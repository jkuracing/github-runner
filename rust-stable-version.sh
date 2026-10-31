#!/usr/bin/env bash
# Print the current Rust stable version (e.g. 1.99.1), as rustup would install
# it today. Exits non-zero, printing nothing, when the channel cannot be read.
#
# Read from the release channel manifest that rustup itself uses, so it moves
# exactly when `rustup toolchain install stable` would start installing
# something new -- point releases like 1.99.1 included, which a fixed six-week
# calendar misses.
set -euo pipefail

# The manifest's [pkg.rust] section starts with a line like
#   version = "1.99.1 (58cf8f9c3 2026-10-13)"
# awk reads to the end instead of exiting at the first match: under pipefail,
# an early exit closes the pipe under the writer, which then dies of SIGPIPE
# and fails the whole pipeline.
manifest=$(curl -fsSL --retry 3 --retry-delay 2 \
  https://static.rust-lang.org/dist/channel-rust-stable.toml)
version=$(printf '%s\n' "$manifest" \
  | awk '/^\[pkg\.rust\]/ { f = 1; next } f && !done && /^version/ { print $3; done = 1 }' \
  | tr -d '"')

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
echo "$version"
