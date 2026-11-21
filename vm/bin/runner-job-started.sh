#!/usr/bin/env bash
# Job-started hook of the runner (ACTIONS_RUNNER_HOOK_JOB_STARTED).
# Each runner has its own HOME, and each job starts with an empty one, the
# same as on a new GitHub-hosted VM. So nothing (helm plugins, docker logins,
# git config) stays from the job before. Caches come from actions/cache.
# $HOME/work is the work folder of the runner (checkouts, tool cache, the
# files of this job) and stays.
set -euo pipefail

case "$HOME" in
  /opt/actions-runner/*/home) ;;
  *) echo "HOME is $HOME, not a runner home: nothing removed." >&2; exit 0 ;;
esac
# Go keeps its module cache (~/go/pkg/mod) read-only; make it writable first.
find "$HOME" -mindepth 1 -maxdepth 1 ! -name work -exec chmod -R u+w {} +
find "$HOME" -mindepth 1 -maxdepth 1 ! -name work -exec rm -rf {} +
