#!/usr/bin/env bash
# Deploy the kiosk unit to kitchen-kiosk over ssh (run from the desktop; the
# kiosk holds no clone of this repo). Idempotent: `install` overwrites the
# wrapper, unit, PAM file and Chromium policy; /etc/default/kinboard-kiosk is created only if
# absent so local tuning survives. Then daemon-reload, graphical.target,
# enable cage@tty1. --restart also restarts the unit (needed to pick up a
# changed wrapper or unit; a running kiosk is otherwise left alone).
#
#   kiosk/install.sh [--restart]        KIOSK_HOST=kiosk@kitchen-kiosk.local
set -euo pipefail

KIOSK_HOST="${KIOSK_HOST:-kiosk@kitchen-kiosk.local}"
UNIT=cage@tty1.service
restart=0
for arg in "$@"; do
	case "$arg" in
		--restart) restart=1 ;;
		-h|--help) sed -n '2,10p' "$0"; exit 0 ;;
		*) echo "unknown argument: $arg" >&2; exit 2 ;;
	esac
done

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for f in kinboard-kiosk cage@.service pam.d-cage kinboard-kiosk.defaults.example chromium-policy.json; do
	[ -f "$here/$f" ] || { echo "missing $here/$f" >&2; exit 1; }
done
sh -n "$here/kinboard-kiosk"

ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10)
tmp="$(ssh "${ssh_opts[@]}" "$KIOSK_HOST" 'mktemp -d /tmp/kinboard-kiosk.XXXXXX')"
trap 'ssh "${ssh_opts[@]}" "$KIOSK_HOST" "rm -rf \"$tmp\"" || true' EXIT

echo "==> copying files to $KIOSK_HOST:$tmp"
scp -q "${ssh_opts[@]}" "$here/kinboard-kiosk" "$here/cage@.service" \
	"$here/pam.d-cage" "$here/kinboard-kiosk.defaults.example" "$here/chromium-policy.json" "$KIOSK_HOST:$tmp/"

echo "==> installing (sudo on the kiosk)"
# shellcheck disable=SC2029  # $tmp/$UNIT/$restart are meant to expand here
ssh "${ssh_opts[@]}" "$KIOSK_HOST" "set -eu; t='$tmp'; u='$UNIT'; r='$restart'
	sudo -n install -m 755 -o root -g root \"\$t/kinboard-kiosk\" /usr/local/bin/kinboard-kiosk
	sudo -n install -m 644 -o root -g root \"\$t/cage@.service\" /etc/systemd/system/cage@.service
	sudo -n install -m 644 -o root -g root \"\$t/pam.d-cage\" /etc/pam.d/cage
	sudo -n install -d -m 755 -o root -g root /etc/chromium/policies/managed
	sudo -n install -m 644 -o root -g root \"\$t/chromium-policy.json\" /etc/chromium/policies/managed/kinboard-kiosk.json
	if [ ! -e /etc/default/kinboard-kiosk ]; then
		sudo -n install -m 644 -o root -g root \"\$t/kinboard-kiosk.defaults.example\" /etc/default/kinboard-kiosk
		echo 'created /etc/default/kinboard-kiosk from the example'
	else
		echo 'kept existing /etc/default/kinboard-kiosk'
	fi
	sudo -n systemctl daemon-reload
	[ \"\$(systemctl get-default)\" = graphical.target ] || sudo -n systemctl set-default graphical.target
	sudo -n systemctl enable \"\$u\" 2>&1 | grep -v '^\$' || true
	if [ \"\$r\" = 1 ]; then sudo -n systemctl restart \"\$u\"; sleep 3; fi
	echo \"==> \$u: \$(systemctl is-enabled \"\$u\") / \$(systemctl is-active \"\$u\" || true); default target \$(systemctl get-default)\"
"
