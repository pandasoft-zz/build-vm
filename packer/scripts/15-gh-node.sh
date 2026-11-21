#!/usr/bin/env bash
# GitHub CLI and Node.js. GitHub-hosted runners have both, and some jobs call
# `gh` and `npx` without a setup action.
# Docs: https://github.com/cli/cli/blob/trunk/docs/install_linux.md
#       https://github.com/nodesource/distributions
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
: "${NODE_MAJOR:?}"

install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  > /etc/apt/sources.list.d/github-cli.list

curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
  | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
  > /etc/apt/sources.list.d/nodesource.list

apt-get update
apt-get install -y gh nodejs
