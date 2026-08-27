#!/bin/bash
# Runs before EVERY job on this replica, via ACTIONS_RUNNER_HOOK_JOB_STARTED.
#
# Why this exists
# ----------------
# A shared setup snippet used across canvas-consuming repos (bender-driver,
# dti-fsic-driver, vehicle-message-definitions, and others being migrated onto
# this fleet) configures a git `insteadOf` rewrite with
# `git config --global set` (then `--add` for a second value under the same
# key). On an ephemeral GitHub-hosted runner this is harmless: the VM, and
# $HOME/.gitconfig with it, is destroyed the moment the job ends.
#
# On this fleet the container -- and therefore the runner user's
# $HOME/.gitconfig -- outlives any one job, so values written by `--add`
# accumulate under the same key across every job a replica has ever run. A
# later job's plain `set` call then collides with an already multi-valued key
# and the whole step fails with:
#   error: cannot overwrite multiple values with a single value
# This is invisible in any single job and only shows up after a replica has
# served enough canvas-consuming jobs to pile up a second value -- which is
# exactly what surfaced once bender-driver/dti-fsic-driver/
# vehicle-message-definitions started sharing this fleet with firmware/hbf.
#
# Why a job-STARTED hook, and not (only) job-completed-hook.sh
# --------------------------------------------------------------
# job-completed-hook.sh (see its own header) only runs after a job finishes
# normally. A cancelled, timed-out, or forcibly-killed job skips it entirely,
# and that job's accumulated $HOME/.gitconfig survives into the next one --
# exactly the collision this hook exists to prevent. A job-STARTED hook runs
# before every job regardless of how the PREVIOUS job ended, so it is the only
# placement that actually closes the gap rather than narrowing it.
#
# What "clean baseline" means here
# ---------------------------------
# Nothing in this image's build or entrypoint.sh ever writes to
# $HOME/.gitconfig for the runner user -- verified by grep, not assumed -- so
# the baseline a freshly created container starts with is simply the file's
# absence. This hook reproduces exactly that, every time, rather than trying
# to selectively undo just the insteadOf rewrite (which would have to know
# every key any consuming repo's setup snippet might someday add).
set -uo pipefail

rm -f "${HOME:-/home/runner}/.gitconfig"

# Never fail the job. Like job-completed-hook.sh, this runs adjacent to work
# that must not be put at risk by a cleanup step -- a non-zero exit here would
# fail the job it is meant to protect.
exit 0
