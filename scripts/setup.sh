#!/bin/bash
# One-time provisioning for a fresh Debian/Pi dockerhost. Run once as root.
# Uses bash features ([[ ]], echo -e), so it must not be invoked via /bin/sh.

set -ex

# basic config
if [[ `tail /etc/profile` != *neofetch* ]]; then
	echo -e "\n\nneofetch\n" >> /etc/profile
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
apt-get -y install git vim neofetch ca-certificates curl gnupg avahi-daemon avahi-utils

# install docker
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
  "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
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
