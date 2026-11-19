#!/bin/bash
# Tests periodic-sweep.sh against a fake runner layout in a throwaway container,
# never a live replica:
#
#   docker run --rm --entrypoint bash -v "$PWD:/src:ro" <runner image> /src/tests/periodic-sweep-test.sh
#
# Covers what is removed and kept, the busy-runner and held-lock skips, and
# job-started-hook.sh waiting for a sweep in progress.
set -u

SRC="${SRC:-/src}"
T=$(mktemp -d)
R="$T/actions-runner"
W="$R/_work"
fail=0

check() {  # check <present|absent> <path>
  if [[ $1 == present && -e $2 ]] || [[ $1 == absent && ! -e $2 ]]; then
    echo "ok   $1 ${2#"$T"/}"
  else
    echo "FAIL $1 ${2#"$T"/}"; fail=1
  fi
}

old() { touch -d '30 days ago' "$@"; }

fixture() {
  rm -rf "$R"
  mkdir -p "$R"/bin.2.1 "$R"/bin.2.2 "$R"/externals.2.1 "$R"/externals.2.2
  ln -s "$R/bin.2.2" "$R/bin"
  ln -s "$R/externals.2.2" "$R/externals"
  mkdir -p "$W/_update/bin" "$W/_tool/Python/3.12.1" "$W/_tool/Python/3.14.1" \
           "$W/_tool/uv/0.1.0" "$W/_tool/uv/0.2.0" "$W/_tool/node/20.1.0" \
           "$W/repo/repo/target/debug" "$W/repo/repo/src"
  touch "$W/_tool/Python/3.12.1.complete" "$W/repo/repo/target/CACHEDIR.TAG" "$W/repo/repo/src/main.rs"
  head -c 3000000 /dev/zero > "$W/repo/repo/target/debug/blob"
  old "$W/_update" "$W/_update/bin" "$W/_tool/Python/3.12.1" "$W/_tool/Python/3.14.1" "$W/_tool/uv/0.1.0" "$W/_tool/node/20.1.0"
}

sweep() {
  RUNNER_DIR="$R" SWEEP_WORK_DIR="$W" SWEEP_LOCK="$T/sweep.lock" SWEEP_MAX_GB=0 \
    COMPLETED_HOOK="$SRC/job-completed-hook.sh" bash "$SRC/periodic-sweep.sh"
}

echo "== idle sweep"
fixture
sweep
check absent  "$R/bin.2.1"
check present "$R/bin.2.2"
check absent  "$R/externals.2.1"
check present "$R/externals.2.2"
check absent  "$W/_update"
check absent  "$W/_tool/Python/3.12.1"
check absent  "$W/_tool/Python/3.12.1.complete"
check present "$W/_tool/Python/3.14.1"   # newest Python, old but kept
check absent  "$W/_tool/uv/0.1.0"
check present "$W/_tool/uv/0.2.0"        # newest uv
check present "$W/_tool/node/20.1.0"     # only version of its tool
check absent  "$W/repo/repo/target"
check present "$W/repo/repo/src/main.rs"

echo "== _update younger than a day is kept"
fixture
touch "$W/_update/bin"
sweep >/dev/null
check present "$W/_update"

echo "== busy runner is skipped"
fixture
cp "$(command -v sleep)" "$T/Runner.Worker"
"$T/Runner.Worker" 5 &
busy=$!
sleep 0.2
out=$(sweep)
kill "$busy" 2>/dev/null; wait "$busy" 2>/dev/null
if [[ $out == *"a job is running"* ]]; then echo "ok   skip message"; else echo "FAIL skip message: $out"; fail=1; fi
check present "$R/bin.2.1"
check present "$W/repo/repo/target"

echo "== held lock is skipped"
fixture
( exec 9>"$T/sweep.lock"; flock 9; sleep 3 ) &
holder=$!
sleep 0.3
out=$(sweep)
if [[ $out == *"another sweep holds"* ]]; then echo "ok   lock message"; else echo "FAIL lock message: $out"; fail=1; fi
check present "$R/bin.2.1"

echo "== job-started hook waits for a sweep in progress"
start=$(date +%s)
SWEEP_LOCK="$T/sweep.lock" GIT_CONFIG_GLOBAL="$T/gitconfig" bash "$SRC/job-started-hook.sh"
waited=$(( $(date +%s) - start ))
wait "$holder"
if (( waited >= 2 )); then echo "ok   hook waited ${waited}s"; else echo "FAIL hook waited ${waited}s"; fail=1; fi

echo "== job-started hook without SWEEP_LOCK does not wait"
( exec 9>"$T/sweep.lock"; flock 9; sleep 3 ) &
holder=$!
sleep 0.3
start=$(date +%s)
GIT_CONFIG_GLOBAL="$T/gitconfig" bash "$SRC/job-started-hook.sh"
waited=$(( $(date +%s) - start ))
wait "$holder"
if (( waited < 2 )); then echo "ok   hook did not wait (${waited}s)"; else echo "FAIL hook waited ${waited}s"; fail=1; fi

rm -rf "$T"
(( fail )) && { echo "FAILED"; exit 1; }
echo "PASSED"
