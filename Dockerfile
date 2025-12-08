FROM ubuntu:24.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

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
        build-essential pkg-config libssl-dev \
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
RUN curl -L -o /usr/local/bin/pkl https://github.com/apple/pkl/releases/download/0.30.1/pkl-linux-amd64 && \
    chmod +x /usr/local/bin/pkl

# ============================================================================
# Install uv (fast Python package manager) and maturin (Rust-Python build tool)
# ============================================================================
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
    # Add uv to PATH
    . $HOME/.local/bin/env && \
    # Install maturin globally via uv
    uv tool install maturin

ENV PATH="/root/.local/bin:${PATH}"

# ============================================================================
# Create runner directory and download GitHub Actions Runner
# ============================================================================
RUN mkdir -p /actions-runner
WORKDIR /actions-runner

RUN LATEST_TAG=$(curl -s https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name) && \
    RUNNER_VERSION=${LATEST_TAG#v} && \
    echo "Downloading Runner Version: ${RUNNER_VERSION}" && \
    curl -L -o actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" && \
    tar xzf actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz && \
    rm actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz

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
    # Copy uv and tools to runner user
    mkdir -p /home/runner/.local && \
    cp -r /root/.local/* /home/runner/.local/ 2>/dev/null || true && \
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