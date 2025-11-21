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
  RUNNER_NAME=$(hostname)
fi

echo "Fixing permissions for /actions-runner..."
chown -R runner:runner /actions-runner

echo $"Runner name: $RUNNER_NAME"
echo $"Runner URL: $URL"

# 3. Configure runner (Check if already configured to avoid errors on restart)
if [ ! -f .runner ]; then
    echo "Configuring GitHub Actions Runner..."
    # Use gosu to run as the 'runner' user
    gosu runner ./config.sh \
      --url "$URL" \
      --token "$RUNNER_TOKEN" \
      --name "$RUNNER_NAME" \
      --unattended \
      --replace
else
    echo "Runner already configured. Skipping configuration."
fi

echo "Starting runner..."
exec gosu runner ./run.sh