#!/usr/bin/env bash
# Base packages. The list follows what the CI jobs call outside setup-* actions.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get -y full-upgrade
apt-get install -y --no-install-recommends \
  build-essential ca-certificates curl wget git git-lfs gnupg jq \
  unzip zip xz-utils zstd tar rsync file lsb-release \
  python3 python3-venv python3-pip \
  libvips-dev \
  openjdk-21-jdk-headless

# The same locale and time zone as GitHub-hosted runners.
timedatectl set-timezone Etc/UTC || true

# More inotify watches for Node and Gradle builds.
cat > /etc/sysctl.d/90-ci.conf <<'CONF'
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
CONF
