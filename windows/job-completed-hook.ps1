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
