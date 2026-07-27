# Dockerized self-hosted GitHub Runner

A self-hosted GitHub Actions runner Docker image configured for JKU Racing firmware development.

## Pre-installed Tools

This runner includes all tools required for the firmware CI pipeline:

### Rust Development

- **Rust stable toolchain** with `rustfmt` and `clippy`
- **ESP-IDF Xtensa toolchain** for ESP32-S3 development (`espup`)
- **cargo-nextest** for fast test execution

### Build Tools

- **just** - Command runner used by the firmware project
- **Pkl** (v0.29.1) - Apple's configuration language (used by canvas)
- **maturin** - Build Python wheels from Rust code

### Python

- **Python 3.12** with development headers
- **uv** - Fast Python package manager
- **python3-cffi** - C FFI for Python

### Other

- **SSH** - Pre-configured with GitHub's host keys for private submodule access
- Standard build essentials (`build-essential`, `pkg-config`, `libssl-dev`)

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
