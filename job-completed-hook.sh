#!/bin/bash
# Runs after EVERY job on this replica, via ACTIONS_RUNNER_HOOK_JOB_COMPLETED.
#
# Why this exists
# ---------------
# sccache made rebuilding a `target/` dir cheap, but it does not make `target/`
# small: rlibs, shared objects and test executables still land there at full
# size, so hbf's reaches 11-13 GB per replica. Twelve of those is ~140 GB, which
# is how a 926 GB volume ended up at 294 MB free on 2026-08-09 -- surfacing not
# as "out of disk" but as `collect2: ld terminated with signal 7 [Bus error]`.
#
# So the disk bound is this hook, and sccache is what makes it affordable: a
# swept replica refills from the shared bucket instead of recompiling. A cold
# rebuild measured 11 misses; after `cargo clean` the same build took 13 hits and
# added no misses, i.e. it came entirely from the cache.
#
# Why a job hook rather than a cron
# ---------------------------------
# The runner invokes this between jobs, so it can never delete a `target/` out
# from under a running compile -- which a host-side cron racing 12 replicas could
# easily do. It also needs no state on the host and no scheduler to keep alive.
#
# Budget
# ------
# Total is meant to stay under 100 GB:
#   images ~10 + cargo registries ~16 + sccache bucket <=20  = ~46 GB fixed
#   12 replicas x SWEEP_MAX_GB                               = the rest
# At the default of 4 GB that lands near 94 GB. Raising it trades disk for fewer
# sweeps (and so faster jobs); lowering it does the reverse. Note this bounds
# STEADY STATE, not the peak: a build in flight can exceed the threshold, and is
# only swept once it finishes.
set -uo pipefail

SWEEP_MAX_GB="${SWEEP_MAX_GB:-4}"
# The runner root's _work, NOT $RUNNER_WORKSPACE.
#
# This originally read `${RUNNER_WORKSPACE:-/actions-runner/_work}`, which was
# wrong: RUNNER_WORKSPACE is per-REPOSITORY (`_work/<repo>`), so the budget was
# enforced once per repo rather than once per replica. With firmware and hbf both
# checked out, each replica could hold 2 x SWEEP_MAX_GB. Measured the morning
# after rollout: five replicas sat at 6.8-7.2 GB against a nominal 4 GB budget,
# and the fleet total reached 52 GB against a 48 GB ceiling. SWEEP_WORK_DIR
# stays overridable for testing.
WORK_DIR="${SWEEP_WORK_DIR:-/actions-runner/_work}"
# _work holds more than checkouts (_tool, _temp, _actions), so measure the whole
# thing -- that is what actually occupies the writable layer.
[[ -d "$WORK_DIR" ]] || exit 0

used_mb=$(du -sm "$WORK_DIR" 2>/dev/null | cut -f1)
[[ -n "$used_mb" ]] || exit 0
limit_mb=$((SWEEP_MAX_GB * 1024))

if (( used_mb <= limit_mb )); then
  echo "sweep: _work at ${used_mb} MB, under the ${limit_mb} MB budget -- keeping it warm"
  exit 0
fi

echo "sweep: _work at ${used_mb} MB exceeds ${limit_mb} MB -- removing target dirs"

# Largest first, stopping as soon as the budget is met, so a replica keeps as
# much warmth as the budget allows instead of being emptied wholesale. Only
# genuine cargo target dirs are touched: the CACHEDIR.TAG / debug / release test
# avoids deleting a source directory that merely happens to be called "target".
while IFS= read -r dir; do
  (( used_mb <= limit_mb )) && break
  [[ -f "${dir}/CACHEDIR.TAG" || -d "${dir}/debug" || -d "${dir}/release" ]] || continue
  freed=$(du -sm "$dir" 2>/dev/null | cut -f1)
  rm -rf "$dir" && used_mb=$((used_mb - ${freed:-0}))
  echo "sweep: removed ${dir} (${freed:-?} MB), now ~${used_mb} MB"
done < <(find "$WORK_DIR" -type d -name target -prune 2>/dev/null \
           | while IFS= read -r d; do echo "$(du -sm "$d" 2>/dev/null | cut -f1) $d"; done \
           | sort -rn | cut -d' ' -f2-)

# Never fail the job. This hook runs after the work that matters is already
# done and reported; a sweep problem must not turn a green job red.
exit 0
