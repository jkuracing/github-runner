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

# Cargo knobs applied to every job this replica runs.
#
# Exporting here is what makes these changeable by a plain `docker restart`.
# `docker compose` bakes a container's environment at CREATION time, so setting
# them only in docker-compose.yml means they reach a job solely after
# `up -d` -- which RECREATES the container, destroying `_work` along with the
# 11-13 GB warm `target/` dir that lives on the writable layer. Restart keeps
# it. The runner inherits this process's environment and hands it to each job
# step, so an export reaches the compiler.
#
# Do NOT move these into /actions-runner/.env. That file is read only by the
# systemd unit `svc.sh` generates; this entrypoint execs ./run.sh directly and
# run.sh contains no reference to it -- verified, not assumed. The stock .env is
# empty here and `env.sh` merely writes it for that service path.
#
# The defaults live here rather than in docker-compose.yml so that one file owns
# them; compose or `docker run -e` can still override either value.

# Worth 2.8 GB per replica (14 GB in a long-lived developer checkout, which is
# what this keeps the fleet from becoming).
#
# This is a trade, NOT free: an earlier version of this comment called
# incremental state "pure waste in CI, since every job is a different commit",
# which is wrong here. hbf's ci.yml deliberately uses `clean: false` to keep
# `target/` warm across jobs, so successive jobs on one replica genuinely can
# hit an incremental cache.
#
# The exposure is bounded and judged worth the disk:
#   - It only ever covers hbf's own dozen workspace crates. Registry
#     dependencies -- which are the whole 8.4 GB bulk of debug/deps -- are
#     compiled non-incrementally regardless of this setting.
#   - A hit needs the SAME replica to rebuild a NEARLY IDENTICAL commit. Jobs
#     go to whichever of the 12 replicas is free, with no branch affinity, so
#     that is luck rather than design.
#   - Where nothing changed at all, cargo's ordinary fingerprinting skips the
#     crate outright and incremental adds nothing.
#   - It is not free even when it hits: incremental raises the codegen-unit
#     count, which costs some link time back.
#
# It is also a prerequisite for sccache rather than a rival to it -- sccache
# cannot cache incrementally compiled units and silently bypasses them. sccache
# would hit across every crate, replica and commit rather than only the
# same-replica-similar-commit case, so trading incremental for it is a clear win
# whenever someone wires it up.
export CARGO_INCREMENTAL="${CARGO_INCREMENTAL:-0}"

# A floor, NOT a saving -- do not expect this to reclaim anything. hbf's ci.yml
# already sets it workflow-wide as of 3a6e615, and the target dirs measured on
# this fleet are already the reduced size: objdump on the largest test
# executable shows .debug_loc at 0 bytes with .debug_line the dominant section,
# the line-tables-only signature. Set here so the property holds for every job
# whatever an individual workflow remembers to configure; firmware_ci.yml sets
# only CARGO_PROFILE_RELEASE_DEBUG and leaves its dev profile uncovered.
export CARGO_PROFILE_DEV_DEBUG="${CARGO_PROFILE_DEV_DEBUG:-line-tables-only}"

# sccache, backed by the fleet's shared S3 (MinIO) bucket.
#
# Shared rather than per-replica on purpose. Twelve private caches would each
# have to warm from scratch, so the first build on every replica stays cold --
# which is most of what a cache is supposed to prevent. Pointed at one bucket,
# whichever replica compiles a crate first serves the other eleven. Note the
# per-replica *local* sccache volumes this fleet used to mount are unnecessary
# in this mode and have been removed from docker-compose.yml: with an S3 backend
# sccache does not use a local cache directory.
#
# A shared local DIRECTORY would not be safe here -- each sccache server process
# keeps its own in-memory LRU index, so several containers writing one directory
# corrupt each other's accounting. A server backend has no such problem, which
# is the distinction the header comment in docker-compose.yml draws for the cargo
# registry as well.
SCCACHE_BUCKET="${SCCACHE_BUCKET:-sccache}"
SCCACHE_ENDPOINT="${SCCACHE_ENDPOINT:-http://sccache-s3:9000}"
SCCACHE_REGION="${SCCACHE_REGION:-us-east-1}"
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-sccache}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-sccache-secret}"

# Enable the wrapper ONLY if the bucket is actually reachable. A cache is an
# optimisation and must never be able to break CI: if MinIO is down, mis-DNSed or
# still starting, the correct outcome is slower builds, not failed ones. sccache
# degrades gracefully once running, but a server that cannot start at all would
# take every `cargo` invocation down with it, so this is checked up front rather
# than hoped for. Retried because the runner and MinIO come up concurrently.
# The window is generous (~60s) because compose only orders startup here and does
# not wait for health -- see docker-compose.yml for why gating the fleet on the
# cache would be worse. On a cold `up -d` MinIO may still be initialising its
# volume while the runners boot, and a replica that gives up early would run
# every job uncached until something restarted it.
sccache_reachable=0
for attempt in $(seq 1 20); do
  if curl -fsS --max-time 3 "${SCCACHE_ENDPOINT}/minio/health/live" >/dev/null 2>&1; then
    sccache_reachable=1
    break
  fi
  echo "sccache: ${SCCACHE_ENDPOINT} not ready (attempt ${attempt}/20), retrying..."
  sleep 3
done

if [[ "$sccache_reachable" == "1" ]]; then
  export SCCACHE_BUCKET SCCACHE_ENDPOINT SCCACHE_REGION
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  export SCCACHE_S3_USE_SSL="${SCCACHE_S3_USE_SSL:-false}"
  # Surfaces storage errors in the job log instead of silently degrading to a 0%
  # hit rate, which is exactly how the previous sccache attempt here died
  # unnoticed -- it left 1.1 GB per replica of cache last written 2026-07-28 and
  # no wrapper ever configured.
  export SCCACHE_ERROR_LOG=/tmp/sccache.log
  export SCCACHE_LOG="${SCCACHE_LOG:-warn}"
  export RUSTC_WRAPPER=sccache

  # Start the server HERE, explicitly, and never let it idle out. Both halves are
  # load-bearing, and this was found the hard way.
  #
  # The sccache server takes its cache configuration from whichever process first
  # starts it. Started explicitly with the environment above it comes up on s3
  # ("Cache location  s3, name: sccache"); left to be spawned implicitly by
  # cargo's first `sccache rustc ...` wrapper call it came up on LOCAL DISK
  # instead, reporting `Cache location  Local disk` with every compile request
  # invisible to the shared bucket. That failure is silent -- builds succeed at
  # full speed-looking cost, the bucket stays empty, and the only symptom is a
  # cache that never hits. It is exactly the shape of the previous dead sccache
  # attempt here, so it gets a real fix rather than a hope.
  #
  # SCCACHE_IDLE_TIMEOUT=0 keeps the server alive for the container's lifetime.
  # The default is 600s, after which the server exits and the NEXT wrapper call
  # respawns it -- landing back on local disk and silently unsharing the cache
  # between jobs. A runner is idle far longer than ten minutes between jobs, so
  # the default would have made this bug the normal case.
  export SCCACHE_IDLE_TIMEOUT=0
  gosu runner env \
    SCCACHE_BUCKET="$SCCACHE_BUCKET" SCCACHE_ENDPOINT="$SCCACHE_ENDPOINT" \
    SCCACHE_REGION="$SCCACHE_REGION" SCCACHE_S3_USE_SSL="$SCCACHE_S3_USE_SSL" \
    AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
    SCCACHE_IDLE_TIMEOUT=0 SCCACHE_ERROR_LOG="$SCCACHE_ERROR_LOG" \
    SCCACHE_LOG="$SCCACHE_LOG" \
    sccache --start-server 2>&1 | tail -2 || true

  # Assert the server really is on s3, via a throwaway compile first.
  #
  # `sccache --show-stats` on its own is NOT a trustworthy probe: with no server
  # running it reports `Cache location  Local disk` from client-side defaults
  # without starting one (no SCCACHE_ERROR_LOG is even created), which reads as a
  # broken S3 config when nothing is wrong. Diagnosing that cost real time here.
  # Routing one trivial compilation through the wrapper guarantees a server
  # exists, so the backend line that follows describes reality.
  #
  # This matters because a cache silently on local disk is worse than no cache:
  # it consumes the very volume this exists to relieve and returns a 0% hit rate,
  # which is precisely how the previous sccache attempt on this fleet died
  # unnoticed.
  sccache_canary="$(mktemp -d)"
  echo 'fn main() {}' > "${sccache_canary}/canary.rs"
  chown -R runner:runner "$sccache_canary"
  gosu runner env RUSTC_WRAPPER=sccache SCCACHE_IDLE_TIMEOUT=0 \
    SCCACHE_BUCKET="$SCCACHE_BUCKET" SCCACHE_ENDPOINT="$SCCACHE_ENDPOINT" \
    SCCACHE_REGION="$SCCACHE_REGION" SCCACHE_S3_USE_SSL="$SCCACHE_S3_USE_SSL" \
    AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
    sccache rustc --crate-name canary --crate-type lib --emit=metadata \
      -o "${sccache_canary}/canary.rmeta" "${sccache_canary}/canary.rs" >/dev/null 2>&1 || true
  rm -rf "$sccache_canary"

  sccache_backend="$(gosu runner sccache --show-stats 2>/dev/null | grep -i 'Cache location' || true)"
  case "$sccache_backend" in
    *s3*) echo "sccache: ENABLED -> ${SCCACHE_ENDPOINT}/${SCCACHE_BUCKET}" ;;
    *)    echo "sccache: WARNING -- not on s3 after canary compile, got: ${sccache_backend:-<no stats>}" ;;
  esac
else
  echo "sccache: DISABLED (${SCCACHE_ENDPOINT} unreachable) -- builds will be slower but will still succeed"
fi

# Bound `target/` between jobs. sccache makes rebuilding cheap but does NOT make
# target/ small -- the rlibs and test executables still land there at full size,
# so without this the twelve replicas drift back to ~140 GB and refill the disk.
# The runner runs this hook between jobs, so unlike a host cron racing twelve
# replicas it can never delete a target dir out from under a live compile.
export ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/usr/local/bin/job-completed-hook.sh
export SWEEP_MAX_GB="${SWEEP_MAX_GB:-4}"

# Reset $HOME/.gitconfig before every job. Canvas-consuming repos' shared setup
# snippet writes a git `insteadOf` rewrite with `git config --global set` (then
# `--add`), which is safe on an ephemeral GitHub-hosted runner but accumulates
# in this container's persistent $HOME/.gitconfig job after job until a later
# `set` call hits an already multi-valued key and fails outright. See
# job-started-hook.sh for why this is a job-STARTED hook rather than only
# living in job-completed-hook.sh: it must run regardless of whether the
# previous job finished, was cancelled, or was killed.
export ACTIONS_RUNNER_HOOK_JOB_STARTED=/usr/local/bin/job-started-hook.sh

echo "Cargo: CARGO_INCREMENTAL=${CARGO_INCREMENTAL} CARGO_PROFILE_DEV_DEBUG=${CARGO_PROFILE_DEV_DEBUG} RUSTC_WRAPPER=${RUSTC_WRAPPER:-<none>}"
echo "Sweep: target/ budget ${SWEEP_MAX_GB} GB per replica, enforced after each job"
echo "Gitconfig: reset to a clean baseline before each job (ACTIONS_RUNNER_HOOK_JOB_STARTED)"

echo "Starting runner..."
gosu runner ./run.sh &
RUNNER_PID=$!
wait "$RUNNER_PID"
deregister_runner
