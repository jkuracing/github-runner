<#
.SYNOPSIS
  Provisions a Windows self-hosted GitHub Actions runner for JKU Racing.

.DESCRIPTION
  The Windows counterpart to this repo's Dockerfile + entrypoint.sh. It is a
  script rather than an image because there is no Windows equivalent of the
  Linux fleet here: Windows containers cannot run on the ARM64 Parallels VM
  this targets, so the runner is installed natively onto a machine that is
  provisioned once and kept.

  Everything is idempotent. Re-running it upgrades the toolchain in place and
  re-registers the runner against a freshly minted token; it is the intended
  way to update a machine, not just to build a new one.

  Registration follows entrypoint.sh: a PAT mints a short-lived registration
  token on every run, because registration tokens expire after ~1 hour and a
  static one goes stale between provisioning and the next re-run.

.PARAMETER Url
  Org or repo to register against. Org-level (the default) is what the Linux
  fleet uses and lets one machine serve every repo.

.PARAMETER Pat
  Classic PAT with `admin:org` (org-level) or `repo` (repo-level). Used ONLY to
  mint a registration token, never stored on the machine. Prefer passing it via
  the GITHUB_PAT environment variable so it stays out of your shell history.

.PARAMETER ServiceAccount
  Existing local account the runner service logs on as, e.g. ".\ci". It must
  already exist -- this script will not create an account, because creating one
  means choosing its password and that is yours to type, not mine to generate.

  It MUST NOT be LocalSystem, and the script refuses if you ask for it. Two
  independent failures come from running the build as SYSTEM, both found the
  hard way while porting hbf:

    - tauri caches its NSIS toolchain under %LOCALAPPDATA%\tauri\NSIS. Under
      SYSTEM that resolves inside C:\Windows\system32\config\systemprofile,
      where the download reports success but nothing lands, and the bundler
      then dies with "Unable to start child process, error 0x2" -- which is
      ERROR_FILE_NOT_FOUND, not the emulation failure it reads as.
    - node_modules created by a SYSTEM build is owned by SYSTEM, and a later
      build under any other account hangs or fails EPERM on it.

  You are never asked for the password by THIS script. config.cmd prompts for
  it itself, so it goes straight into the runner's own stdin and never reaches
  a command line, an environment variable, or this file.

.PARAMETER Labels
  Runner labels. Default targets the machine by what it IS, not what it builds:
  an ARM64 Windows box cross-compiles x86_64-pc-windows-msvc perfectly well
  (proven: `Target: x64`, payload PE machine 0x8664), so labelling it
  "windows-x64" would be a lie that breaks the day someone adds an x64 box.

.PARAMETER BuildJobs
  Cap on cargo's parallelism. Defaults to half the CPUs, because this VM is
  expected to share a host with other work -- on the machine this was written
  for, an unthrottled VM build starves the OrbStack Linux fleet badly enough
  that its runners drop with "lost communication".

.EXAMPLE
  $env:GITHUB_PAT = '<pat>'
  .\provision.ps1 -ServiceAccount '.\ci'
#>
[CmdletBinding()]
param(
  [string] $Url            = 'https://github.com/jkuracing',
  [string] $Pat            = $env:GITHUB_PAT,
  [Parameter(Mandatory)]
  [string] $ServiceAccount,
  [string] $Name           = "win-$env:COMPUTERNAME",
  [string] $Labels         = '',
  [string] $RunnerRoot     = 'C:\actions-runner',
  # Empty means "resolve the latest release at run time", which is what every
  # other download here does. A hand-pinned version only goes stale: the runner
  # self-updates on first contact with GitHub anyway, so pinning buys nothing
  # and guarantees the first job runs on a just-replaced binary. Set it
  # explicitly only to reproduce a specific machine.
  [string] $RunnerVersion  = '',
  [int]    $BuildJobs      = 0,
  [switch] $SkipToolchain,
  # Print everything this run would derive, then exit without touching the
  # machine. Worth having before provisioning a box you care about, and it is
  # how the derivation below is tested without side effects.
  [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Info  ($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Warn  ($m) { Write-Host "!!  $m" -ForegroundColor Yellow }
function Fail  ($m) { Write-Host "!!  $m" -ForegroundColor Red; exit 1 }

# --------------------------------------------------------------------------
# Guardrails
# --------------------------------------------------------------------------

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole(
      [Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Fail 'Run this from an elevated PowerShell -- installing a service and machine-level environment both need it.'
}

# Refuse the one account that is known to produce a green provision and a
# broken runner. See the ServiceAccount help above for the two mechanisms.
if ($ServiceAccount -match '^(NT AUTHORITY\\)?(LocalSystem|SYSTEM)$') {
  Fail 'ServiceAccount must not be LocalSystem: tauri''s NSIS cache and node_modules ownership both break under it. Use a dedicated local account.'
}

if (-not $Pat) {
  Fail 'No PAT. Pass -Pat or set GITHUB_PAT (classic PAT: admin:org for an org runner, repo for a repo runner).'
}

# Fail early and clearly rather than at config.cmd time, where the error is
# "The specified account does not exist" buried in runner output.
$acctName = $ServiceAccount -replace '^\.\\', ''
if ($ServiceAccount -like '.\*' -and -not (Get-LocalUser -Name $acctName -ErrorAction SilentlyContinue)) {
  Fail @"
Local account '$acctName' does not exist. Create it yourself (it needs a password you choose), then re-run:

    New-LocalUser -Name '$acctName' -Description 'GitHub Actions runner' -PasswordNeverExpires

config.cmd grants it SeServiceLogonRight when it installs the service, so no
manual rights assignment is needed.
"@
}

if (-not $RunnerVersion) {
  try {
    $RunnerVersion = (Invoke-RestMethod 'https://api.github.com/repos/actions/runner/releases/latest').tag_name -replace '^v', ''
  } catch {
    Fail "Could not resolve the latest actions/runner release: $_. Pass -RunnerVersion to pin one."
  }
}

$arch = $env:PROCESSOR_ARCHITECTURE
switch ($arch) {
  'ARM64' { $runnerArch = 'arm64'; $isArm = $true }
  'AMD64' { $runnerArch = 'x64';   $isArm = $false }
  default { Fail "Unsupported architecture: $arch" }
}

if (-not $Labels) {
  $Labels = if ($isArm) { 'windows,windows-arm64' } else { 'windows,windows-x64' }
}

if ($BuildJobs -le 0) {
  $cpus = [int](Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
  $BuildJobs = [Math]::Max(1, [Math]::Floor($cpus / 2))
}

# Derived here rather than at point of use so -DryRun can show it. Mirrors
# fetch_runner_token in entrypoint.sh: org URLs hit /orgs/{org}/..., repo URLs
# /repos/{owner}/{repo}/.... Pure string work -- no network call happens here.
$path  = ($Url -replace '^https://github\.com/', '').TrimEnd('/')
$parts = $path.Split('/')
$api = if ($parts.Count -ge 2) {
  "https://api.github.com/repos/$($parts[0])/$($parts[1])/actions/runners/registration-token"
} else {
  "https://api.github.com/orgs/$($parts[0])/actions/runners/registration-token"
}

Info "Architecture   : $arch (runner package: $runnerArch)"
Info "Runner name    : $Name"
Info "Labels         : $Labels"
Info "Service account: $ServiceAccount"
Info "CARGO_BUILD_JOBS: $BuildJobs"
Info "Registration API: $api"
Info "Runner root    : $RunnerRoot (actions-runner $RunnerVersion)"

if ($DryRun) {
  Warn 'DryRun: nothing installed, nothing registered, no machine state changed.'
  exit 0
}

# --------------------------------------------------------------------------
# Toolchain
#
# Established empirically against hbf rather than from any vendor's docs; the
# same list is documented in hbf's docs/book/src/contributing/development.md.
#
# `winget` is deliberately not used anywhere here: it hangs outright under a
# non-interactive remote session on this VM, so everything below is curl plus
# a silent installer.
# --------------------------------------------------------------------------

$tempDir = Join-Path $env:TEMP 'jkur-provision'
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

function Get-File($Uri, $OutFile) {
  Info "Downloading $Uri"
  # Explicit TLS 1.2 for older PowerShell hosts, and the progress bar off:
  # Invoke-WebRequest's progress rendering costs more wall-clock than the
  # download on a fast link.
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $ProgressPreference = 'SilentlyContinue'
  Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
}

function Test-Cmd($Name) {
  $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Add-MachinePath($Dir) {
  $cur = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  if ($cur -notlike "*$Dir*") {
    [Environment]::SetEnvironmentVariable('Path', "$cur;$Dir", 'Machine')
    Info "PATH += $Dir"
  }
  if ($env:Path -notlike "*$Dir*") { $env:Path = "$env:Path;$Dir" }
}

if (-not $SkipToolchain) {

  # Git for Windows. This is NOT optional and NOT merely a convenience: every
  # composite action these workflows use declares `shell: bash`, and on a
  # self-hosted Windows runner that resolves to bash.exe on PATH. Without Git
  # for Windows the runner registers fine and then fails every single job.
  if (-not (Test-Cmd git)) {
    $exe = Join-Path $tempDir 'git-setup.exe'
    $gitArch = if ($isArm) { 'arm64' } else { '64-bit' }
    $rel = Invoke-RestMethod 'https://api.github.com/repos/git-for-windows/git/releases/latest'
    $asset = $rel.assets | Where-Object { $_.name -like "Git-*-$gitArch.exe" } | Select-Object -First 1
    if (-not $asset) { Fail "No Git for Windows $gitArch installer in the latest release." }
    Get-File $asset.browser_download_url $exe
    Info 'Installing Git for Windows'
    Start-Process $exe -ArgumentList '/VERYSILENT','/NORESTART','/NOCANCEL','/SP-' -Wait
  }
  Add-MachinePath 'C:\Program Files\Git\bin'

  # Visual Studio Build Tools: the MSVC linker. Rust's *-pc-windows-msvc
  # targets cannot link without it.
  $vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
  if (-not (Test-Path $vsWhere)) {
    $exe = Join-Path $tempDir 'vs_buildtools.exe'
    Get-File 'https://aka.ms/vs/17/release/vs_BuildTools.exe' $exe
    Info 'Installing VS Build Tools (this is the slow one)'
    # ARM64 hosts need the ARM64 toolchain component explicitly; the x64 one is
    # installed on both so a single machine can cross-compile either way.
    $vsArgs = @(
      '--quiet','--wait','--norestart','--nocache',
      '--add','Microsoft.VisualStudio.Workload.VCTools',
      '--add','Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
      '--add','Microsoft.VisualStudio.Component.Windows11SDK.22621'
    )
    if ($isArm) { $vsArgs += @('--add','Microsoft.VisualStudio.Component.VC.Tools.ARM64') }
    Start-Process $exe -ArgumentList $vsArgs -Wait
  }

  # LLVM/clang, on ARM64 only. `ring` assembles its crypto with clang for
  # aarch64-pc-windows-msvc; x64 links with MSVC alone. Installing it
  # everywhere would be harmless but misleading about why it is here.
  if ($isArm -and -not (Test-Path 'C:\Program Files\LLVM\bin\clang.exe')) {
    $exe = Join-Path $tempDir 'llvm.exe'
    $rel = Invoke-RestMethod 'https://api.github.com/repos/llvm/llvm-project/releases/latest'
    $asset = $rel.assets | Where-Object { $_.name -like 'LLVM-*-woa64.exe' } | Select-Object -First 1
    if (-not $asset) { Fail 'No LLVM woa64 (ARM64) installer in the latest release.' }
    Get-File $asset.browser_download_url $exe
    Info 'Installing LLVM (ARM64)'
    Start-Process $exe -ArgumentList '/S' -Wait
  }
  if ($isArm) { Add-MachinePath 'C:\Program Files\LLVM\bin' }

  # Rust. Both MSVC targets are added regardless of host so either direction of
  # cross-compilation works; that is how an ARM64 box produces the shipping x64
  # installer.
  if (-not (Test-Cmd rustup)) {
    $exe = Join-Path $tempDir 'rustup-init.exe'
    Get-File "https://static.rust-lang.org/rustup/dist/$(if($isArm){'aarch64'}else{'x86_64'})-pc-windows-msvc/rustup-init.exe" $exe
    Info 'Installing Rust'
    Start-Process $exe -ArgumentList '-y','--default-toolchain','stable','--profile','minimal' -Wait
  }
  Add-MachinePath "$env:USERPROFILE\.cargo\bin"
  rustup target add x86_64-pc-windows-msvc aarch64-pc-windows-msvc
  rustup component add rustfmt clippy

  # nextest. hbf's suite needs it: plain `cargo test` produces phantom 30s
  # timeouts there, so a runner without it cannot run that gate at all.
  if (-not (Test-Cmd cargo-nextest)) {
    Info 'Installing cargo-nextest'
    cargo install cargo-nextest --locked
  }

  # Pkl. A build script shells out to it. There is no Windows ARM64 build, and
  # none is needed -- the amd64 exe runs under emulation, and codegen is not a
  # hot path.
  $pklDir = 'C:\Program Files\pkl'
  if (-not (Test-Path "$pklDir\pkl.exe")) {
    New-Item -ItemType Directory -Force -Path $pklDir | Out-Null
    $rel = Invoke-RestMethod 'https://api.github.com/repos/apple/pkl/releases/latest'
    $asset = $rel.assets | Where-Object { $_.name -eq 'pkl-windows-amd64.exe' } | Select-Object -First 1
    if (-not $asset) { Fail 'No pkl-windows-amd64.exe in the latest pkl release.' }
    Get-File $asset.browser_download_url "$pklDir\pkl.exe"
  }
  Add-MachinePath $pklDir

  # bun, for the UI bundle. hbf-gui's generate_context! embeds ui/build at
  # COMPILE time, so the bundle has to exist before cargo runs.
  if (-not (Test-Cmd bun)) {
    Info 'Installing bun'
    # bun's own installer is the supported path on Windows and picks the right
    # architecture itself.
    Invoke-RestMethod 'https://bun.sh/install.ps1' | Invoke-Expression
  }
  Add-MachinePath "$env:USERPROFILE\.bun\bin"

  # WebView2 is preinstalled on Windows 11. Checked rather than assumed,
  # because a missing runtime fails at GUI launch, long after the build.
  $wv = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' -ErrorAction SilentlyContinue
  if (-not $wv) { Warn 'WebView2 runtime not detected. The GUI will not launch; install it if this machine runs GUI jobs.' }
}

# --------------------------------------------------------------------------
# Runner
# --------------------------------------------------------------------------

New-Item -ItemType Directory -Force -Path $RunnerRoot | Out-Null

if (-not (Test-Path (Join-Path $RunnerRoot 'config.cmd'))) {
  $pkg = Join-Path $tempDir "actions-runner-win-$runnerArch-$RunnerVersion.zip"
  Get-File "https://github.com/actions/runner/releases/download/v$RunnerVersion/actions-runner-win-$runnerArch-$RunnerVersion.zip" $pkg
  Info "Extracting runner to $RunnerRoot"
  Expand-Archive -LiteralPath $pkg -DestinationPath $RunnerRoot -Force
}

# The service account owns the runner tree. Without this the service starts and
# then fails on its first write to _work, which surfaces as an opaque job
# failure rather than a permissions error.
Info "Granting $ServiceAccount full control of $RunnerRoot"
# ".\name" is what config.cmd wants but is NOT a resolvable NTAccount string,
# so the ACL below needs the machine-qualified form or it throws
# IdentityNotMappedException.
$aclIdentity = if ($ServiceAccount -like '.\*') {
  "$env:COMPUTERNAME\$($ServiceAccount -replace '^\.\\', '')"
} else {
  $ServiceAccount
}
$acl = Get-Acl $RunnerRoot
$rule = New-Object Security.AccessControl.FileSystemAccessRule(
  $aclIdentity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
$acl.SetAccessRule($rule)
Set-Acl -Path $RunnerRoot -AclObject $acl

Info 'Requesting a registration token'
try {
  $resp = Invoke-RestMethod -Method Post -Uri $api -Headers @{
    Authorization = "Bearer $Pat"
    Accept        = 'application/vnd.github+json'
  }
} catch {
  Fail "Could not mint a registration token from $api -- check the PAT's scopes. $_"
}
$token = $resp.token

Push-Location $RunnerRoot
try {
  # Remove any previous registration so re-running this script is an upgrade
  # rather than an error. `.runner_migrated` MUST be in this list: the runner
  # self-updates in place and drops that marker, and config.cmd treats the
  # marker ALONE as proof it is already configured. Leaving it behind is what
  # silently took the Linux fleet offline about ten days after a rebuild.
  if (Get-Service 'actions.runner.*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*$Name*" }) {
    Info 'Removing the existing service registration'
    try { & .\config.cmd remove --token $token } catch { Warn "config.cmd remove failed: $_" }
  }
  foreach ($stale in '.runner','.credentials','.credentials_rsaparams','.runner_migrated','.credentials_migrated') {
    # Named explicitly rather than via Get-ChildItem -Include, which needs a
    # wildcard path to match anything and would silently clean nothing here.
    Remove-Item -Force -LiteralPath $stale -ErrorAction SilentlyContinue
  }

  Info 'Configuring the runner as a Windows service'
  Warn 'config.cmd will now prompt for the service account password. It goes straight into the runner and is not stored, logged, or passed on a command line.'

  # NOTE: deliberately NOT --unattended. Everything else is supplied, so the
  # only thing it can prompt for is the password -- which is exactly where we
  # want it entered. Passing --windowslogonpassword instead would put the
  # password in this process's command line, visible to any other process on
  # the machine for the lifetime of the call.
  & .\config.cmd `
    --url $Url `
    --token $token `
    --name $Name `
    --labels $Labels `
    --work '_work' `
    --replace `
    --runasservice `
    --windowslogonaccount $ServiceAccount

  if ($LASTEXITCODE -ne 0) { Fail "config.cmd exited $LASTEXITCODE" }
} finally {
  Pop-Location
}

# --------------------------------------------------------------------------
# Machine environment
#
# The Linux entrypoint exports these before exec'ing run.sh. A Windows service
# has no equivalent hook, and the runner's `.env` file is read only by the
# Linux systemd unit -- so machine-level environment is the portable place.
# The service picks these up at start, which is why it is restarted below.
# --------------------------------------------------------------------------

$hooks = Join-Path $RunnerRoot 'hooks'
New-Item -ItemType Directory -Force -Path $hooks | Out-Null
foreach ($hook in 'job-started-hook.ps1','job-completed-hook.ps1') {
  $src = Join-Path $PSScriptRoot $hook
  # Copied from beside this script, so a lone provision.ps1 downloaded without
  # the rest of windows/ fails here loudly rather than registering a runner
  # whose hooks silently do not exist.
  if (-not (Test-Path $src)) { Fail "Missing $hook next to provision.ps1 -- clone the repo rather than downloading the script alone." }
  Copy-Item -Force $src $hooks
}

$machineEnv = @{
  # Same reasoning as entrypoint.sh: without a cap, cargo sizes its thread pool
  # from the host core count and swamps a machine that is sharing a host.
  'CARGO_BUILD_JOBS'         = "$BuildJobs"
  'CARGO_INCREMENTAL'        = '0'
  'CARGO_PROFILE_DEV_DEBUG'  = 'line-tables-only'
  'ACTIONS_RUNNER_HOOK_JOB_STARTED'   = (Join-Path $hooks 'job-started-hook.ps1')
  'ACTIONS_RUNNER_HOOK_JOB_COMPLETED' = (Join-Path $hooks 'job-completed-hook.ps1')
  'SWEEP_MAX_GB'             = '8'
}
foreach ($k in $machineEnv.Keys) {
  [Environment]::SetEnvironmentVariable($k, $machineEnv[$k], 'Machine')
  Info "env $k = $($machineEnv[$k])"
}

$svc = Get-Service | Where-Object { $_.Name -like 'actions.runner.*' } | Select-Object -First 1
if ($svc) {
  Info "Restarting $($svc.Name) so it picks up the machine environment"
  Restart-Service $svc.Name
  Start-Sleep -Seconds 3
  $svc = Get-Service $svc.Name
  Info "Service status: $($svc.Status)"
  if ($svc.Status -ne 'Running') {
    Fail "Service is $($svc.Status). Check Event Viewer -> Windows Logs -> Application, and confirm the account password was correct."
  }
} else {
  Fail 'No actions.runner.* service found after configuration.'
}

Info 'Done. The runner should now appear under the org''s Actions > Runners.'
