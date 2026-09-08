# Self-hosted GitHub Runners

Self-hosted GitHub Actions runners configured for JKU Racing firmware
development: a Docker image for Linux (`amd64`/`arm64`), and a native
PowerShell provisioning script for Windows (see [Windows runners](#windows-runners)).

## Pre-installed Tools

This runner includes all tools required for the firmware CI pipeline:

### Rust Development

- **Rust stable toolchain** with `rustfmt` and `clippy`
- **ESP-IDF Xtensa toolchain** for ESP32-S3 development (`espup`)
- **cargo-nextest** for fast test execution

### Build Tools

- **just** - Command runner used by the firmware project
- **Pkl** (v0.31.1) - Apple's configuration language (used by canvas); `/usr/local/bin`
  is writable by the `runner` user so consuming workflows can self-install a
  different pinned version without hitting `EACCES`
- **maturin** - Build Python wheels from Rust code

### Python

- **Python 3.12** with development headers
- **uv** - Fast Python package manager
- **python3-cffi** - C FFI for Python

### Other

- **SSH** - Pre-configured with GitHub's host keys for private submodule access
- Standard build essentials (`build-essential`, `pkg-config`, `libssl-dev`)
- **WebKitGTK / Tauri stack** for hbf's desktop app, plus `file` for appimagetool

## Architectures

The image builds for both `linux/amd64` and `linux/arm64` (e.g. Apple Silicon via
OrbStack/Docker Desktop). Architecture-specific downloads (GitHub Actions runner,
Pkl) are selected from BuildKit's `TARGETARCH`; the Rust, ESP (`espup`) and Python
toolchains resolve their own host architecture.

Docker Compose and `docker build` produce a native image by default. To build
explicitly for one architecture:

```bash
docker buildx build --platform linux/arm64 -t github-runner .
```

> Note: if `TARGETARCH` is unset (a build without BuildKit), the Dockerfile falls
> back to `dpkg --print-architecture`, i.e. the base image's own architecture.

## Usage

### Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `URL` | Yes | GitHub repository or organization URL |
| `GITHUB_PAT` | One of `GITHUB_PAT` / `RUNNER_TOKEN` | Personal access token used to mint a fresh registration token on every container start. Preferred, since it never goes stale. Needs `admin:org` scope (classic PAT) for org-level runners, or `repo`/Administration for repo-level runners. |
| `RUNNER_TOKEN` | One of `GITHUB_PAT` / `RUNNER_TOKEN` | Static runner registration token from GitHub. Expires ~1 hour after creation, so restarts after that will fail unless refreshed. Ignored if `GITHUB_PAT` is set. |
| `RUNNER_NAME` | No | Base name for the runner (default: `runner`) |
| `RUNNER_LABELS` | No | Comma-separated labels for the runner |
| `RUNNER_CPUS` | No | CPUs per replica; also caps `CARGO_BUILD_JOBS` (default: `2`) |
| `RUNNER_MEMORY` | No | Memory per replica (default: `6g`) |

### Parallel Jobs

A GitHub Actions runner executes **one job at a time** — there is no concurrency
setting inside the runner. Total parallelism is therefore just `RUNNER_COUNT`.

Eight replicas (`runner-1` .. `runner-8`) are declared explicitly in
`docker-compose.yml`, at 2 CPUs and 6 GB each, sized for a 16-core / 64 GB host.
`CARGO_BUILD_JOBS` is pinned to `RUNNER_CPUS` — without that, cargo sizes its
thread pool from the *host* core count and every replica would spawn ~16
threads, oversubscribing the machine.

**Memory, not CPU, is what limits the replica count.** 8 x 6 GB = 48 GB of the
~58 GB the OrbStack VM exposes. Adding replicas without lowering `RUNNER_MEMORY`
will overcommit and get builds OOM-killed.

A single CI run only reaches 5 concurrent jobs (four checks in parallel, then
three builds behind `needs`). The reason more replicas still help is that
`concurrency` in `firmware_ci.yml` is keyed per *branch*, so several runs
execute at once and jobs queue globally.

To run fewer runners, name the services; to run bigger ones, raise the limits:

```bash
docker compose up -d --build runner-1 runner-2 runner-3
RUNNER_CPUS=4 RUNNER_MEMORY=10g docker compose up -d --build
```

> Replicas are separate services rather than `deploy.replicas` because a scaled
> service shares one set of volumes, and sccache cannot safely share a cache
> directory between concurrent server processes (see below).

### Caching

Two caches survive container recreation, both **per replica**:

- **`cargo-registry-N`** — the crate download cache.
- **`sccache-N`** — the compiler cache. `setup-rust-dual` in the firmware repo
  points sccache at `$HOME/.cache/sccache`.

Neither may be shared between replicas. sccache keeps its LRU index in memory
per server process, so containers sharing one directory evict against each
other. The registry was shared in an earlier revision and broke CI: unpacked
sources under `registry/src` disappear mid-compile when another container's
cargo garbage-collects the global cache, producing
`could not execute process ... No such file or directory`. The cost of not
sharing is N copies of the same crate downloads, which is the right trade.

The runner's `_work` directory is deliberately **not** persisted. The firmware
workflow checks out with `clean: false` to reuse `target/`, but a stale
submodule `target/` surviving `git submodule deinit` is what produced
`could not parse/generate dep info ... No such file or directory` build
failures. sccache is content-hashed and immune to that staleness, so it is the
right layer to persist; `_work` is not.

### Running with Docker Compose

```bash
# Set environment variables
export URL=https://github.com/jkuracing
export GITHUB_PAT=<your-pat>

# Start the runners
docker compose up -d --build
```

> Always pass `--build`. Plain `docker compose up -d` only builds when the image
> is missing, so it will happily keep running a stale image after the Dockerfile
> or `entrypoint.sh` changes.

## x86_64 runners on an Apple Silicon host

`runner-amd64-1` and `runner-amd64-2` are `linux/amd64` containers on the same
aarch64 host. OrbStack runs them through **Rosetta**, not qemu, so this is
translation at roughly native speed rather than emulation at a fraction of it.

They carry their own labels — `hbf-builder-amd64,fw-builder-amd64` — rather
than the shared `fw-builder,hbf-builder` pair. A runner is offered a job when
its labels are a *superset* of the job's `runs-on`, so adding `hbf-builder`
here would let ordinary aarch64 work land on a translated container and run
slower for nothing.

**Why not cross-compile from aarch64 instead.** hbf's binaries pull in
`tokio-serial` → `serialport`, which links `libudev` on Linux. `cargo-zigbuild`
supplies a cross C toolchain but not an x86_64 `libudev` sysroot, so a cross
build needs a hand-maintained multiarch sysroot. An amd64 runner needs neither:
the image installs `libudev-dev` for whatever architecture it is built for.

Two replicas rather than twelve — x86_64 artifacts are published from pushes to
`main`, not from every PR, so this is a low-duty-cycle lane sized not to
compete with the aarch64 fleet for the host.

They sit behind a compose **profile**, so a bare `docker compose up -d --build`
starts the twelve aarch64 runners and nothing else — the x86_64 lane is opt-in:

```bash
docker compose --profile amd64 up -d --build
```

### Can x86_64 work leak onto this lane?

Only if a workflow asks for it. Label matching is an exact-string superset
test, not a prefix match, so `hbf-builder-amd64` does **not** satisfy a job
requesting `hbf-builder`. Every self-hosted job in the org names an exact
label today (`[fw-builder]`, `[hbf-builder]`, `[windows-arm64]`), so nothing
can drift here by accident.

The one way it could: GitHub adds implicit `self-hosted`, `Linux` and `X64` /
`ARM64` labels to every runner, so a future job written as
`runs-on: self-hosted` or `runs-on: [self-hosted, Linux]` would match these
containers as readily as the native ones. Name the builder label explicitly and
that cannot happen.

## Windows runners

Linux runs in Docker; Windows does not. Windows containers cannot run on the
ARM64 Parallels VM this targets, so a Windows runner is provisioned natively
onto a machine that is set up once and kept. `windows/provision.ps1` is that
provisioning, and it is idempotent -- re-running it upgrades the toolchain and
re-registers against a freshly minted token, which is the intended way to
update a machine rather than only to build one.

`provision.ps1` is **one self-contained file** and the whole procedure. It
needs nothing else from this repo -- the job hooks are embedded and written out
during provisioning -- and it handles x64 and ARM64 identically.

On a blank Windows machine, in an **elevated** PowerShell:

```powershell
# See exactly what it would do, without touching anything:
powershell -NoProfile -ExecutionPolicy Bypass -File .\provision.ps1 `
    -ServiceAccount '.\ci' -DryRun

# Then for real:
powershell -NoProfile -ExecutionPolicy Bypass -File .\provision.ps1 `
    -ServiceAccount '.\ci'
```

**`-ExecutionPolicy Bypass` is not decoration.** A default Windows install
refuses to run an unsigned `.ps1` invoked by path, with
`PSSecurityException: running scripts is disabled on this system`. Passing it
on the `powershell.exe` command line scopes the exemption to that single
process, which is why the script is invoked this way rather than asking you to
change the machine's policy.

Or fetch just that file onto a fresh machine first:

```powershell
$u = 'https://raw.githubusercontent.com/jkuracing/github-runner/main/windows/provision.ps1'
Invoke-WebRequest $u -OutFile provision.ps1 -UseBasicParsing
```

That single run installs the toolchain, offers to create the service account,
logs in to GitHub, registers the runner as a service and starts it. Nothing
needs preparing beforehand -- no PAT to mint, no account to create.

It prompts for exactly two things, both yours, neither stored or displayed by
the script:

- **the runner account's password**, if the account does not exist yet and you
  ask it to create one. Read twice and compared, because a typo here does not
  fail here -- it fails later, as a service that installs cleanly and then
  refuses to start.
- **your GitHub login**, through `gh`'s own flow.

`config.cmd` then asks for the account password a second time. That is
deliberate rather than an oversight: it keeps the password inside the runner
instead of on a command line, where `--windowslogonpassword` would put it.

### PowerShell execution policy

A default Windows install will not run an unsigned `.ps1` invoked by path. This
bites in two separate places, and both are handled rather than worked around by
loosening the machine's policy -- that is a system-wide security setting, and
changing it so this repo's own two hooks can run would be a poor trade.

**Invoking the provisioner.** Every documented command goes through
`powershell -NoProfile -ExecutionPolicy Bypass -File ...`, which scopes the
exemption to that one process. Running `.\provision.ps1` directly fails with:

```
File ...\provision.ps1 cannot be loaded because running scripts is disabled
on this system.
    + FullyQualifiedErrorId : UnauthorizedAccess
```

**Workflow steps.** The runner writes each `run:` block to a temp `.ps1` and
invokes it the same way, so on a machine at the Windows default every step
without an explicit `shell:` fails too. Consuming workflows should set
`defaults.run.shell: bash` for jobs on these runners — hbf's do.

**The job hooks.** The runner invokes a `.ps1` hook as
`powershell.EXE -command ". '<path>'"` with no `-ExecutionPolicy`, and that is
not configurable. Because a non-zero hook fails the job, an unsigned `.ps1`
hook kills **every job** in the `Set up runner` step, before a single workflow
line executes:

```
Set up runner   . : File C:\actions-runner\hooks\job-started-hook.ps1 cannot
                    be loaded because running scripts is disabled on this system
                ##[error]Process completed with exit code 1.
```

So `ACTIONS_RUNNER_HOOK_JOB_STARTED` / `_COMPLETED` point at generated `.sh`
wrappers instead, which re-invoke the `.ps1` with the bypass. Both the wrappers
and the scripts live in `<RunnerRoot>\hooks\`.

`.sh` specifically, not `.cmd`: the runner accepts only `.sh`, `.ps1` or `.js`
and rejects anything else with *"is not a valid path to a script"*. bash is
guaranteed here regardless, since Git for Windows is already mandatory for
`shell: bash` steps. The wrappers hardcode the absolute Windows path rather
than deriving it from `$0`, because Git Bash reports a POSIX path
(`/c/actions-runner/...`) that `powershell -File` cannot resolve, and they are
written with LF endings -- a shell script with CRLF fails as a confusing
"not found".

### Unattended runs

Every interactive path degrades to a printed instruction rather than a hang,
which matters because a `prlctl exec`, WinRM or scheduled-task session has no
console for `gh` to prompt on, and a hang there is worse than a failure.
Detection is `[Environment]::UserInteractive -and -not [Console]::IsInputRedirected`.

For those sessions, split the run:

```powershell
# Long and unattended: toolchain only.
powershell -NoProfile -ExecutionPolicy Bypass -File .\provision.ps1 `
    -ServiceAccount '.\ci' -SkipRegistration

# Short and interactive, on the machine itself.
powershell -NoProfile -ExecutionPolicy Bypass -File C:\actions-runner\provision.ps1 `
    -ServiceAccount '.\ci' -SkipToolchain
```

The script installs a copy of itself at `<RunnerRoot>\provision.ps1`, so the
second half -- and any later upgrade -- is the same command on every machine,
regardless of where the first half was run from.

### Credentials

Registration tries, in order: `-RegistrationToken` / `RUNNER_TOKEN`, then
`-Pat` / `GITHUB_PAT`, then `gh`. The gh path is the default and the one worth
using -- its credential is managed and revocable rather than a classic PAT
pasted through a shell. `-RegistrationToken` is the one that keeps a PAT off
the provisioned machine entirely: mint it where the credential already lives
and pass only the ~1h result.

gh's ordinary login carries `read:org` while registering an **org** runner
needs `admin:org`, so the script asks gh to widen its own scope when a mint is
refused rather than telling you to. A **repo**-scoped runner
(`-Url https://github.com/<owner>/<repo>`) needs admin on that repo instead,
and an org that disables repo-level runners reports that as a `404` rather than
a permission error.

### The service account is not optional, and must not be SYSTEM

`config.cmd` prompts for the account's password itself, so it never reaches a
command line, an environment variable, or this repo. Create the account first
(you choose the password); the script refuses to invent one:

```powershell
New-LocalUser -Name 'ci' -Description 'GitHub Actions runner' -PasswordNeverExpires
```

Running jobs as LocalSystem is rejected outright, because two independent
things break under it and both were found the hard way:

- tauri caches its NSIS toolchain under `%LOCALAPPDATA%\tauri\NSIS`. Under
  SYSTEM that resolves inside `systemprofile`, the download reports success,
  nothing lands, and the bundler dies with `Unable to start child process,
  error 0x2` -- which is `ERROR_FILE_NOT_FOUND`, not the x86-emulation failure
  it reads as.
- `node_modules` created by a SYSTEM build is owned by SYSTEM, and any later
  build under another account hangs or fails `EPERM` on it.

### Architecture

The runner is labelled by what the machine **is** (`windows-arm64` or
`windows-x64`), not by what it builds. An ARM64 Windows box cross-compiles
`x86_64-pc-windows-msvc` perfectly well -- verified end to end, including an
NSIS installer whose payload is PE machine `0x8664` -- so labelling an ARM64
machine `windows-x64` would be a lie that breaks the first time a real x64
machine joins.

`makensis.exe` is a 32-bit x86 binary and runs under ARM64's emulation, the
same way the amd64-only `pkl` this toolchain installs does. Nothing about the
Windows packaging path requires an x64 host.

### Toolchain

Established empirically against hbf rather than from vendor docs:

| Tool | Why |
|------|-----|
| Git for Windows | **Required.** Every composite action these workflows use declares `shell: bash`, which resolves to `bash.exe` on PATH. Without it the runner registers and then fails every job. |
| VS Build Tools | The MSVC linker. `*-pc-windows-msvc` cannot link without it. |
| Rust + both MSVC targets | Either direction of cross-compilation from one machine. |
| `cargo-nextest` | hbf's suite needs it; plain `cargo test` produces phantom 30s timeouts. |
| clang (LLVM) | **ARM64 only** -- `ring` assembles its crypto with it there. x64 links with MSVC alone. |
| Pkl | A build script shells out to it. No ARM64 build exists; the amd64 exe runs emulated. |
| bun | `hbf-gui`'s `generate_context!` embeds `ui/build` at *compile* time. |
| WebView2 | Preinstalled on Windows 11; checked, not assumed. |
| `gh` | Mints the runner registration token, so no PAT is needed. |
| `uv` + CPython | Workflow steps assume Python: `publish-gui.yml` resolves the workspace version with `python3 -c 'import tomllib...'`. Installed machine-wide via `UV_PYTHON_INSTALL_DIR`, with a `python3.exe` copy beside `python.exe` because Windows CPython ships only the latter while every step written for Linux says `python3`. |
| `jq` | The shared `vs-registry-auth` action parses the registry config with it. Absent, that check fails as *"returned 200 but not the registry config (SSO page?)"* — pointing at the registry rather than at the missing binary. Linux gets jq from its base packages, so this gap is Windows-only. |

`winget` is deliberately unused -- it hangs under a non-interactive remote
session on this VM, so every install is `curl` plus a silent installer.

### Hooks and machine environment

The job hooks are embedded in `provision.ps1` and written to
`<RunnerRoot>\hooks\` during provisioning -- that is what keeps the script a
single file. They are PowerShell twins of the `.sh` hooks, for the same
reasons: resetting an accumulating `.gitconfig` before each job, and bounding
`target/` after it. `-DryRun` writes them to `%TEMP%` so you can read exactly
what will be installed.

They are written for **Windows PowerShell 5.1** deliberately. The target VM has
no PowerShell 7, so that is what the runner invokes hooks with; a `??` in the
sweep hook would have failed to parse on every job.
The Linux entrypoint exports the cargo knobs before `run.sh`; a Windows service
has no equivalent hook and the runner's `.env` is read only by the Linux
systemd unit, so `provision.ps1` sets them as **machine-level** environment and
restarts the service to pick them up.

`CARGO_BUILD_JOBS` defaults to half the CPUs rather than all of them. This VM
is expected to share a host with other work, and an unthrottled Windows build
starves the OrbStack Linux fleet badly enough that its runners drop with "lost
communication".
