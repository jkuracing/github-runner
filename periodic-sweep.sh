#!/bin/bash
# Periodic idle-time cleanup for one Linux replica. entrypoint.sh starts it as
# `periodic-sweep.sh --loop`, as the runner user, next to run.sh.
#
# Why this exists
# ---------------
# job-completed-hook.sh bounds `target/` after every job, but measured on
# 2026-11-15 the replicas' writable layers still held 2-7.7 GB each (78 GB for
# the fleet), and the host disk filled. The hook misses:
#
#   - jobs that are cancelled, time out or die with the container: the
#     completed hook never runs, so their `target/` stays until a later job
#     finishes normally on that replica;
#   - old runner versions: every self-update leaves the previous
#     `bin.<ver>` / `externals.<ver>` (~0.4 GB) and `_work/_update` (~0.45 GB)
#     behind;
#   - `_work/_tool`: setup-python and setup-uv add a version per release and
#     never drop one (1.2 GB on one replica, 3 uv versions and 2 Pythons).
#
# The hook cannot remove these itself: it only runs after a job, and only
# deletes `target/` dirs.
#
# Why it cannot race a job
# ------------------------
# A sweep runs only while no Runner.Worker process exists, and holds
# $SWEEP_LOCK for its whole duration. job-started-hook.sh takes the same lock
# before the job's first step, so a job assigned mid-sweep waits for it to
# finish instead of building into a directory that is being deleted. The
# completed hook runs inside Runner.Worker, so the two never overlap either.
set -uo pipefail

RUNNER_DIR="${RUNNER_DIR:-/actions-runner}"
WORK_DIR="${SWEEP_WORK_DIR:-${RUNNER_DIR}/_work}"
SWEEP_LOCK="${SWEEP_LOCK:-/tmp/runner-sweep.lock}"
SWEEP_INTERVAL_MIN="${SWEEP_INTERVAL_MIN:-30}"
SWEEP_TOOL_DAYS="${SWEEP_TOOL_DAYS:-7}"
COMPLETED_HOOK="${COMPLETED_HOOK:-/usr/local/bin/job-completed-hook.sh}"

log() { echo "periodic-sweep: $*"; }

remove() {
  local freed
  freed=$(du -sm "$1" 2>/dev/null | cut -f1)
  rm -rf "$1" && log "removed $1 (${freed:-?} MB)"
}

# Runner versions the bin/externals symlinks do not point at.
sweep_runner_versions() {
  local kind current dir
  for kind in bin externals; do
    current=$(readlink -f "${RUNNER_DIR}/${kind}" 2>/dev/null) || continue
    [[ -n "$current" ]] || continue
    for dir in "${RUNNER_DIR}/${kind}".*; do
      [[ -d "$dir" && "$(readlink -f "$dir")" != "$current" ]] && remove "$dir"
    done
  done
  # The staging copy of a finished self-update. The minimum age keeps it out of
  # the way of an update the listener is downloading right now.
  if [[ -d "${WORK_DIR}/_update" ]] &&
     [[ -z "$(find "${WORK_DIR}/_update" -mmin -1440 -print -quit 2>/dev/null)" ]]; then
    remove "${WORK_DIR}/_update"
  fi
}

# All but the newest version of each tool, once older than SWEEP_TOOL_DAYS.
# A job that needs a dropped version downloads it again (seconds to a minute),
# and that resets its age, so a version in use survives.
sweep_tool_cache() {
  local tool newest ver
  for tool in "${WORK_DIR}/_tool"/*/; do
    [[ -d "$tool" ]] || continue
    newest=$(find "$tool" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V | tail -1)
    for ver in "$tool"*/; do
      ver="${ver%/}"
      [[ "$(basename "$ver")" == "$newest" ]] && continue
      [[ -n "$(find "$ver" -maxdepth 0 -mtime "+${SWEEP_TOOL_DAYS}" 2>/dev/null)" ]] || continue
      remove "$ver"
      rm -f "${ver}.complete"
    done
  done
}

sweep_once() {
  exec 9>"$SWEEP_LOCK"
  if ! flock -n 9; then
    log "another sweep holds ${SWEEP_LOCK}, skipping"
    return 0
  fi
  # Checked under the lock: a job that starts after this point blocks in
  # job-started-hook.sh until the lock is released.
  if pgrep -x Runner.Worker >/dev/null 2>&1; then
    log "a job is running, skipping"
    exec 9>&-
    return 0
  fi
  local before after
  before=$(du -sm "$WORK_DIR" 2>/dev/null | cut -f1)
  # Through bash, as the runner itself starts hooks: the file need not be +x.
  [[ -f "$COMPLETED_HOOK" ]] && bash "$COMPLETED_HOOK" | sed 's/^/periodic-sweep: /'
  sweep_runner_versions
  sweep_tool_cache
  after=$(du -sm "$WORK_DIR" 2>/dev/null | cut -f1)
  log "_work ${before:-?} MB -> ${after:-?} MB"
  exec 9>&-
}

if [[ "${1:-}" == "--loop" ]]; then
  # The first pass waits a few minutes, so it catches what a crash or restart
  # left behind without slowing the container's start.
  sleep 300
  while true; do
    sweep_once
    sleep $((SWEEP_INTERVAL_MIN * 60))
  done
else
  sweep_once
fi
# Never fail: this is housekeeping next to the runner, not part of a job.
exit 0
