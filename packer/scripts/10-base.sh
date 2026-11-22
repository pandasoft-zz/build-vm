#!/usr/bin/env bash
# Base packages. The list follows what the CI jobs call outside setup-* actions,
# plus the small everyday tools of the GitHub-hosted Ubuntu image
# (https://github.com/actions/runner-images, Ubuntu2404-Readme.md).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get -y full-upgrade
apt-get install -y --no-install-recommends \
  build-essential pkg-config ca-certificates curl wget aria2 git git-lfs gnupg jq \
  unzip zip xz-utils zstd bzip2 lz4 pigz brotli p7zip-full tar rsync file tree \
  lsb-release acl time parallel gettext-base sqlite3 \
  openssh-client dnsutils iputils-ping iproute2 netcat-openbsd \
  python3 python3-venv python3-pip python3-yaml python-is-python3 pipx \
  shellcheck yamllint \
  libssl-dev libyaml-dev libsqlite3-dev libicu-dev \
  libvips-dev \
  openjdk-21-jdk-headless

# The same locale and time zone as GitHub-hosted runners.
timedatectl set-timezone Etc/UTC || true

# More inotify watches for Node and Gradle builds.
cat > /etc/sysctl.d/90-ci.conf <<'CONF'
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
CONF
