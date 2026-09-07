#!/usr/bin/env bash
# Install the Beszel agent on kitchen-kiosk over ssh so the hub on dockerhost
# (docs/beszel.md) can chart the kiosk too: SoC temperature, memory (a
# weeks-old Chromium), SD-card fill, Wi-Fi throughput and the cage@tty1 unit.
# Run from the desktop; the kiosk holds no clone of this repo.
#
# Installs upstream's .deb, pinned to the hub's version (AGENT_VERSION below,
# sha256-checked), and writes /etc/beszel-agent.conf with the hub's public
# KEY plus SERVICE_PATTERNS. The agent listens on TCP 45876 on the LAN and
# the hub connects *to* it, so nothing on the kiosk needs to resolve
# beszel.local (mDNS over Wi-Fi is unreliable there). It only answers a hub
# that signs with the matching private key. Idempotent: re-running upgrades
# or reinstalls the package and rewrites the config.
#
# The KEY comes from (first hit wins): $BESZEL_KEY, env.d/beszel.env in this
# clone, or env.d/beszel.env in the dockerhost clone over ssh ($DOCKER_HOST).
#
#   kiosk/install-beszel-agent.sh      KIOSK_HOST=kiosk@kitchen-kiosk.local
#                                      DOCKER_HOST=pi@dockerhost.local
#
# Afterwards, in the hub UI (http://beszel.local): Add System, name
# kitchen-kiosk, host 192.168.86.206, port 45876.
set -euo pipefail

AGENT_VERSION=0.19.0   # keep equal to the henrygd/beszel image tags in docker-compose.yml
AGENT_ARCH=arm64
AGENT_SHA256=a037bb1822302d40a3c67ad56aa40c916742f61a27a498f991f222e303845eef
KIOSK_HOST="${KIOSK_HOST:-kiosk@kitchen-kiosk.local}"
DOCKER_HOST="${DOCKER_HOST:-pi@dockerhost.local}"
SERVICE_PATTERNS="cage@tty1.service,NetworkManager.service,unattended-upgrades.service"

for arg in "$@"; do
	case "$arg" in
		-h|--help) sed -n '2,24p' "$0"; exit 0 ;;
		*) echo "unknown argument: $arg" >&2; exit 2 ;;
	esac
done

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10)

# --- hub public key --------------------------------------------------------
key="${BESZEL_KEY:-}"
if [ -z "$key" ] && [ -f "$repo/env.d/beszel.env" ]; then
	key="$(sed -n 's/^KEY=//p' "$repo/env.d/beszel.env" | head -1)"
fi
if [ -z "$key" ]; then
	echo "==> reading KEY from $DOCKER_HOST:~/devel/home-dockerhost/env.d/beszel.env"
	key="$(ssh "${ssh_opts[@]}" "$DOCKER_HOST" \
		"sed -n 's/^KEY=//p' ~/devel/home-dockerhost/env.d/beszel.env | head -1")"
fi
case "$key" in
	ssh-ed25519\ *) ;;
	*) echo "no usable hub key (want 'ssh-ed25519 AAAA...'); set BESZEL_KEY or fill env.d/beszel.env" >&2; exit 1 ;;
esac

# --- fetch + verify the pinned package locally ----------------------------
deb="beszel-agent_${AGENT_VERSION}_linux_${AGENT_ARCH}.deb"
url="https://github.com/henrygd/beszel/releases/download/v${AGENT_VERSION}/${deb}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
echo "==> downloading $url"
curl -fsSL -o "$work/$deb" "$url"
echo "$AGENT_SHA256  $work/$deb" | sha256sum -c - >/dev/null || {
	echo "sha256 mismatch for $deb; update AGENT_SHA256 if you bumped AGENT_VERSION" >&2; exit 1; }

# The .deb's postinst asks debconf for the key only when the config has no
# KEY= line, so writing the config first keeps the install non-interactive.
cat > "$work/beszel-agent.conf" <<CONF
# Beszel agent on kitchen-kiosk; installed by kiosk/install-beszel-agent.sh
# from the home-dockerhost repo -- edit there and re-run, not here.
KEY=$key
SERVICE_PATTERNS=$SERVICE_PATTERNS
CONF

# --- install on the kiosk --------------------------------------------------
tmp="$(ssh "${ssh_opts[@]}" "$KIOSK_HOST" 'mktemp -d /tmp/beszel-agent.XXXXXX')"
trap 'rm -rf "$work"; ssh "${ssh_opts[@]}" "$KIOSK_HOST" "rm -rf \"$tmp\"" || true' EXIT
echo "==> copying to $KIOSK_HOST:$tmp"
scp -q "${ssh_opts[@]}" "$work/$deb" "$work/beszel-agent.conf" "$KIOSK_HOST:$tmp/"

echo "==> installing (sudo on the kiosk)"
# shellcheck disable=SC2029  # $tmp/$deb are meant to expand here
ssh "${ssh_opts[@]}" "$KIOSK_HOST" "set -eu; t='$tmp'; d='$deb'
	sudo -n install -m 600 -o root -g root \"\$t/beszel-agent.conf\" /etc/beszel-agent.conf
	sudo -n env DEBIAN_FRONTEND=noninteractive dpkg -i \"\$t/\$d\" 2>&1 | grep -Ev '^(Selecting|Preparing|Unpacking|\(Reading)' || true
	# the package creates the 'beszel' user; the config must be readable by it
	sudo -n chown beszel:beszel /etc/beszel-agent.conf
	sudo -n systemctl enable --now beszel-agent.service 2>&1 | grep -v '^\$' || true
	sudo -n systemctl restart beszel-agent.service
	sleep 2
	echo \"==> beszel-agent \$(beszel-agent --version 2>/dev/null || true): \$(systemctl is-enabled beszel-agent) / \$(systemctl is-active beszel-agent || true)\"
	ss -ltn | grep -q ':45876 ' && echo '==> listening on 45876' || { echo 'not listening on 45876' >&2; journalctl -u beszel-agent -n 20 --no-pager; exit 1; }
"
echo "==> now add the system in the hub UI: http://beszel.local -> Add System, name kitchen-kiosk, host 192.168.86.206, port 45876"
