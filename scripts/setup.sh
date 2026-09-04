#!/bin/bash
# One-time provisioning for a fresh Debian/Pi dockerhost. Run once as root.
# Uses bash features ([[ ]], echo -e), so it must not be invoked via /bin/sh.

set -ex

# basic config: system summary at login. Trixie dropped neofetch for fastfetch;
# guard with command -v so a login never errors if the package is missing.
if [[ $(tail /etc/profile) != *fastfetch* ]]; then
	echo -e "\n\ncommand -v fastfetch >/dev/null && fastfetch\n" >> /etc/profile
fi
# archive then blank the default motd (idempotent: only if motd has content)
if [ -s /etc/motd ]; then
	cat /etc/motd >> /etc/motd.old
	: > /etc/motd
fi

# set config on a pi to allow docker to see app memory (idempotent: append once).
# On Bookworm this file lives at /boot/firmware/cmdline.txt.
CMDLINE=/boot/cmdline.txt
[ -f /boot/firmware/cmdline.txt ] && CMDLINE=/boot/firmware/cmdline.txt
if ! grep -q cgroup_memory "$CMDLINE"; then
	echo -n " cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory" >> "$CMDLINE"
fi

# update
apt-get update
apt-get -y upgrade
# also installs shellcheck for the pre-commit hook (see .githooks/); the Pi commits too
apt-get -y install git vim fastfetch ca-certificates curl gnupg avahi-daemon avahi-utils shellcheck

# install docker
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

arch=$(dpkg --print-architecture)
# shellcheck disable=SC1091  # /etc/os-release exists on the Debian host, not at lint time
codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
echo \
  "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $codename stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update
apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# add pi user to docker group
usermod -aG docker pi

# configure basic log rotation
cat << EOF > /etc/docker/daemon.json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

# start the service
systemctl enable docker.service
systemctl enable containerd.service

# enable the repo's git pre-commit hook (shellcheck + compose validation) for
# the pi user's clone, so provisioning yields a working hook. Deps (shellcheck,
# compose plugin) are installed above. Run as pi to avoid root-owning .git/config.
REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
sudo -u pi git -C "$REPO_ROOT" config core.hooksPath .githooks
