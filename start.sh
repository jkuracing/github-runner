#!/usr/bin/env bash
# Bring the runner fleet up.
#
# Wraps `docker compose up -d --build` with the checks that are easy to forget
# and expensive to get wrong:
#
#   - that the daemon is actually running (OrbStack is not always started)
#   - that URL and GITHUB_PAT are set, since without them every container comes
#     up, fails to register, and restart-loops looking healthy from `ps`
#   - that --build is passed, because compose only builds when an image is
#     MISSING and will otherwise happily keep running a stale one after the
#     Dockerfile or entrypoint changes
#   - what the memory ceilings add up to against what the VM actually has
#
# Usage:
#   ./start.sh                          # whole fleet
#   ./start.sh runner-1 runner-amd64-1  # only these
#   RUNNER_MEMORY=3g ./start.sh         # smaller replicas
set -euo pipefail
cd "$(dirname "$0")"

die() { printf '\033[31m!!  %s\033[0m\n' "$*" >&2; exit 1; }
say() { printf '\033[36m==> %s\033[0m\n' "$*"; }

command -v docker >/dev/null 2>&1 || die "docker not on PATH."
docker info >/dev/null 2>&1 || die "the docker daemon is not responding -- is OrbStack running?"

# .env is how this fleet is configured; compose reads it itself, so it is only
# checked for here, never printed.
[ -f .env ] || die ".env not found. It must set URL and GITHUB_PAT (see README)."
grep -q '^URL=' .env        || die ".env has no URL="
grep -q '^GITHUB_PAT=' .env || die ".env has no GITHUB_PAT= (a runner cannot register without it)"

# A plain string, not an array: macOS ships bash 3.2, where `mapfile` does not
# exist at all and `${arr[@]}` on an empty array trips `set -u`. Service names
# never contain spaces, so word splitting is safe here.
services="$*"
if [ -z "$services" ]; then
  services=$(docker compose config --services | grep '^runner' | tr '\n' ' ')
fi
count=$(printf '%s\n' $services | grep -c . || true)

# Ceilings vs reality. Limits are ceilings rather than reservations, so
# overcommitting is normal and works right up until several replicas peak
# together and the kernel starts killing builds -- which reads as a random
# compiler crash, not as an out-of-memory problem.
per=${RUNNER_MEMORY:-4g}
per_gb=${per%[gG]}
total=$(( count * per_gb ))
avail=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
avail_gb=$(( avail / 1073741824 ))
say "$count runner(s) x ${per} = ${total} GB of ceilings against ${avail_gb} GB available"
if [ "$total" -gt "$avail_gb" ] && [ "$avail_gb" -gt 0 ]; then
  printf '\033[33m!!  overcommitted by %s GB -- fine while replicas do not peak together, OOM-killed builds when they do.\033[0m\n' \
    "$(( total - avail_gb ))"
  printf '\033[33m    Lower it with RUNNER_MEMORY=3g, or start fewer replicas by naming them.\033[0m\n'
fi

# --build is not optional here; see the header.
say "Building and starting: $services"
docker compose up -d --build $services

say "Waiting for containers to settle"
sleep 5
docker compose ps --format 'table {{.Name}}\t{{.Status}}' | head -20

# A container that is Up but failed to register is the failure mode this script
# exists to make visible: it looks healthy and silently never takes a job.
say "Registration check (last line per runner)"
for s in $services; do
  line=$(docker compose logs --tail 40 "$s" 2>/dev/null \
         | grep -iE "Listening for Jobs|Runner successfully|error|failed" | tail -1)
  printf '  %-20s %s\n' "$s" "${line:-<no runner output yet>}"
done

say "Done. Follow along with: docker compose logs -f <service>"
