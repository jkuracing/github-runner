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
#   ./provision.sh -n 3               # three runners on this Mac
#   ./provision.sh -n 3 --instance 2  # re-provision only the second of them
#
# MULTIPLE INSTANCES
# ------------------
# A runner agent takes exactly one job at a time and has no option to take
# more: it hands the job the whole machine -- $HOME, the tool cache, _work,
# every port -- with no boundary between one job and the next. Concurrency on
# one machine therefore means several runner agents, which is what `-n` sets
# up, and is the same shape the Linux fleet gets from N containers.
#
# Instance 1 is deliberately IDENTICAL to what this script produced before -n
# existed: same $HOME/actions-runner, same name, same daemon label, same
# ~/.cargo. Instances 2..N are siblings with a -2, -3 suffix. Numbering them
# all -1..-N would have been tidier, but it would rename the runner on every
# Mac already provisioned, leaving an orphaned registration online in the org
# and a LaunchDaemon this script no longer recognises as its own.
#
# Run it as yourself, NOT with sudo: the toolchain installs into $HOME, and the
# single privileged step (installing the LaunchDaemon) calls sudo on its own.
# You will be prompted for your password once, at that step.
#
set -euo pipefail

# Resolved HERE, before anything cd's. `$0` is whatever the caller typed, and
# for the documented invocation (`./macos/provision.sh` from the repo root)
# that is a RELATIVE path. Resolving it later -- after the `cd "$RUNNER_ROOT"`
# further down -- made `dirname "$0"` point at a ./macos that does not exist
# there, so the subshell failed, SELF became "/provision.sh", and the copy
# below aborted the whole run before the runner was ever registered.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

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
# How many runner agents this Mac should host, and optionally which single one
# of them to act on. ONLY_INSTANCE is what makes upgrading one instance safe:
# without it, re-running to fix instance 3 would tear down and re-register 1
# and 2 as well, which means three registration churns and three daemon
# restarts to fix one machine.
INSTANCES="${INSTANCES:-1}"
ONLY_INSTANCE=""
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
    -n|--instances)     INSTANCES="$2"; shift 2 ;;
    --instance)         ONLY_INSTANCE="$2"; shift 2 ;;
    --skip-toolchain)   SKIP_TOOLCHAIN=true; shift ;;
    --skip-registration) SKIP_REGISTRATION=true; shift ;;
    --dry-run)          DRY_RUN=true; shift ;;
    # The header IS the help, printed from line 2 to the last comment line
    # before the first statement. Derived rather than a hardcoded range: the
    # range was '2,36p' and had already fallen behind the header it prints.
    -h|--help)          sed -n '2,/^[^#]/p' "$0" | sed '$d'; exit 0 ;;
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
# `xcode-<major>` is deliberately NOT published, and the reason is worth
# recording because the opposite was tried. `xcode-27` is a GitHub-HOSTED image
# label. A workflow naming it in `runs-on` is routed to GitHub's hosted pool no
# matter how many self-hosted runners advertise the identical string, so the
# label cannot do the one job it was added for -- steering hbf's publish-gui.yml
# here. With no Actions budget the hosted pool answers by killing the run after
# six seconds with runner=null and a zero-byte log; observed twice with this Mac
# online and idle. publish-gui.yml now asks for `[self-hosted, macos-arm64]`
# instead, which this runner does serve. Advertising a reserved hosted label
# only invites someone to write `runs-on: xcode-27` again and lose another
# afternoon to it.
#
# The Xcode VERSION still matters -- see the check further down, which warns
# when it is older than 27 -- but that is a property to verify, not to publish
# as a label.
#
# `hbf-builder` is deliberately NOT here. Fifteen hbf jobs ask for it -- Format,
# Lint Rust, Test Rust, Test Rust (client), Test Rust (gui), the drift check, UI
# lint, Build Python and more -- and every one of them is written for the Linux
# fleet: apt-installed deps, the WebKitGTK/Tauri stack, AppImage packaging, the
# xdg-open shim, libudev. A runner is offered a job when its labels are a
# superset of the job's `runs-on`, so carrying that label would make all of them
# eligible to land on macOS and fail. Worse, it would fail NON-DETERMINISTICALLY
# -- the same commit passing or failing depending on which runner happened to be
# free, which is the hardest kind of CI fault to trust a bisect through.
#
# Advertise only what this machine can actually serve. macOS work is addressed
# by `macos` / `macos-arm64`, on top of the `self-hosted`, `macOS` and `ARM64`
# labels GitHub attaches by itself.
if [ -z "$LABELS" ]; then
  LABELS="macos,macos-${ARCH}"
fi

case "$INSTANCES" in
  ''|*[!0-9]*) fail "--instances takes a positive integer, got: $INSTANCES" ;;
esac
[ "$INSTANCES" -ge 1 ] || fail "--instances must be at least 1, got: $INSTANCES"
if [ -n "$ONLY_INSTANCE" ]; then
  case "$ONLY_INSTANCE" in
    ''|*[!0-9]*) fail "--instance takes a positive integer, got: $ONLY_INSTANCE" ;;
  esac
  { [ "$ONLY_INSTANCE" -ge 1 ] && [ "$ONLY_INSTANCE" -le "$INSTANCES" ]; } \
    || fail "--instance $ONLY_INSTANCE is outside 1..$INSTANCES (pass -n $ONLY_INSTANCE or higher)"
fi

if [ "$BUILD_JOBS" -eq 0 ] 2>/dev/null; then
  # Half the cores, because this Mac is expected to share itself with other
  # work. On the machine this was written for it also hosts the OrbStack Linux
  # fleet and a Parallels VM, and an unthrottled native build starves the
  # replicas badly enough that their runners drop with "lost communication".
  #
  # Divided again by the instance count, because that half is the budget for
  # RUNNER work as a whole, not per agent: N instances each sized for half the
  # box would oversubscribe it by N and reproduce exactly the starvation this
  # cap exists to prevent. An explicit --build-jobs is taken as given and is
  # NOT divided -- it is already an answer to this question.
  BUILD_JOBS=$(( $(sysctl -n hw.ncpu) / 2 / INSTANCES ))
  [ "$BUILD_JOBS" -lt 1 ] && BUILD_JOBS=1
fi

# --------------------------------------------------------------------------
# Per-instance derivation
#
# Instance 1 keeps every path and name this script used before -n existed; see
# the MULTIPLE INSTANCES note in the header for why the numbering is offset
# rather than uniform. Everything an instance must not share with its siblings
# is derived here, in one place, so the answer to "what is private to an
# instance?" is readable rather than scattered.
# --------------------------------------------------------------------------

instance_suffix() { [ "$1" -eq 1 ] && printf '' || printf -- '-%s' "$1"; }
instance_root()   { printf '%s%s' "$RUNNER_ROOT" "$(instance_suffix "$1")"; }
instance_name()   { printf '%s%s' "$NAME" "$(instance_suffix "$1")"; }

# CARGO_HOME is the one that bites hardest. Two concurrent builds sharing a
# cargo registry is not a tidiness problem, it is a build failure: the Linux
# fleet gives every replica its own registry volume after sharing one produced
#   error: could not compile `crc32fast` (lib)
#   Caused by: No such file or directory (os error 2)
# when another container's cargo garbage-collected unpacked sources mid-compile.
# Same user, same $HOME, same registry here -- so instances 2..N get their own.
#
# Instance 1 keeps ~/.cargo: it is already warm on every provisioned Mac, and
# moving it would re-download the index and every crate for no isolation gain
# (it is isolated from 2..N either way).
instance_cargo_home() {
  [ "$1" -eq 1 ] && printf '%s/.cargo' "$HOME" || printf '%s/.cargo' "$(instance_root "$1")"
}

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
info "Labels          : $LABELS"
info "Runs as         : $(id -un) (LaunchDaemon, starts at boot)"
info "CARGO_BUILD_JOBS: $BUILD_JOBS (per instance)"
info "Registration    : $SCOPE — $API"
info "Runner package  : actions-runner ${RUNNER_VERSION:-latest}"
info "Xcode           : $(xcodebuild -version 2>/dev/null | head -1 || echo 'NOT FOUND')"
info "Instances       : $INSTANCES${ONLY_INSTANCE:+ (acting on #$ONLY_INSTANCE only)}"

# The instance table is the whole point of --dry-run now: everything that must
# differ between siblings is derived above, so printing it here is what makes a
# derivation bug visible before it reaches a machine rather than after.
for i in $(seq 1 "$INSTANCES"); do
  [ -n "$ONLY_INSTANCE" ] && [ "$i" != "$ONLY_INSTANCE" ] && continue
  info "  #$i  name=$(instance_name "$i")  root=$(instance_root "$i")  CARGO_HOME=$(instance_cargo_home "$i")"
done

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
     27-era Icon Composer features. Upgrade Xcode, or expect that job to fail:
     this runner advertises macos-arm64 and will be offered it regardless."
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
# Runner package version
#
# Resolved once, ahead of the per-instance loop: it is a network call, and
# every instance on this Mac installs the same release.
# --------------------------------------------------------------------------

if [ -z "$RUNNER_VERSION" ]; then
  RUNNER_VERSION="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
    | jq -r .tag_name | sed 's/^v//')"
  [ -n "$RUNNER_VERSION" ] || fail "could not resolve the latest actions/runner release"
fi

# --------------------------------------------------------------------------
# Registration token
#
# Minted ONCE and reused by every instance. A registration token is not tied to
# a runner -- it authorises registering against this org or repo for about an
# hour -- so minting one per instance would mean N API calls, N chances to fail
# partway through a fleet, and on the gh path potentially N interactive
# prompts, all to obtain N interchangeable secrets.
#
# Three ways to get one, tried in order, matching windows/provision.ps1:
#
#   RUNNER_TOKEN  one minted elsewhere -- keeps a PAT off this machine entirely
#   GITHUB_PAT    a classic PAT
#   gh            nothing to pass at all
#
# The gh path is the one worth reaching for. Its credential is managed and
# revocable rather than a classic PAT pasted through a shell or parked in a
# .env, and there is nothing to create beforehand. It needs one grant, because
# gh's ordinary login carries read:org while registering an ORG runner needs
# admin:org -- so rather than telling you that, this asks gh to widen its own
# scope when a mint is refused.
# --------------------------------------------------------------------------

if [ "$SKIP_REGISTRATION" = false ]; then
  if [ -z "$REG_TOKEN" ] && [ -z "$PAT" ] && command -v gh >/dev/null 2>&1; then
    gh_scope=admin:org
    [ "$SCOPE" = repo ] && gh_scope=repo

    if ! gh auth status --hostname github.com >/dev/null 2>&1; then
      info "gh is not logged in; starting gh auth login"
      gh auth login --hostname github.com --scopes "$gh_scope" \
        || fail "gh auth login failed. Pass --pat, or set RUNNER_TOKEN."
    fi

    info "Minting a registration token via gh"
    REG_TOKEN="$(gh api -X POST "$API" --jq .token 2>/dev/null || true)"

    if [ -z "$REG_TOKEN" ] || [ "$REG_TOKEN" = null ]; then
      # Logged in but refused: overwhelmingly the scope. Ask for it rather than
      # printing an instruction and exiting.
      info "gh could not mint a token; requesting the '$gh_scope' scope"
      gh auth refresh --hostname github.com --scopes "$gh_scope" \
        || fail "gh auth refresh failed. Pass --pat, or set RUNNER_TOKEN."
      REG_TOKEN="$(gh api -X POST "$API" --jq .token 2>/dev/null || true)"
    fi

    [ -n "$REG_TOKEN" ] && [ "$REG_TOKEN" != null ] \
      || fail "gh still could not mint a registration token for $API (scope: $gh_scope)"
  fi

  if [ -z "$REG_TOKEN" ]; then
    [ -n "$PAT" ] || fail "no credential: set GITHUB_PAT, or RUNNER_TOKEN, or install gh (brew install gh)"
    info "Minting a registration token"
    REG_TOKEN="$(curl -fsSL -X POST \
      -H "Authorization: Bearer $PAT" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/$API" | jq -r .token)"
    [ -n "$REG_TOKEN" ] && [ "$REG_TOKEN" != null ] \
      || fail "could not mint a registration token — check the PAT's scope ($SCOPE)"
  fi
fi

# --------------------------------------------------------------------------
# provision_instance <index>
#
# Everything that belongs to ONE runner agent: its directory, its hooks, its
# environment, its registration and its daemon. The toolchain above is shared
# and deliberately outside this -- Homebrew, rustup and Xcode are per machine,
# not per runner, and installing them N times would only be slower.
# --------------------------------------------------------------------------

provision_instance() {
  idx="$1"
  inst_root="$(instance_root "$idx")"
  inst_name="$(instance_name "$idx")"
  inst_cargo="$(instance_cargo_home "$idx")"

  info ""
  info "=== instance #$idx: $inst_name ($inst_root) ==="

  mkdir -p "$inst_root"
  cd "$inst_root"

  if [ ! -x "$inst_root/config.sh" ]; then
    TARBALL="actions-runner-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
    # Downloaded once and kept for the rest of the run: every instance installs
    # the same release, and re-fetching ~200 MB per instance would be the
    # slowest part of provisioning a multi-instance machine. Removed after the
    # loop rather than here.
    if [ ! -f "/tmp/$TARBALL" ]; then
      info "Downloading $TARBALL"
      curl -fsSLo "/tmp/$TARBALL" \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${TARBALL}"
    fi
    info "Extracting runner to $inst_root"
    tar xzf "/tmp/$TARBALL" -C "$inst_root"
  fi

  # Install this script beside the runner it provisions, for the same reason
  # the Windows one does: re-running is how a machine is upgraded, and the copy
  # you first ran from is usually somewhere temporary. Written into every
  # instance root rather than just the first so that no root depends on another
  # one still existing, and rewritten on every run so the copies cannot drift.
  if [ "$SELF" != "$inst_root/provision.sh" ]; then
    cp -f "$SELF" "$inst_root/provision.sh"
    chmod +x "$inst_root/provision.sh"
  fi

  # ------------------------------------------------------------------------
  # Job hooks
  #
  # Fetched from this repo rather than embedded: unlike Windows, macOS runs the
  # same bash hooks the Linux fleet does, so duplicating them here would mean
  # two copies to keep in step. The sweep budget is the only knob that differs.
  # ------------------------------------------------------------------------

  mkdir -p "$inst_root/hooks"
  for hook in job-started-hook.sh job-completed-hook.sh; do
    if [ -f "$(dirname "$SELF")/../$hook" ]; then
      cp -f "$(dirname "$SELF")/../$hook" "$inst_root/hooks/$hook"
    else
      curl -fsSLo "$inst_root/hooks/$hook" \
        "https://raw.githubusercontent.com/jkuracing/github-runner/main/$hook" \
        || fail "could not obtain $hook"
    fi
    chmod +x "$inst_root/hooks/$hook"
  done
  info "Hooks installed to $inst_root/hooks"

  # PATH puts this instance's CARGO_HOME/bin first so that `cargo install`ed
  # tools resolve to the ones this instance owns. For instance 1 that IS
  # ~/.cargo/bin, so it is not listed twice.
  inst_path="$inst_cargo/bin"
  [ "$inst_cargo" = "$HOME/.cargo" ] || inst_path="$inst_path:$HOME/.cargo/bin"
  # ${BREW:-...} rather than a bare $BREW: BREW is only assigned inside the
  # toolchain block, so under --skip-toolchain (the documented "re-register
  # only" path) `set -u` would abort here on an unbound variable.
  inst_path="$inst_path:$(dirname "${BREW:-/opt/homebrew/bin/brew}"):/usr/bin:/bin:/usr/sbin:/sbin"

  # SWEEP_WORK_DIR is not optional here, and was missing before -n existed.
  # job-completed-hook.sh defaults it to /actions-runner/_work -- the path
  # inside a fleet CONTAINER, which does not exist on a Mac -- so the hook hit
  # its `[[ -d "$WORK_DIR" ]] || exit 0` guard and returned without sweeping
  # anything, every time. The disk budget has therefore never been enforced on
  # macOS. With several instances it also has to name THIS instance's _work, or
  # one instance would sweep another's build tree mid-compile.
  #
  # GIT_CONFIG_GLOBAL for the reason job-started-hook.sh now explains: that
  # hook resets git's global config before every job, and every instance on
  # this Mac runs as the same user. Sharing one ~/.gitconfig would mean
  # instance 2 starting a job deletes the config instance 1 is mid-job using.
  cat > "$inst_root/.env" <<ENV
CARGO_BUILD_JOBS=$BUILD_JOBS
CARGO_INCREMENTAL=0
CARGO_PROFILE_DEV_DEBUG=line-tables-only
CARGO_HOME=$inst_cargo
ACTIONS_RUNNER_HOOK_JOB_STARTED=$inst_root/hooks/job-started-hook.sh
ACTIONS_RUNNER_HOOK_JOB_COMPLETED=$inst_root/hooks/job-completed-hook.sh
SWEEP_MAX_GB=$SWEEP_MAX_GB
SWEEP_WORK_DIR=$inst_root/_work
GIT_CONFIG_GLOBAL=$inst_root/.gitconfig
PATH=$inst_path
ENV
  info "Wrote $inst_root/.env"

  if [ "$SKIP_REGISTRATION" = true ]; then
    info "Toolchain installed; registration skipped for #$idx."
    return 0
  fi

  # ------------------------------------------------------------------------
  # Registration
  # ------------------------------------------------------------------------

  # config.sh refuses to reconfigure an existing registration, and the daemon
  # holds the runner binary open, so an upgrade run has to unwind both. Any
  # actions.runner daemon pointing at THIS instance's root is ours, whatever it
  # was labelled on a previous run -- the name or the org could have changed
  # since.
  #
  # The match is on the exact WorkingDirectory element, not a bare grep for the
  # root. A substring test looks equivalent and is not: "actions-runner" is a
  # prefix of "actions-runner-2", so provisioning instance 1 would find its own
  # root inside instance 2's plist and bootout a healthy sibling -- which reads
  # as a runner that mysteriously went offline while a different one was being
  # upgraded. The closing tag is what makes the comparison exact.
  for old_plist in /Library/LaunchDaemons/actions.runner.*.plist; do
    [ -e "$old_plist" ] || continue
    if grep -qF "<string>${inst_root}</string>" "$old_plist" 2>/dev/null; then
      info "Stopping the existing daemon ($(basename "$old_plist"))"
      sudo launchctl bootout system "$old_plist" 2>/dev/null || true
      sudo rm -f "$old_plist"
    fi
  done
  # A LaunchAgent from an earlier version of this script, or from `svc.sh`.
  if [ -f "$inst_root/svc.sh" ] && ./svc.sh status >/dev/null 2>&1; then
    info "Removing the previous LaunchAgent"
    ./svc.sh stop || true
    ./svc.sh uninstall || true
  fi
  if [ -f "$inst_root/.runner" ]; then
    info "Removing the previous registration"
    ./config.sh remove --token "$REG_TOKEN" || warn "remove failed; continuing to reconfigure"
  fi

  info "Registering $inst_name"
  ./config.sh \
    --unattended --replace \
    --url "$URL" \
    --token "$REG_TOKEN" \
    --name "$inst_name" \
    --labels "$LABELS" \
    --work _work

  # A LaunchDaemon, not the LaunchAgent `svc.sh install` would create.
  #
  # svc.sh writes ~/Library/LaunchAgents/..., and an agent starts at LOGIN.
  # After a reboot the runner would not come back until someone logged in, and
  # jobs would sit queued with no error anywhere -- indistinguishable from a
  # stalled fleet until you go looking. This machine is meant to be unattended,
  # so the plist is written here instead.
  #
  # `UserName` is what makes a daemon usable rather than merely early: Homebrew
  # and rustup live in this user's home, so a root-owned daemon would run with
  # a PATH pointing at a toolchain in /var/root that does not exist. Running as
  # the invoking user keeps the toolchain, the cargo registry and the sccache
  # config exactly where the toolchain step put them.
  #
  # SessionCreate gives the job its own security session. Not needed for
  # today's ad-hoc signing (publish-gui.yml asserts `Signature=adhoc`), but it
  # is what a Developer ID identity in the login keychain would later need, and
  # it costs nothing now.
  #
  # The label carries the instance's name, which is unique per instance, so N
  # instances install N distinct daemons rather than fighting over one.
  DAEMON_LABEL="actions.runner.$(printf '%s' "$SLUG" | tr '/' '-').${inst_name}"
  PLIST="/Library/LaunchDaemons/${DAEMON_LABEL}.plist"

  # `runsvc.sh` is the plist's ProgramArguments, and nothing has created it yet:
  # the tarball ships it as bin/runsvc.sh, and the copy to the runner root is
  # done by `svc.sh install`, which this script deliberately does not call (that
  # is what would give us a login-time LaunchAgent instead of a boot-time
  # daemon). Skipping svc.sh therefore means inheriting this one step from it.
  #
  # Without it launchd exec's a path that does not exist. It reports that
  # nowhere useful: both daemon logs stay zero bytes, `launchctl print` shows
  # the service loaded, and the runner simply never appears online after a
  # reboot.
  #
  # Unconditional, and before the plist is written, so that re-running this
  # script repairs a machine already installed by a version that omitted it.
  cp -f "$inst_root/bin/runsvc.sh" "$inst_root/runsvc.sh" \
    || fail "could not copy bin/runsvc.sh to $inst_root/runsvc.sh"
  chmod +x "$inst_root/runsvc.sh"

  info "Installing LaunchDaemon $PLIST (runs as $(id -un), starts at boot)"
  sudo tee "$PLIST" >/dev/null <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${DAEMON_LABEL}</string>
  <key>ProgramArguments</key>
  <array><string>${inst_root}/runsvc.sh</string></array>
  <key>WorkingDirectory</key><string>${inst_root}</string>
  <key>UserName</key><string>$(id -un)</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>SessionCreate</key><true/>
  <key>StandardOutPath</key><string>${inst_root}/_diag/daemon.out.log</string>
  <key>StandardErrorPath</key><string>${inst_root}/_diag/daemon.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${HOME}</string>
    <key>PATH</key><string>${inst_path}</string>
  </dict>
</dict>
</plist>
PLISTEOF
  sudo chown root:wheel "$PLIST"
  sudo chmod 644 "$PLIST"
  mkdir -p "$inst_root/_diag"

  # bootout first so a re-run replaces cleanly; it fails when nothing is loaded,
  # which is fine and is why the failure is swallowed.
  sudo launchctl bootout system "$PLIST" 2>/dev/null || true
  sudo launchctl bootstrap system "$PLIST"
  sudo launchctl enable "system/${DAEMON_LABEL}"
  sleep 2
  sudo launchctl print "system/${DAEMON_LABEL}" 2>/dev/null | sed -n '1,6p' || \
    warn "launchctl print failed; check $inst_root/_diag/daemon.err.log"
}

for i in $(seq 1 "$INSTANCES"); do
  if [ -n "$ONLY_INSTANCE" ] && [ "$i" != "$ONLY_INSTANCE" ]; then
    continue
  fi
  provision_instance "$i"
done

# The shared download, now that every instance has unpacked it.
rm -f "/tmp/actions-runner-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"

info ""
if [ "$SKIP_REGISTRATION" = true ]; then
  # Nothing was registered, so promising a runner in the org's list would be a
  # lie -- and one that reads as a failure when nothing turns up there.
  info "Done. Toolchain and runner directories are ready; nothing was registered."
  info "Re-run without --skip-registration to register and install the daemons."
else
  if [ -n "$ONLY_INSTANCE" ]; then
    info "Done. Instance #$ONLY_INSTANCE should now appear under the org's Actions > Runners"
  else
    info "Done. $INSTANCES runner(s) should now appear under the org's Actions > Runners"
  fi
  info "with labels: $LABELS"
fi
info ""
if [ "$INSTANCES" -gt 1 ]; then
  info "Re-run to upgrade all:  $(instance_root 1)/provision.sh -n $INSTANCES"
  info "Re-run to upgrade one:  $(instance_root 1)/provision.sh -n $INSTANCES --instance <i>"
else
  info "Re-run to upgrade:  $(instance_root 1)/provision.sh"
fi
