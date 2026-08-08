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

# These are named volumes. Docker seeds them from the image with the right
# ownership, but a volume created before the directory existed in the image (or
# by another image) comes back root-owned and silently breaks every build.
for vol_dir in /home/runner/.cargo/registry /home/runner/.cache/sccache; do
  if [[ -d "$vol_dir" ]] && [[ "$(stat -c %U "$vol_dir")" != "runner" ]]; then
    echo "Fixing permissions for ${vol_dir}..."
    chown -R runner:runner "$vol_dir"
  fi
done

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
# Clean up previous runs (crucial for ephemeral runners).
#
# `.runner_migrated` MUST be in this list. The runner self-updates in place, and
# a post-update runner drops that marker beside its config. `config.sh` treats
# the marker ALONE as proof the runner is already configured -- verified by
# creating only `.runner_migrated` and passing a deliberately bogus token: it
# fails with "Cannot configure the runner because it is already configured"
# without even attempting to authenticate.
#
# Because the old list stopped at `.credentials_rsaparams`, every replica that
# had auto-updated crash-looped on its next restart until `restart:
# on-failure:5` exhausted its retries, which silently took the entire fleet
# offline about ten days after it was last rebuilt. Deleting the marker is
# correct rather than merely expedient: this entrypoint always reconfigures from
# a freshly minted registration token, so there is no migrated state worth
# preserving across a restart.
rm -f .runner .credentials .credentials_rsaparams \
      .runner_migrated .credentials_migrated

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
