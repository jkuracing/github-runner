FROM ubuntu:22.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies (including gosu for permission handling)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl jq git bash libicu70 ca-certificates \
        uuid-runtime iputils-ping gosu && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Create runner directory
RUN mkdir -p /actions-runner
WORKDIR /actions-runner

# Automatically download the LATEST runner version
RUN LATEST_TAG=$(curl -s https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name) && \
    RUNNER_VERSION=${LATEST_TAG#v} && \
    echo "Downloading Runner Version: ${RUNNER_VERSION}" && \
    curl -L -o actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" && \
    tar xzf actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz && \
    rm actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz

# Copy entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Create a non-root user
RUN useradd -m runner

# We remain as root here so entrypoint.sh can fix volume permissions
ENTRYPOINT ["/entrypoint.sh"]