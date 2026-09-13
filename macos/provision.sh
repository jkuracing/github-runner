#!/usr/bin/env bash
#
# Provisions a macOS self-hosted GitHub Actions runner for JKU Racing.
#
# The macOS counterpart to windows/provision.ps1, and a script for the same
# reason: there is no container story here. macOS cannot be virtualised into
# the Linux fleet, and Apple's licence ties macOS VMs to Apple hardware, so the
# runner is installed natively onto a Mac that is provisioned once and kept.
#
# Everything is idempotent. Re-running upgrades the toolchain in place and
# re-registers against a freshly minted token; that is the intended way to
# update a machine, not just to build a new one.
#
# Registration follows entrypoint.sh and the Windows script: a PAT mints a
# short-lived registration token on every run, because registration tokens
# expire after ~1 hour and a static one goes stale between provisioning and the
# next re-run.
#
# WHY THIS EXISTS
# ---------------
# The org has no GitHub Actions budget. Hosted jobs now fail before they start
# with "the job was not started because recent account payments have failed",
# which on a pull request reads as a broken PR rather than a broken account.
# Linux work moved to the fleet; macOS work had nowhere to go, because the
# fleet has no macOS. This gives it somewhere.
#
# What is currently stranded without it:
#   - hbf publish-gui.yml  : the Hbf.app bundle (needs Xcode 27, see below)
#   - hbf publish-binaries : macos-aarch64 and macos-x86_64 CLI binaries
#
# Usage:
#   export GITHUB_PAT=<classic PAT with admin:org>
#   ./provision.sh
#
#   ./provision.sh --dry-run          # derive everything, touch nothing
#   ./provision.sh --skip-toolchain   # re-register only
#
# Run it as yourself, NOT with sudo: the toolchain installs into $HOME, and the
# single privileged step (installing the LaunchDaemon) calls sudo on its own.
# You will be prompted for your password once, at that step.
#
set -euo pipefail

# --------------------------------------------------------------------------
# Defaults
# --------------------------------------------------------------------------

URL="${URL:-https://github.com/jkuracing}"
PAT="${GITHUB_PAT:-}"
# A token minted elsewhere, as an alternative to a PAT. entrypoint.sh accepts
# RUNNER_TOKEN for the same reason: it lets the PAT stay off this machine
# entirely -- mint the token where the PAT already lives and pass only the
# short-lived result. Expires in ~1 hour.
REG_TOKEN="${RUNNER_TOKEN:-}"
RUNNER_ROOT="${RUNNER_ROOT:-$HOME/actions-runner}"
# Empty means "resolve the latest release at run time", like every other
# download here. A hand-pinned version only goes stale: the runner self-updates
# on first contact with GitHub anyway, so pinning buys nothing and guarantees
# the first job runs on a just-replaced binary.
RUNNER_VERSION="${RUNNER_VERSION:-}"
NAME="${RUNNER_NAME:-mac-$(scutil --get ComputerName 2>/dev/null | tr ' ' '-' | tr -cd '[:alnum:]-' || hostname -s)}"
LABELS="${RUNNER_LABELS:-}"
BUILD_JOBS="${BUILD_JOBS:-0}"
SWEEP_MAX_GB="${SWEEP_MAX_GB:-8}"
SKIP_TOOLCHAIN=false
SKIP_REGISTRATION=false
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --url)              URL="$2"; shift 2 ;;
    --pat)              PAT="$2"; shift 2 ;;
    --token)            REG_TOKEN="$2"; shift 2 ;;
    --name)             NAME="$2"; shift 2 ;;
    --labels)           LABELS="$2"; shift 2 ;;
    --runner-root)      RUNNER_ROOT="$2"; shift 2 ;;
    --runner-version)   RUNNER_VERSION="$2"; shift 2 ;;
    --build-jobs)       BUILD_JOBS="$2"; shift 2 ;;
    --skip-toolchain)   SKIP_TOOLCHAIN=true; shift ;;
    --skip-registration) SKIP_REGISTRATION=true; shift ;;
    --dry-run)          DRY_RUN=true; shift ;;
    -h|--help)          sed -n '2,36p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

info() { printf '\033[36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m!!  %s\033[0m\n' "$*"; }
fail() { printf '\033[31m!!  %s\033[0m\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------------------
# Refuse to run the WHOLE script as root
#
# Not about account isolation -- the runner deliberately runs as the invoking
# user (see the LaunchDaemon section). It is about where the toolchain lands.
# Homebrew and rustup install into $HOME, so `sudo ./provision.sh` would put
# them in /var/root, leave root-owned files behind, and hand the runner a PATH
# pointing at a toolchain its user cannot read.
#
# The one step that genuinely needs privilege -- writing the LaunchDaemon into
# /Library/LaunchDaemons -- calls sudo itself, and only there.
# --------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] && fail "run this as your normal user, not with sudo. Homebrew and rustup install into \$HOME; the one privileged step calls sudo itself."

[ "$(uname -s)" = "Darwin" ] || fail "this is the macOS provisioner; use the Dockerfile on Linux or windows/provision.ps1 on Windows"

# --------------------------------------------------------------------------
# Derivation
# --------------------------------------------------------------------------

case "$(uname -m)" in
  arm64)  ARCH=arm64;  RUNNER_ARCH=osx-arm64 ;;
  x86_64) ARCH=x64;    RUNNER_ARCH=osx-x64 ;;
  *) fail "unsupported architecture: $(uname -m)" ;;
esac

# Labels name what the machine IS, not what it builds -- the same rule the
# Windows script follows. An arm64 Mac cross-compiles x86_64-apple-darwin
# perfectly well, so labelling it "macos-x64" would be a lie that breaks the
# day someone adds an Intel Mac.
#
# `xcode-27` is deliberate and is NOT a description of the hardware: it is the
# label hbf's publish-gui.yml already targets, because Icon Composer saved
# hbf-gui/icons/icon.icon with 27-era features that Xcode 26.6's actool cannot
# open. Carrying the label here lets that workflow move off the hosted image
# with no edit at all. Drop it from --labels if this Mac is ever downgraded
# below Xcode 27, or that workflow will be routed here and fail on the icon.
if [ -z "$LABELS" ]; then
  LABELS="macos,macos-${ARCH},hbf-builder"
  if [ -n "${XCODE_MAJOR:-}" ] || xcodebuild -version >/dev/null 2>&1; then
    XCODE_MAJOR="${XCODE_MAJOR:-$(xcodebuild -version 2>/dev/null | awk 'NR==1{split($2,v,"."); print v[1]}')}"
    [ -n "$XCODE_MAJOR" ] && LABELS="${LABELS},xcode-${XCODE_MAJOR}"
  fi
fi

if [ "$BUILD_JOBS" -eq 0 ] 2>/dev/null; then
  # Half the cores, because this Mac is expected to share itself with other
  # work. On the machine this was written for it also hosts the OrbStack Linux
  # fleet and a Parallels VM, and an unthrottled native build starves the
  # replicas badly enough that their runners drop with "lost communication".
  BUILD_JOBS=$(( $(sysctl -n hw.ncpu) / 2 ))
  [ "$BUILD_JOBS" -lt 1 ] && BUILD_JOBS=1
fi

# Strip the host BEFORE counting separators. Matching slashes on the whole URL
# looks right and is not: "https://github.com/jkuracing" already carries three,
# so an org URL derives a repo endpoint and registration fails with a 404 that
# blames the PAT's scope. What distinguishes the two is owner vs owner/repo in
# the remainder.
SLUG="${URL#https://github.com/}"
SLUG="${SLUG%/}"
case "$SLUG" in
  */*) API="repos/${SLUG}/actions/runners/registration-token"; SCOPE=repo ;;
  *)   API="orgs/${SLUG}/actions/runners/registration-token";  SCOPE=org ;;
esac

info "Architecture    : $ARCH (runner package: $RUNNER_ARCH)"
info "Runner name     : $NAME"
info "Labels          : $LABELS"
info "Runs as         : $(id -un) (LaunchDaemon, starts at boot)"
info "CARGO_BUILD_JOBS: $BUILD_JOBS"
info "Registration    : $SCOPE — $API"
info "Runner root     : $RUNNER_ROOT (actions-runner ${RUNNER_VERSION:-latest})"
info "Xcode           : $(xcodebuild -version 2>/dev/null | head -1 || echo 'NOT FOUND')"

if [ "$DRY_RUN" = true ]; then
  info "--dry-run: nothing was changed."
  exit 0
fi

# --------------------------------------------------------------------------
# Xcode
#
# Not installed by this script. Xcode is a ~20 GB Apple-account-gated download,
# and choosing which version a build machine carries is a decision, not a
# detail -- see the xcode-27 note above. So this verifies and explains instead.
# --------------------------------------------------------------------------

if ! xcodebuild -version >/dev/null 2>&1; then
  fail "Xcode is not installed or not selected.
     Install Xcode (27 or newer for hbf's icon pipeline), then:
       sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
       sudo xcodebuild -license accept"
fi
XCODE_MAJOR="$(xcodebuild -version | awk 'NR==1{split($2,v,"."); print v[1]}')"
if [ "${XCODE_MAJOR:-0}" -lt 27 ]; then
  warn "Xcode $XCODE_MAJOR is older than 27. hbf's publish-gui.yml will fail in
     actool with \"Could not open\" on hbf-gui/icons/icon.icon, which uses
     27-era Icon Composer features. Remove xcode-* from --labels, or upgrade."
fi

# The command line tools are separate from Xcode.app and some crates' build
# scripts reach for them directly.
xcode-select -p >/dev/null 2>&1 || sudo xcode-select --install || true

# --------------------------------------------------------------------------
# Toolchain
# --------------------------------------------------------------------------

if [ "$SKIP_TOOLCHAIN" = false ]; then
  if ! command -v brew >/dev/null 2>&1; then
    info "Installing Homebrew"
    NONINTERACTIVE=1 /bin/bash -c \
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  # Homebrew's prefix differs by arch and is not on PATH for a fresh shell.
  BREW="$( [ "$ARCH" = arm64 ] && echo /opt/homebrew/bin/brew || echo /usr/local/bin/brew )"
  eval "$("$BREW" shellenv)"

  info "Installing packages"
  # bun: hbf's GUI build bundles the UI with it before cargo runs.
  # cmake/pkg-config: transitive build deps of the serialport and GUI stacks.
  # jq: used by this script and by several workflows.
  "$BREW" install --quiet bun cmake pkg-config jq || warn "brew install reported a problem; continuing"

  if ! command -v rustup >/dev/null 2>&1; then
    info "Installing rustup"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
  fi
  # shellcheck disable=SC1091
  . "$HOME/.cargo/env"
  rustup toolchain install stable --profile minimal
  # Both Darwin targets: publish-binaries builds macos-aarch64 and
  # macos-x86_64, and the GUI bundle is a universal2 lipo of the two.
  rustup target add aarch64-apple-darwin x86_64-apple-darwin
  info "Rust: $(rustc --version)"
fi

# --------------------------------------------------------------------------
# Runner
# --------------------------------------------------------------------------

mkdir -p "$RUNNER_ROOT"
cd "$RUNNER_ROOT"

if [ -z "$RUNNER_VERSION" ]; then
  RUNNER_VERSION="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
    | jq -r .tag_name | sed 's/^v//')"
  [ -n "$RUNNER_VERSION" ] || fail "could not resolve the latest actions/runner release"
fi

if [ ! -x "$RUNNER_ROOT/config.sh" ]; then
  TARBALL="actions-runner-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
  info "Downloading $TARBALL"
  curl -fsSLo "/tmp/$TARBALL" \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${TARBALL}"
  tar xzf "/tmp/$TARBALL" -C "$RUNNER_ROOT"
  rm -f "/tmp/$TARBALL"
fi

# Install this script beside the runner it provisions, for the same reason the
# Windows one does: re-running is how a machine is upgraded, and the copy you
# first ran from is usually somewhere temporary.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
if [ "$SELF" != "$RUNNER_ROOT/provision.sh" ]; then
  cp -f "$SELF" "$RUNNER_ROOT/provision.sh"
  chmod +x "$RUNNER_ROOT/provision.sh"
  info "Installed this script to $RUNNER_ROOT/provision.sh"
fi

# --------------------------------------------------------------------------
# Job hooks
#
# Fetched from this repo rather than embedded: unlike Windows, macOS runs the
# same bash hooks the Linux fleet does, so duplicating them here would mean two
# copies to keep in step. The sweep budget is the only knob that differs.
# --------------------------------------------------------------------------

mkdir -p "$RUNNER_ROOT/hooks"
for hook in job-started-hook.sh job-completed-hook.sh; do
  if [ -f "$(dirname "$SELF")/../$hook" ]; then
    cp -f "$(dirname "$SELF")/../$hook" "$RUNNER_ROOT/hooks/$hook"
  else
    curl -fsSLo "$RUNNER_ROOT/hooks/$hook" \
      "https://raw.githubusercontent.com/jkuracing/github-runner/main/$hook" \
      || fail "could not obtain $hook"
  fi
  chmod +x "$RUNNER_ROOT/hooks/$hook"
done
info "Hooks installed to $RUNNER_ROOT/hooks"

cat > "$RUNNER_ROOT/.env" <<ENV
CARGO_BUILD_JOBS=$BUILD_JOBS
CARGO_INCREMENTAL=0
CARGO_PROFILE_DEV_DEBUG=line-tables-only
ACTIONS_RUNNER_HOOK_JOB_STARTED=$RUNNER_ROOT/hooks/job-started-hook.sh
ACTIONS_RUNNER_HOOK_JOB_COMPLETED=$RUNNER_ROOT/hooks/job-completed-hook.sh
SWEEP_MAX_GB=$SWEEP_MAX_GB
PATH=$HOME/.cargo/bin:$(dirname "$BREW" 2>/dev/null || echo /opt/homebrew/bin):/usr/bin:/bin:/usr/sbin:/sbin
ENV
info "Wrote $RUNNER_ROOT/.env"

if [ "$SKIP_REGISTRATION" = true ]; then
  info "Toolchain installed; registration skipped."
  exit 0
fi

# --------------------------------------------------------------------------
# Registration
# --------------------------------------------------------------------------

if [ -z "$REG_TOKEN" ]; then
  [ -n "$PAT" ] || fail "need GITHUB_PAT (classic, admin:org for an org runner) or RUNNER_TOKEN"
  info "Minting a registration token"
  REG_TOKEN="$(curl -fsSL -X POST \
    -H "Authorization: Bearer $PAT" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/$API" | jq -r .token)"
  [ -n "$REG_TOKEN" ] && [ "$REG_TOKEN" != null ] \
    || fail "could not mint a registration token — check the PAT's scope ($SCOPE)"
fi

# config.sh refuses to reconfigure an existing registration, and the daemon
# holds the runner binary open, so an upgrade run has to unwind both. Any
# actions.runner daemon here is ours, whatever it was labelled on a previous
# run -- the name or the org could have changed since.
for old_plist in /Library/LaunchDaemons/actions.runner.*.plist; do
  [ -e "$old_plist" ] || continue
  if grep -q "$RUNNER_ROOT" "$old_plist" 2>/dev/null; then
    info "Stopping the existing daemon ($(basename "$old_plist"))"
    sudo launchctl bootout system "$old_plist" 2>/dev/null || true
    sudo rm -f "$old_plist"
  fi
done
# A LaunchAgent from an earlier version of this script, or from `svc.sh`.
if [ -f "$RUNNER_ROOT/svc.sh" ] && ./svc.sh status >/dev/null 2>&1; then
  info "Removing the previous LaunchAgent"
  ./svc.sh stop || true
  ./svc.sh uninstall || true
fi
if [ -f "$RUNNER_ROOT/.runner" ]; then
  info "Removing the previous registration"
  ./config.sh remove --token "$REG_TOKEN" || warn "remove failed; continuing to reconfigure"
fi

info "Registering $NAME"
./config.sh \
  --unattended --replace \
  --url "$URL" \
  --token "$REG_TOKEN" \
  --name "$NAME" \
  --labels "$LABELS" \
  --work _work

# A LaunchDaemon, not the LaunchAgent `svc.sh install` would create.
#
# svc.sh writes ~/Library/LaunchAgents/..., and an agent starts at LOGIN. After
# a reboot the runner would not come back until someone logged in, and jobs
# would sit queued with no error anywhere -- indistinguishable from a stalled
# fleet until you go looking. This machine is meant to be unattended, so the
# plist is written here instead.
#
# `UserName` is what makes a daemon usable rather than merely early: Homebrew
# and rustup live in this user's home, so a root-owned daemon would run with a
# PATH pointing at a toolchain in /var/root that does not exist. Running as the
# invoking user keeps the toolchain, the cargo registry and the sccache config
# exactly where the toolchain step put them.
#
# SessionCreate gives the job its own security session. Not needed for today's
# ad-hoc signing (publish-gui.yml asserts `Signature=adhoc`), but it is what a
# Developer ID identity in the login keychain would later need, and it costs
# nothing now.
DAEMON_LABEL="actions.runner.$(printf '%s' "$SLUG" | tr '/' '-').${NAME}"
PLIST="/Library/LaunchDaemons/${DAEMON_LABEL}.plist"

info "Installing LaunchDaemon $PLIST (runs as $(id -un), starts at boot)"
sudo tee "$PLIST" >/dev/null <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${DAEMON_LABEL}</string>
  <key>ProgramArguments</key>
  <array><string>${RUNNER_ROOT}/runsvc.sh</string></array>
  <key>WorkingDirectory</key><string>${RUNNER_ROOT}</string>
  <key>UserName</key><string>$(id -un)</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>SessionCreate</key><true/>
  <key>StandardOutPath</key><string>${RUNNER_ROOT}/_diag/daemon.out.log</string>
  <key>StandardErrorPath</key><string>${RUNNER_ROOT}/_diag/daemon.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${HOME}</string>
    <key>PATH</key><string>${HOME}/.cargo/bin:$(dirname "${BREW:-/opt/homebrew/bin/brew}"):/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
</dict>
</plist>
PLISTEOF
sudo chown root:wheel "$PLIST"
sudo chmod 644 "$PLIST"
mkdir -p "$RUNNER_ROOT/_diag"

# bootout first so a re-run replaces cleanly; it fails when nothing is loaded,
# which is fine and is why the failure is swallowed.
sudo launchctl bootout system "$PLIST" 2>/dev/null || true
sudo launchctl bootstrap system "$PLIST"
sudo launchctl enable "system/${DAEMON_LABEL}"
sleep 2
sudo launchctl print "system/${DAEMON_LABEL}" 2>/dev/null | sed -n '1,6p' || \
  warn "launchctl print failed; check $RUNNER_ROOT/_diag/daemon.err.log"

info ""
info "Done. The runner should now appear under the org's Actions > Runners"
info "with labels: $LABELS"
info ""
info "Re-run to upgrade:  $RUNNER_ROOT/provision.sh"
