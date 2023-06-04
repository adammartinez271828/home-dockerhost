#!/bin/sh

# basic config
if [[ `tail /etc/profile` != *neofetch* ]]; then
	echo -e "\n\nneofetch\n" >> /etc/profile
fi
cat /etc/motd >> /etc/motd.old
rm /etc/motd
touch /etc/motd

# update
apt update
apt -y upgrade
apt -y install git vim neofetch ca-certificates curl gnupg

# install docker
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
  "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update
apt -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

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
