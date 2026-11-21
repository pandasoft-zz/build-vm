#!/usr/bin/env bash
# Job-started hook of the runner (ACTIONS_RUNNER_HOOK_JOB_STARTED).
# Each runner has its own HOME, and each job starts with an empty one, the
# same as on a new GitHub-hosted VM. So nothing (helm plugins, docker logins,
# git config) stays from the job before. Caches come from actions/cache.
set -euo pipefail

case "$HOME" in
  /opt/actions-runner/*/home) ;;
  *) echo "HOME is $HOME, not a runner home: nothing removed." >&2; exit 0 ;;
esac
find "$HOME" -mindepth 1 -delete
