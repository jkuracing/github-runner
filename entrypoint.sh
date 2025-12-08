#!/bin/bash
set -e

if [[ -z "$URL" ]]; then
  echo "ERROR: URL environment variable is required."
  exit 1
fi
if [[ -z "$RUNNER_TOKEN" ]]; then
  echo "ERROR: RUNNER_TOKEN environment variable is required."
  exit 1
fi
if [[ -z "$RUNNER_NAME" ]]; then
  RUNNER_NAME="runner"
fi

FULL_RUNNER_NAME="${RUNNER_NAME}-${HOSTNAME}"

echo "Fixing permissions for /actions-runner..."
chown -R runner:runner /actions-runner

# Source ESP toolchain environment if available
if [[ -f /home/runner/export-esp.sh ]]; then
  echo "Sourcing ESP toolchain environment..."
  source /home/runner/export-esp.sh 2>/dev/null || true
fi

echo "Removing any existing runner configuration..."
# Clean up previous runs (crucial for ephemeral runners)
rm -f .runner .credentials .credentials_rsaparams

echo "Configuring GitHub Actions Runner as ${FULL_RUNNER_NAME}..."
echo "URL: $URL"

# Build config.sh arguments
CONFIG_ARGS=(
  --url "$URL"
  --token "$RUNNER_TOKEN"
  --name "$FULL_RUNNER_NAME"
  --unattended
  --replace
)

# Add labels if RUNNER_LABELS is set
if [[ -n "$RUNNER_LABELS" ]]; then
  echo "Labels: $RUNNER_LABELS"
  CONFIG_ARGS+=(--labels "$RUNNER_LABELS")
fi

# Configure using the UNIQUE name
gosu runner ./config.sh "${CONFIG_ARGS[@]}"

echo "Starting runner..."
exec gosu runner ./run.sh