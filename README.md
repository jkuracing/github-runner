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

## Usage

### Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `URL` | Yes | GitHub repository or organization URL |
| `GITHUB_PAT` | One of `GITHUB_PAT` / `RUNNER_TOKEN` | Personal access token used to mint a fresh registration token on every container start. Preferred, since it never goes stale. Needs `admin:org` scope (classic PAT) for org-level runners, or `repo`/Administration for repo-level runners. |
| `RUNNER_TOKEN` | One of `GITHUB_PAT` / `RUNNER_TOKEN` | Static runner registration token from GitHub. Expires ~1 hour after creation, so restarts after that will fail unless refreshed. Ignored if `GITHUB_PAT` is set. |
| `RUNNER_NAME` | No | Base name for the runner (default: `runner`) |
| `RUNNER_LABELS` | No | Comma-separated labels for the runner |

### Running with Docker Compose

```bash
# Set environment variables
export URL=https://github.com/jkuracing
export GITHUB_PAT=<your-pat>

# Start the runner
docker compose up -d
```
