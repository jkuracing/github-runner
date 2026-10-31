#!/usr/bin/env bash
# Rebuild the fleet when a new Rust stable is out, then delete the images the
# rebuild replaced.
#
# Why this exists
# ---------------
# Jobs update `stable` themselves (dtolnay/rust-toolchain@stable, `rustup
# toolchain install stable`). Once the image's stable is older than the
# channel's, every replica writes a full copy of the new one onto its writable
# layer: ~1.4 GB each, ~17 GB across the twelve. Rebuilding puts it back in the
# shared image. See the Dockerfile's toolchain layer.
#
# A rebuild leaves the previous images behind untagged -- ~15.5 GB on
# 2026-10-19, measured after the rebuild that introduced the toolchain layer.
# Nothing refers to them once the containers are recreated, so they are pruned
# here rather than left for someone to notice the disk filling.
#
# What it does
# ------------
#   1. compares Rust's current stable with the one the image was built with
#      (the org.jkuracing.rust-stable label), and stops if they match
#   2. runs start.sh, which builds, recreates the containers and checks
#      that every runner registers
#   3. `docker image prune -f`, which deletes every untagged image on this
#      Docker host, not only the runners'
#
# Recreating a container drops its _work, so the next build of each repo per
# replica starts without a target/ dir. sccache keeps that fast.
#
# Usage:
#   ./update.sh            # rebuild only if stable changed
#   ./update.sh --force    # rebuild anyway, e.g. after editing the Dockerfile
#   ./update.sh --check    # only report whether a rebuild is due
set -euo pipefail
cd "$(dirname "$0")"

die() { printf '\033[31m!!  %s\033[0m\n' "$*" >&2; exit 1; }
say() { printf '\033[36m==> %s\033[0m\n' "$*"; }

mode=update
case "${1:-}" in
  --force) mode=force ;;
  --check) mode=check ;;
  "") ;;
  *) die "unknown option '$1' (use --force or --check)" ;;
esac

docker info >/dev/null 2>&1 || die "the docker daemon is not responding -- is OrbStack running?"

latest=$(./rust-stable-version.sh) || die "could not read the Rust stable version from static.rust-lang.org"

# Every runner service builds the same Dockerfile, so the first image speaks for
# all of them. An image built before the label existed reports nothing, which
# counts as out of date.
image=$(docker compose config --images | grep -- '-runner-' | head -1)
built=$(docker image inspect "$image" \
          --format '{{ index .Config.Labels "org.jkuracing.rust-stable" }}' 2>/dev/null || true)
say "Rust stable: ${latest} (image ${image} was built with: ${built:-unknown})"

if [ "$latest" = "$built" ] && [ "$mode" != force ]; then
  say "Up to date. Nothing to do."
  exit 0
fi
if [ "$mode" = check ]; then
  say "A rebuild is due. Run ./update.sh to do it."
  exit 0
fi

RUST_STABLE_VERSION="$latest" ./start.sh

say "Deleting the images this rebuild replaced"
docker image prune -f

say "Disk now"
docker system df
