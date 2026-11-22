#!/usr/bin/env bash
# GitHub Actions runner. The image holds one unpacked copy (a template);
# runner-add copies it once for each repository.
# Docs: https://docs.github.com/en/actions/hosting-your-own-runners
set -euo pipefail

# Version and SHA-256 come from build-vm.pkr.hcl (see update-versions.sh).
: "${RUNNER_VERSION:?}" "${RUNNER_SHA256:?}" "${RUNNER_USER:?}"
version=$RUNNER_VERSION

file="actions-runner-linux-x64-${version}.tar.gz"
curl -fsSL -o "/tmp/$file" "https://github.com/actions/runner/releases/download/v${version}/${file}"
echo "${RUNNER_SHA256}  /tmp/$file" | sha256sum -c -

template=/opt/actions-runner/template
rm -rf "$template"
mkdir -p "$template"
tar -xzf "/tmp/$file" -C "$template"
rm -f "/tmp/$file"
"$template/bin/installdependencies.sh"
chown -R "$RUNNER_USER:$RUNNER_USER" /opt/actions-runner
echo "Installed actions/runner v$version"

# Helper scripts and the weekly Docker clean-up.
install -m 0755 /tmp/vm-files/bin/runner-add /usr/local/bin/runner-add
install -m 0755 /tmp/vm-files/bin/runner-remove /usr/local/bin/runner-remove
install -m 0755 /tmp/vm-files/bin/runner-list /usr/local/bin/runner-list
install -m 0755 /tmp/vm-files/bin/runner-job-started.sh /usr/local/bin/runner-job-started.sh
install -m 0644 /tmp/vm-files/systemd/docker-prune.service /etc/systemd/system/docker-prune.service
install -m 0644 /tmp/vm-files/systemd/docker-prune.timer /etc/systemd/system/docker-prune.timer
systemctl enable docker-prune.timer

echo "RUNNER_USER=$RUNNER_USER" > /etc/build-vm.conf
