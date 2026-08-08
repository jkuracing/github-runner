FROM ubuntu:24.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Populated by BuildKit with "amd64" or "arm64". Must be declared WITHOUT a
# default: a default shadows the value the builder injects, which would silently
# fetch the wrong architecture's binaries. Steps below fall back to
# `dpkg --print-architecture` (same amd64/arm64 vocabulary) when it is unset,
# so non-BuildKit builds still resolve the host architecture correctly.
ARG TARGETARCH

# ============================================================================
# Base system dependencies (GitHub Actions Runner)
# ============================================================================
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl jq git bash libicu74 ca-certificates \
        uuid-runtime iputils-ping gosu && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# ============================================================================
# Firmware build dependencies
# ============================================================================
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential pkg-config libssl-dev libudev-dev \
        openssh-client unzip wget \
        python3.12 python3.12-venv python3.12-dev python3-cffi && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# ============================================================================
# Install Rust toolchain (stable)
# ============================================================================
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable && \
    rustup component add rustfmt clippy && \
    # Install cargo-nextest for faster test execution
    cargo install cargo-nextest --locked

# ============================================================================
# Install ESP-IDF Xtensa toolchain for ESP32-S3
# ============================================================================
RUN mkdir -p /opt/esp-tools && \
    # Install espup to manage ESP toolchains
    cargo install espup --locked && \
    # Install ESP Rust toolchain with ESP32-S3 support
    espup install --targets esp32s3

# Add ESP toolchain binaries to PATH dynamically
# espup creates export-esp.sh with the correct paths
RUN echo 'source $HOME/export-esp.sh 2>/dev/null || true' >> /etc/bash.bashrc

# ============================================================================
# Install just (command runner)
# ============================================================================
RUN curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to /usr/local/bin

# ============================================================================
# Install Pkl (Apple's configuration language - used by canvas)
# ============================================================================
RUN ARCH="${TARGETARCH:-$(dpkg --print-architecture)}" && \
    case "$ARCH" in \
        amd64) PKL_ARCH=amd64 ;; \
        arm64) PKL_ARCH=aarch64 ;; \
        *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;; \
    esac && \
    curl -fL -o /usr/local/bin/pkl "https://github.com/apple/pkl/releases/download/0.30.1/pkl-linux-${PKL_ARCH}" && \
    chmod +x /usr/local/bin/pkl

# ============================================================================
# Install uv (fast Python package manager) and maturin (Rust-Python build tool)
# ============================================================================
# Installed into shared, world-readable locations rather than under /root, which
# is mode 0700: a tool symlinked out of /root is unusable by the unprivileged
# runner user that actually executes jobs.
ENV UV_TOOL_DIR=/opt/uv/tools

RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh && \
    # Install maturin globally, with its launcher on the shared PATH
    UV_TOOL_BIN_DIR=/usr/local/bin uv tool install maturin && \
    chmod -R a+rX /opt/uv

# ============================================================================
# Web UI and Tauri desktop dependencies (hbf)
# ============================================================================
# Deliberately placed AFTER the espup layer. Docker invalidates every layer
# below an edited one, and rebuilding the Xtensa toolchain costs many minutes,
# so anything added later must stay later.
#
# `cargo build -p hbf-gui` links against webkit2gtk-4.1 and fails at
# pkg-config time without the -dev package; librsvg2 and appindicator3 are
# Tauri's SVG and tray-icon dependencies. This mirrors the apt list hbf CI
# installs per job, minus what the firmware layers above already provide
# (libudev-dev, pkg-config, libssl-dev).
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        libwebkit2gtk-4.1-dev libayatana-appindicator3-dev \
        librsvg2-dev && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# bun builds the SvelteKit bundle that `tauri::generate_context!()` embeds at
# COMPILE time, so it is a build dependency of hbf-gui rather than a test-only
# tool. Pinned to the version hbf CI's `oven-sh/setup-bun` requests so lockfile
# resolution is identical on both. BUN_INSTALL places the binary on the shared
# PATH instead of under /root, which is mode 0700 and therefore invisible to the
# unprivileged runner user -- the same trap the uv block above documents.
ENV BUN_INSTALL=/usr/local
RUN curl -fsSL https://bun.sh/install | bash -s "bun-v1.3.14" && \
    chmod a+rx /usr/local/bin/bun && \
    bun --version

# ============================================================================
# Create runner directory and download GitHub Actions Runner
# ============================================================================
RUN mkdir -p /actions-runner
WORKDIR /actions-runner

RUN ARCH="${TARGETARCH:-$(dpkg --print-architecture)}" && \
    case "$ARCH" in \
        amd64) RUNNER_ARCH=x64 ;; \
        arm64) RUNNER_ARCH=arm64 ;; \
        *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;; \
    esac && \
    LATEST_TAG=$(curl -s https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name) && \
    RUNNER_VERSION=${LATEST_TAG#v} && \
    echo "Downloading Runner Version: ${RUNNER_VERSION} (${RUNNER_ARCH})" && \
    curl -fL -o runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz" && \
    tar xzf runner.tar.gz && \
    rm runner.tar.gz

# ============================================================================
# Setup SSH for private repository access (submodules)
# ============================================================================
RUN mkdir -p /root/.ssh && \
    chmod 700 /root/.ssh && \
    ssh-keyscan github.com >> /root/.ssh/known_hosts && \
    chmod 644 /root/.ssh/known_hosts

# Copy entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Create a non-root user and copy tools
RUN useradd -m runner && \
    # Copy Rust/Cargo to runner user
    mkdir -p /home/runner/.cargo /home/runner/.rustup && \
    cp -r /usr/local/cargo/* /home/runner/.cargo/ 2>/dev/null || true && \
    cp -r /usr/local/rustup/* /home/runner/.rustup/ 2>/dev/null || true && \
    # Copy ESP toolchain to runner user (espup installs to ~/.rustup)
    cp -r /root/.rustup/* /home/runner/.rustup/ 2>/dev/null || true && \
    # Copy export-esp.sh to runner home
    cp /root/export-esp.sh /home/runner/export-esp.sh 2>/dev/null || true && \
    # uv and its tools (maturin) live in /usr/local/bin and /opt/uv, which are
    # already on the shared PATH and readable by this user — nothing to copy.
    # Pre-create the sccache directory so its named volume is seeded with runner
    # ownership. A volume mounted over a path that does not exist in the image is
    # created root-owned, which the unprivileged runner cannot write to.
    mkdir -p /home/runner/.cache/sccache && \
    # Copy SSH config to runner user
    mkdir -p /home/runner/.ssh && \
    cp /root/.ssh/known_hosts /home/runner/.ssh/ && \
    chmod 700 /home/runner/.ssh && \
    chmod 644 /home/runner/.ssh/known_hosts && \
    # Add source export-esp.sh to runner's bashrc
    echo 'source $HOME/export-esp.sh 2>/dev/null || true' >> /home/runner/.bashrc && \
    # Fix ownership
    chown -R runner:runner /home/runner

# Environment variables for runner user
ENV RUSTUP_HOME=/home/runner/.rustup \
    CARGO_HOME=/home/runner/.cargo \
    PATH="/home/runner/.cargo/bin:/home/runner/.local/bin:${PATH}"

# We remain as root here so entrypoint.sh can fix volume permissions
ENTRYPOINT ["/entrypoint.sh"]