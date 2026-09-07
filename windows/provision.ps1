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
  # A registration token minted elsewhere, as an alternative to -Pat. The Linux
  # entrypoint accepts RUNNER_TOKEN for the same reason: it lets the PAT stay
  # off this machine entirely -- mint the token where the PAT already lives and
  # pass only the short-lived result. Expires in ~1 hour.
  [string] $RegistrationToken = $env:RUNNER_TOKEN,
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
  # Skip the registration step and stop after the toolchain. config.cmd prompts
  # for the service account password on an interactive console, so a session
  # without a real stdin (a remote `prlctl exec`, a scripted deploy) cannot
  # answer it. This lets the long unattended half run there and the short
  # interactive half be done by a person.
  [switch] $SkipRegistration,
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
# Job hooks
#
# Embedded rather than shipped as sibling files so this script is the ONLY
# thing you need on a new machine: download it, run it, done. The trade is that
# the hook sources live inside a here-string; they are single-quoted, so
# nothing in them is expanded by this script.
# --------------------------------------------------------------------------

$JobStartedHook = @'
<#
  Runs before EVERY job, via ACTIONS_RUNNER_HOOK_JOB_STARTED.

  The PowerShell twin of job-started-hook.sh, and it exists for exactly the
  same reason. A shared setup snippet used across canvas-consuming repos
  configures a git `insteadOf` rewrite with `git config --global set`, then
  `--add` for a second value under the same key. On an ephemeral hosted runner
  that is harmless -- the machine is destroyed when the job ends. Here the
  service account outlives every job, so those values accumulate in its
  .gitconfig until a later `set` collides with an already multi-valued key:

      error: cannot overwrite multiple values with a single value

  It is invisible in any one job and only appears once a machine has served
  enough canvas-consuming jobs to pile up a second value.

  This is a job-STARTED hook rather than only a completed one because a
  cancelled, timed-out or killed job skips the completed hook entirely, and its
  accumulated .gitconfig would survive into the next job -- which is the exact
  collision being prevented. Running before every job closes the gap instead of
  narrowing it.

  "Clean baseline" means the file's absence: nothing in provision.ps1 writes a
  .gitconfig for the service account, so that is what a freshly provisioned
  machine starts with.
#>
$ErrorActionPreference = 'Continue'

$gitconfig = Join-Path $env:USERPROFILE '.gitconfig'
if (Test-Path $gitconfig) {
  Remove-Item -Force $gitconfig -ErrorAction SilentlyContinue
  Write-Host "hook: reset $gitconfig to a clean baseline"
}

# Never fail the job. This runs adjacent to work that must not be put at risk
# by a cleanup step.
exit 0
'@

$JobCompletedHook = @'
<#
  Runs after EVERY job, via ACTIONS_RUNNER_HOOK_JOB_COMPLETED.

  The PowerShell twin of job-completed-hook.sh: bound `target/` between jobs so
  a persistent machine does not drift until the disk fills. On the Linux fleet
  that surfaced not as "out of disk" but as a linker bus error, which cost real
  time to diagnose; a Windows machine will fail differently but no more
  clearly.

  The budget is higher here than the fleet's 4 GB because this is ONE machine
  rather than twelve replicas sharing a volume, and because a Windows build
  tree carries both the host and the cross target -- hbf builds
  aarch64-pc-windows-msvc and x86_64-pc-windows-msvc from one checkout.

  Why a job hook rather than a scheduled task: the runner invokes this between
  jobs, so it can never delete a target/ out from under a live compile.

  This bounds STEADY STATE, not the peak. A build in flight can exceed the
  threshold and is only swept once it finishes.
#>
$ErrorActionPreference = 'Continue'

# Written the long way rather than with `??`: the runner may invoke this hook
# with Windows PowerShell 5.1, which has no null-coalescing operator and would
# fail to parse the file outright.
$maxGb = if ($env:SWEEP_MAX_GB) { [int]$env:SWEEP_MAX_GB } else { 8 }
# The runner root's _work, NOT RUNNER_WORKSPACE. RUNNER_WORKSPACE is
# per-repository, so using it would enforce the budget once per repo rather
# than once per machine -- on the Linux fleet that let each replica hold twice
# its nominal budget with two repos checked out.
$workDir = if ($env:SWEEP_WORK_DIR) { $env:SWEEP_WORK_DIR } else { 'C:\actions-runner\_work' }
if (-not (Test-Path $workDir)) { exit 0 }

function Get-SizeMb($Path) {
  try {
    [Math]::Round((Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
      Measure-Object -Property Length -Sum).Sum / 1MB)
  } catch { 0 }
}

$usedMb  = Get-SizeMb $workDir
$limitMb = $maxGb * 1024
if ($usedMb -le $limitMb) {
  Write-Host "sweep: _work at $usedMb MB, under the $limitMb MB budget -- keeping it warm"
  exit 0
}

Write-Host "sweep: _work at $usedMb MB exceeds $limitMb MB -- removing target dirs"

# Largest first, stopping as soon as the budget is met, so the machine keeps as
# much warmth as the budget allows instead of being emptied wholesale. Only
# genuine cargo target dirs are touched: the CACHEDIR.TAG / debug / release
# test avoids deleting a source directory that merely happens to be named
# "target".
$targets = Get-ChildItem -LiteralPath $workDir -Recurse -Directory -Force -Filter 'target' -ErrorAction SilentlyContinue |
  Where-Object {
    (Test-Path (Join-Path $_.FullName 'CACHEDIR.TAG')) -or
    (Test-Path (Join-Path $_.FullName 'debug'))        -or
    (Test-Path (Join-Path $_.FullName 'release'))
  } |
  ForEach-Object { [pscustomobject]@{ Path = $_.FullName; Mb = Get-SizeMb $_.FullName } } |
  Sort-Object Mb -Descending

foreach ($t in $targets) {
  if ($usedMb -le $limitMb) { break }
  Remove-Item -LiteralPath $t.Path -Recurse -Force -ErrorAction SilentlyContinue
  $usedMb -= $t.Mb
  Write-Host "sweep: removed $($t.Path) ($($t.Mb) MB), now ~$usedMb MB"
}

# Never fail the job: this runs after the work that matters is already done and
# reported, and a sweep problem must not turn a green job red.
exit 0
'@

function Write-HookFiles {
  param([Parameter(Mandatory)][string] $Destination)
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  $a = Join-Path $Destination 'job-started-hook.ps1'
  $b = Join-Path $Destination 'job-completed-hook.ps1'
  # ASCII, not the default UTF-8-with-BOM of Set-Content on 5.1: a BOM ahead of
  # the first line is tolerated by PowerShell but shows up in diffs and logs.
  $JobStartedHook   | Set-Content -LiteralPath $a -Encoding ASCII
  $JobCompletedHook | Set-Content -LiteralPath $b -Encoding ASCII
  Info "Hooks written to $Destination"
  return @($a, $b)
}

# --------------------------------------------------------------------------
# gh helpers
#
# gh writes to stderr in normal operation, and this script runs with
# ErrorActionPreference = 'Stop', under which `2>&1` on a native command throws
# NativeCommandError. Every gh call therefore goes through here, which relaxes
# that for the duration and hands back the exit code plus clean text.
# --------------------------------------------------------------------------

function Invoke-Gh {
  param(
    [Parameter(Mandatory)][string[]] $GhArgs,
    # Let gh own the console so it can prompt, print a device code, and open a
    # browser. Output is not captured in this mode -- it belongs to the user.
    [switch] $Interactive
  )
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if ($Interactive) {
      & gh @GhArgs
      return [pscustomobject]@{ Code = $LASTEXITCODE; Output = '' }
    }
    # ToString() per record: formatting an ErrorRecord wraps PowerShell's own
    # "At <script>:<line> char:" trace around gh's one-line message.
    $out = (& gh @GhArgs 2>&1 | ForEach-Object { $_.ToString() }) -join "`n"
    return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out.Trim() }
  } finally {
    $ErrorActionPreference = $prev
  }
}

function Test-Interactive {
  # A provisioning run driven over `prlctl exec`, WinRM or a scheduled task has
  # no console for gh to prompt on. Attempting it there hangs, which is worse
  # than failing, so those sessions get printed instructions instead.
  return [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
}

function Get-GhRegistrationToken {
  param(
    [Parameter(Mandatory)][string] $ApiPath,
    [Parameter(Mandatory)][string] $Scope
  )

  $manual = @"
Run these on this machine, then re-run this script:

    gh auth login --hostname github.com --scopes $Scope
    <this script> -ServiceAccount '$ServiceAccount' -SkipToolchain

Or skip gh entirely by passing -Pat, or -RegistrationToken if you minted one
elsewhere.
"@

  $status = Invoke-Gh @('auth', 'status', '--hostname', 'github.com')
  if ($status.Code -ne 0) {
    Info 'gh is not logged in yet.'
    if (-not (Test-Interactive)) { Fail "gh needs an interactive login and this session has no console.`n`n$manual" }
    Info "Starting `gh auth login` -- follow its prompts (browser, or paste a token)."
    $login = Invoke-Gh @('auth', 'login', '--hostname', 'github.com', '--scopes', $Scope) -Interactive
    if ($login.Code -ne 0) { Fail "gh auth login exited $($login.Code).`n`n$manual" }
  }

  $attempt = Invoke-Gh @('api', '-X', 'POST', $ApiPath, '--jq', '.token')
  if ($attempt.Code -eq 0 -and $attempt.Output -and $attempt.Output -notmatch '\s') {
    return $attempt.Output
  }

  # Logged in but refused. Overwhelmingly this is the scope: gh's ordinary
  # login grants read:org, while registering an org runner needs admin:org.
  # Note an org that disables repo-level runners reports THAT as a 404 rather
  # than a permission error, so the message keeps gh's own text.
  Info "gh is logged in but could not mint a token; requesting the '$Scope' scope."
  Info "  $($attempt.Output)"
  if (-not (Test-Interactive)) { Fail "gh needs '$Scope' and this session has no console to grant it.`n`n$manual" }
  $refresh = Invoke-Gh @('auth', 'refresh', '--hostname', 'github.com', '--scopes', $Scope) -Interactive
  if ($refresh.Code -ne 0) { Fail "gh auth refresh exited $($refresh.Code).`n`n$manual" }

  $attempt = Invoke-Gh @('api', '-X', 'POST', $ApiPath, '--jq', '.token')
  if ($attempt.Code -ne 0 -or -not $attempt.Output -or $attempt.Output -match '\s') {
    Fail "gh still could not mint a registration token from $ApiPath after granting '$Scope':`n`n  $($attempt.Output)`n`n$manual"
  }
  return $attempt.Output
}

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

# gh counts as a credential: it can mint the registration token itself. Checked
# with Get-Command rather than the Test-Cmd helper because that is defined with
# the toolchain further down, and -SkipToolchain must still reach this. gh may
# also be installed BY this run, so a missing gh is only fatal when the
# toolchain step is being skipped.
$haveGh = $null -ne (Get-Command gh -ErrorAction SilentlyContinue)
if (-not $Pat -and -not $RegistrationToken -and -not $SkipRegistration -and -not $haveGh -and $SkipToolchain) {
  Fail 'No credential and no gh. Pass -Pat/GITHUB_PAT, or -RegistrationToken/RUNNER_TOKEN if you minted one elsewhere, or drop -SkipToolchain so gh gets installed, or -SkipRegistration to install only the toolchain.'
}

# Fail early and clearly rather than at config.cmd time, where the error is
# "The specified account does not exist" buried in runner output.
$acctName = $ServiceAccount -replace '^\.\\', ''
if ($ServiceAccount -like '.\*' -and -not (Get-LocalUser -Name $acctName -ErrorAction SilentlyContinue)) {
  $createHint = @"
Create it yourself, then re-run:

    New-LocalUser -Name '$acctName' -Description 'GitHub Actions runner' -PasswordNeverExpires

config.cmd grants it SeServiceLogonRight when it installs the service, so no
manual rights assignment is needed.
"@
  if (-not (Test-Interactive)) {
    Fail "Local account '$acctName' does not exist, and this session has no console to create it on.`n`n$createHint"
  }
  Warn "Local account '$acctName' does not exist."
  $answer = Read-Host "Create it now? The password is yours to choose and is never shown, logged or stored by this script [y/N]"
  if ($answer -notmatch '^(y|yes)$') { Fail $createHint }

  # Read twice and compare. A mistyped password here does not fail here -- it
  # fails later, as a service that installs cleanly and then refuses to start,
  # which is a much worse place to discover a typo.
  $pw1 = Read-Host 'Password for the runner account' -AsSecureString
  $pw2 = Read-Host 'Confirm password' -AsSecureString
  $b1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw1)
  $b2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw2)
  try {
    $s1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b1)
    $s2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b2)
    $match = $s1 -ceq $s2
  } finally {
    # Zero both copies rather than waiting for the GC: BSTRs are unmanaged and
    # would otherwise sit in memory for the rest of the run.
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b1)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b2)
  }
  if (-not $match) { Fail 'The two passwords do not match.' }

  New-LocalUser -Name $acctName -Password $pw1 -Description 'GitHub Actions runner' `
                -PasswordNeverExpires -UserMayNotChangePassword | Out-Null
  Info "Created local account '$acctName'."
  Warn 'config.cmd will ask for this password again shortly. That second prompt is deliberate: it keeps the password inside the runner rather than on a command line.'
}

if (-not $RunnerVersion) {
  try {
    $RunnerVersion = (Invoke-RestMethod 'https://api.github.com/repos/actions/runner/releases/latest').tag_name -replace '^v', ''
  } catch {
    Fail "Could not resolve the latest actions/runner release: $_. Pass -RunnerVersion to pin one."
  }
}

# ".\name" is what config.cmd wants but is NOT a resolvable NTAccount string,
# so every ACL below needs the machine-qualified form or it throws
# IdentityNotMappedException.
$aclIdentity = if ($ServiceAccount -like '.\*') {
  "$env:COMPUTERNAME\$($ServiceAccount -replace '^\.\\', '')"
} else {
  $ServiceAccount
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
  # The hooks go to TEMP rather than the runner root: it makes them
  # inspectable (and testable) without writing anything the machine keeps.
  $preview = Join-Path $env:TEMP 'jkur-provision-hooks'
  Write-HookFiles -Destination $preview | Out-Null
  Warn "DryRun: nothing installed, nothing registered, no service touched. Hooks emitted to $preview for inspection."
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
  # Rust goes to a MACHINE-WIDE location, not %USERPROFILE%.
  #
  # This is the one toolchain here that defaults to a per-user path, and
  # getting it wrong is invisible until the first job. Provisioning runs
  # elevated -- often as SYSTEM -- while jobs run as the service account, so a
  # default install puts cargo in the provisioning account's profile, publishes
  # that unreadable path on the machine PATH, and the runner then registers
  # cleanly and fails every job with "cargo not found". Setting CARGO_HOME and
  # RUSTUP_HOME before rustup-init runs makes the install account-independent.
  $rustRoot   = 'C:\rust'
  $cargoHome  = Join-Path $rustRoot 'cargo'
  $rustupHome = Join-Path $rustRoot 'rustup'
  [Environment]::SetEnvironmentVariable('CARGO_HOME',  $cargoHome,  'Machine')
  [Environment]::SetEnvironmentVariable('RUSTUP_HOME', $rustupHome, 'Machine')
  $env:CARGO_HOME  = $cargoHome
  $env:RUSTUP_HOME = $rustupHome

  if (-not (Test-Path (Join-Path $cargoHome 'bin\rustup.exe'))) {
    $exe = Join-Path $tempDir 'rustup-init.exe'
    Get-File "https://static.rust-lang.org/rustup/dist/$(if($isArm){'aarch64'}else{'x86_64'})-pc-windows-msvc/rustup-init.exe" $exe
    Info "Installing Rust into $rustRoot"
    Start-Process $exe -ArgumentList '-y','--default-toolchain','stable','--profile','minimal' -Wait -NoNewWindow
  }
  Add-MachinePath (Join-Path $cargoHome 'bin')

  # cargo writes to CARGO_HOME (the registry cache, and `cargo install`), so
  # the service account needs Modify here, not merely Read.
  $rustAcl = Get-Acl $rustRoot
  $rustAcl.SetAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
    $aclIdentity, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
  Set-Acl -Path $rustRoot -AclObject $rustAcl
  Info "Granted $aclIdentity Modify on $rustRoot"
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
  # bun publishes a per-architecture zip for Windows, including aarch64, so it
  # is fetched directly rather than by piping bun.sh/install.ps1 into
  # Invoke-Expression: the zip is deterministic, works the same on both
  # architectures, and does not execute a remote script as Administrator.
  $bunDir = 'C:\Program Files\bun'
  if (-not (Test-Path "$bunDir\bun.exe")) {
    $bunArch = if ($isArm) { 'aarch64' } else { 'x64' }
    $rel = Invoke-RestMethod 'https://api.github.com/repos/oven-sh/bun/releases/latest'
    $asset = $rel.assets | Where-Object { $_.name -eq "bun-windows-$bunArch.zip" } | Select-Object -First 1
    if (-not $asset) { Fail "No bun-windows-$bunArch.zip in the latest bun release." }
    $zip = Join-Path $tempDir "bun-$bunArch.zip"
    Get-File $asset.browser_download_url $zip
    $staging = Join-Path $tempDir 'bun-extract'
    Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
    Expand-Archive -LiteralPath $zip -DestinationPath $staging -Force
    New-Item -ItemType Directory -Force -Path $bunDir | Out-Null
    # The zip nests everything under bun-windows-<arch>/.
    Get-ChildItem -Recurse -File -Path $staging -Filter 'bun.exe' |
      Select-Object -First 1 |
      ForEach-Object { Copy-Item -Force $_.FullName "$bunDir\bun.exe" }
    if (-not (Test-Path "$bunDir\bun.exe")) { Fail 'bun.exe not found inside the downloaded zip.' }
    # An x64 machine older than the baseline cutoff needs
    # bun-windows-x64-baseline.zip instead; bun will fail with an illegal
    # instruction rather than a clear message if so.
  }
  Add-MachinePath $bunDir

  # GitHub CLI. Not needed to build anything -- it is here so registration can
  # use `gh auth` instead of a hand-made classic PAT (see Get-RegistrationToken
  # below), and because a CI box is a place you end up wanting it.
  $ghDir = 'C:\Program Files\gh'
  if (-not (Test-Path "$ghDir\gh.exe")) {
    $ghArch = if ($isArm) { 'arm64' } else { 'amd64' }
    $rel = Invoke-RestMethod 'https://api.github.com/repos/cli/cli/releases/latest'
    $asset = $rel.assets | Where-Object { $_.name -like "gh_*_windows_$ghArch.zip" } | Select-Object -First 1
    if (-not $asset) { Fail "No gh_*_windows_$ghArch.zip in the latest gh release." }
    $zip = Join-Path $tempDir "gh-$ghArch.zip"
    Get-File $asset.browser_download_url $zip
    $staging = Join-Path $tempDir 'gh-extract'
    Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
    Expand-Archive -LiteralPath $zip -DestinationPath $staging -Force
    New-Item -ItemType Directory -Force -Path $ghDir | Out-Null
    # The zip nests everything under gh_<version>_windows_<arch>/bin/.
    Get-ChildItem -Recurse -File -Path $staging -Filter 'gh.exe' |
      Select-Object -First 1 |
      ForEach-Object { Copy-Item -Force $_.FullName "$ghDir\gh.exe" }
    if (-not (Test-Path "$ghDir\gh.exe")) { Fail 'gh.exe not found inside the downloaded zip.' }
  }
  Add-MachinePath $ghDir

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
$acl = Get-Acl $RunnerRoot
$rule = New-Object Security.AccessControl.FileSystemAccessRule(
  $aclIdentity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
$acl.SetAccessRule($rule)
Set-Acl -Path $RunnerRoot -AclObject $acl

if ($SkipRegistration) {
  Warn 'SkipRegistration: installing the toolchain only, leaving the runner unregistered.'
} else {
  if ($RegistrationToken) {
    Info 'Using the registration token supplied on the command line'
    $token = $RegistrationToken
  } elseif ($Pat) {
    Info 'Requesting a registration token with the supplied PAT'
    try {
      $resp = Invoke-RestMethod -Method Post -Uri $api -Headers @{
        Authorization = "Bearer $Pat"
        Accept        = 'application/vnd.github+json'
      }
    } catch {
      Fail "Could not mint a registration token from $api -- check the PAT's scopes. $_"
    }
    $token = $resp.token
  } else {
    # No PAT and no pre-minted token: let the GitHub CLI handle it, logging in
    # or widening its scope interactively if it has to. This is the path an
    # empty machine takes -- nothing to create beforehand, and gh's credential
    # is managed and revocable rather than a classic PAT pasted through a
    # shell.
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
      Fail 'gh is not on PATH. Drop -SkipToolchain so this script installs it, or pass -Pat / -RegistrationToken.'
    }
    # An org runner needs admin:org; a repo runner needs admin on the repo,
    # which the `repo` scope carries.
    $ghScope = if ($parts.Count -ge 2) { 'repo' } else { 'admin:org' }
    $token = Get-GhRegistrationToken -ApiPath ($api -replace '^https://api\.github\.com/', '') -Scope $ghScope
  }

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
}

# --------------------------------------------------------------------------
# Machine environment
#
# The Linux entrypoint exports these before exec'ing run.sh. A Windows service
# has no equivalent hook, and the runner's `.env` file is read only by the
# Linux systemd unit -- so machine-level environment is the portable place.
# The service picks these up at start, which is why it is restarted below.
# --------------------------------------------------------------------------

# Install this script beside the runner it provisions.
#
# Re-running is how a machine is upgraded, and the copy you first ran from is
# often somewhere temporary -- a Downloads folder, a network share, a checkout
# that gets deleted. Landing a copy at a stable, predictable path means the
# upgrade command is the same on every machine and does not depend on where the
# operator happened to be standing.
$selfSource = $PSCommandPath
$selfTarget = Join-Path $RunnerRoot 'provision.ps1'
if ($selfSource -and (Test-Path $selfSource) -and
    ((Resolve-Path $selfSource).Path -ne (Join-Path (Resolve-Path $RunnerRoot).Path 'provision.ps1'))) {
  Copy-Item -Force -LiteralPath $selfSource -Destination $selfTarget
  Info "Installed this script to $selfTarget"
}

$hooks = Join-Path $RunnerRoot 'hooks'
New-Item -ItemType Directory -Force -Path $hooks | Out-Null
Write-HookFiles -Destination $hooks | Out-Null

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
if ($SkipRegistration) {
  Info ''
  Info 'Toolchain installed. To finish, run this from an ELEVATED PowerShell'
  Info 'on the machine itself -- config.cmd prompts for the account password on'
  Info 'an interactive console, which a remote or scripted session cannot answer:'
  Info ''
  Info "    `$env:GITHUB_PAT = '<classic PAT>'"
  Info "    $selfTarget -ServiceAccount '$ServiceAccount' -SkipToolchain"
  Info ''
  exit 0
}
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
