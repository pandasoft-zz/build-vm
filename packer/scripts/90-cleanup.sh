#!/usr/bin/env bash
# Make the image small, remove the build login and prepare cloud-init, so each
# VM gets its own SSH key, host name, machine-id and SSH host keys on first boot.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
: "${RUNNER_USER:?}"

# --- Login: only the SSH key from the seed disk, no password. -------------
passwd -l "$RUNNER_USER"
rm -f "/home/$RUNNER_USER/.ssh/authorized_keys"
cat > /etc/ssh/sshd_config.d/10-build-vm.conf <<'CONF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
CONF

# --- cloud-init: read the NoCloud seed disk on first boot. ----------------
# The installer leaves its own config, which turns off the data sources and
# the network config. Remove it.
rm -f /etc/cloud/cloud.cfg.d/99-installer.cfg \
      /etc/cloud/cloud.cfg.d/90-installer-network.cfg \
      /etc/cloud/cloud.cfg.d/subiquity-disable-cloudinit-networking.cfg \
      /etc/cloud/cloud-init.disabled
cat > /etc/cloud/cloud.cfg.d/90-build-vm.cfg <<'CONF'
datasource_list: [ NoCloud, None ]
CONF
# The network config of the build VM (QEMU) does not match the Hyper-V NIC.
# cloud-init writes a new one from the seed disk.
rm -f /etc/netplan/*.yaml
cloud-init clean --logs --seed --machine-id

# --- Size. ----------------------------------------------------------------
apt-get -y autoremove --purge
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
{ journalctl --rotate; journalctl --vacuum-time=1s; } || true
fstrim -av || true
