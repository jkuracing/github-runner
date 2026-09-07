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
