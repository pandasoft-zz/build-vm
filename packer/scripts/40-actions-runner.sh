#!/usr/bin/env bash
# GitHub Actions runner. The image holds one unpacked copy (a template);
# runner-add copies it once for each repository.
# Docs: https://docs.github.com/en/actions/hosting-your-own-runners
set -euo pipefail

: "${RUNNER_VERSION:?}" "${RUNNER_USER:?}"
api=https://api.github.com/repos/actions/runner/releases

if [ "$RUNNER_VERSION" = latest ]; then
  release=$(curl -fsSL "$api/latest")
else
  release=$(curl -fsSL "$api/tags/v${RUNNER_VERSION}")
fi
version=$(jq -r '.tag_name' <<<"$release" | sed 's/^v//')
# The release notes carry the SHA-256 of each package between these markers.
sha=$(jq -r '.body' <<<"$release" | sed -n 's/.*<!-- BEGIN SHA linux-x64 -->\([0-9a-f]\{64\}\)<!-- END SHA linux-x64 -->.*/\1/p')
[ -n "$sha" ] || { echo "No SHA-256 for linux-x64 in the notes of runner v$version" >&2; exit 1; }

file="actions-runner-linux-x64-${version}.tar.gz"
curl -fsSL -o "/tmp/$file" "https://github.com/actions/runner/releases/download/v${version}/${file}"
echo "${sha}  /tmp/$file" | sha256sum -c -

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
install -m 0755 /tmp/vm-files/bin/runner-job-started /usr/local/bin/runner-job-started
install -m 0644 /tmp/vm-files/systemd/docker-prune.service /etc/systemd/system/docker-prune.service
install -m 0644 /tmp/vm-files/systemd/docker-prune.timer /etc/systemd/system/docker-prune.timer
systemctl enable docker-prune.timer

echo "RUNNER_USER=$RUNNER_USER" > /etc/build-vm.conf
