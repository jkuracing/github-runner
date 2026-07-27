#!/bin/bash
set -e

if [[ -z "$URL" ]]; then
  echo "ERROR: URL environment variable is required."
  exit 1
fi
if [[ -z "$GITHUB_PAT" && -z "$RUNNER_TOKEN" ]]; then
  echo "ERROR: either GITHUB_PAT or RUNNER_TOKEN environment variable is required."
  exit 1
fi
if [[ -z "$RUNNER_NAME" ]]; then
  RUNNER_NAME="runner"
fi

FULL_RUNNER_NAME="${RUNNER_NAME}-${HOSTNAME}"

echo "Fixing permissions for /actions-runner..."
chown -R runner:runner /actions-runner

# The shared cargo registry is a named volume. Docker seeds it from the image
# with the right ownership, but a volume created before that directory existed
# (or by another image) comes back root-owned and silently breaks every build.
if [[ -d /home/runner/.cargo/registry ]] && [[ "$(stat -c %U /home/runner/.cargo/registry)" != "runner" ]]; then
  echo "Fixing permissions for the shared cargo registry..."
  chown -R runner:runner /home/runner/.cargo/registry
fi

# Fetches a short-lived token ($1: "registration-token" or "remove-token") from the
# GitHub API, using GITHUB_PAT. Prints the token on stdout, returns non-zero on failure.
fetch_runner_token() {
  local kind="$1"
  local url_path="${URL#https://github.com/}"
  url_path="${url_path%/}"
  local owner repo
  IFS='/' read -r owner repo <<< "$url_path"

  local api_url
  if [[ -n "$repo" ]]; then
    api_url="https://api.github.com/repos/${owner}/${repo}/actions/runners/${kind}"
  else
    api_url="https://api.github.com/orgs/${owner}/actions/runners/${kind}"
  fi

  local resp_file http_code token
  resp_file="$(mktemp)"
  http_code=$(curl -s -o "$resp_file" -w "%{http_code}" -X POST \
    -H "Authorization: Bearer ${GITHUB_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "$api_url")

  if [[ "$http_code" != "201" ]]; then
    echo "ERROR: Failed to obtain ${kind} from GitHub API (HTTP $http_code)." >&2
    cat "$resp_file" >&2
    rm -f "$resp_file"
    return 1
  fi

  token=$(jq -r .token "$resp_file")
  rm -f "$resp_file"
  if [[ -z "$token" || "$token" == "null" ]]; then
    echo "ERROR: GitHub API response did not contain a token." >&2
    return 1
  fi
  echo "$token"
}

# Registration tokens expire after ~1 hour, so if a PAT is available, use it
# to mint a fresh one on every start instead of relying on a stale static token.
if [[ -n "$GITHUB_PAT" ]]; then
  echo "Requesting a fresh registration token from the GitHub API..."
  RUNNER_TOKEN=$(fetch_runner_token registration-token) || exit 1
fi

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

# Deregisters the runner from GitHub so it doesn't linger as an "Offline" entry.
# Only possible with GITHUB_PAT, since removing a runner requires a dedicated
# remove-token that a static RUNNER_TOKEN cannot mint.
deregister_runner() {
  echo "Deregistering ${FULL_RUNNER_NAME} from GitHub..."
  if [[ -z "$GITHUB_PAT" ]]; then
    echo "WARNING: GITHUB_PAT not set, cannot fetch a remove-token. Runner will show as offline until manually removed."
    return
  fi
  local remove_token
  if remove_token=$(fetch_runner_token remove-token); then
    gosu runner ./config.sh remove --token "$remove_token" \
      || echo "WARNING: failed to deregister ${FULL_RUNNER_NAME}. It will show as offline until manually removed."
  else
    echo "WARNING: could not obtain a remove-token. ${FULL_RUNNER_NAME} will show as offline until manually removed."
  fi
}

RUNNER_PID=""
handle_shutdown() {
  echo "Received shutdown signal, stopping runner (waiting for any active job to finish)..."
  if [[ -n "$RUNNER_PID" ]]; then
    kill -TERM "$RUNNER_PID" 2>/dev/null || true
    wait "$RUNNER_PID" 2>/dev/null || true
  fi
  deregister_runner
  exit 0
}
trap handle_shutdown SIGTERM SIGINT

echo "Starting runner..."
gosu runner ./run.sh &
RUNNER_PID=$!
wait "$RUNNER_PID"
deregister_runner
