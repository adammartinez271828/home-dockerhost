#!/usr/bin/env bash
# Deploy the kiosk unit to kitchen-kiosk over ssh (run from the desktop; the
# kiosk holds no clone of this repo). Idempotent: `install` overwrites the
# wrapper, screen script, Wi-Fi watchdog, nightly-restart timer + stale-Chromium hook, crash watcher, units, PAM file,
# logrotate + apt drop-ins and Chromium policy;
# /etc/default/kinboard-kiosk is created only if
# absent so local tuning survives (missing KIOSK_SCREEN_*/KIOSK_NET_* knobs are appended). It also pins the HDMI connector
# as "connected" (video=<output>:e on the kernel cmdline, applied live via debugfs too) so the monitor's
# standby hotplug pulse cannot resurrect a screen that the schedule turned off. Then daemon-reload,
# graphical.target, enable cage@tty1, the screen/net/restart timers and the crash-dump path unit. --restart also restarts the unit (needed to pick up a
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
for f in kinboard-kiosk kinboard-kiosk-screen kinboard-kiosk-screen.service kinboard-kiosk-screen.timer \
	kinboard-kiosk-net kinboard-kiosk-net.service kinboard-kiosk-net.timer \
	kinboard-kiosk-restart.service kinboard-kiosk-restart.timer kinboard-kiosk-stale-chromium \
	kinboard-kiosk-crash kinboard-kiosk-crash.path kinboard-kiosk-crash.service \
	logrotate-kinboard-kiosk-net apt.conf.d-kinboard-kiosk \
	cage@.service pam.d-cage kinboard-kiosk.defaults.example chromium-policy.json; do
	[ -f "$here/$f" ] || { echo "missing $here/$f" >&2; exit 1; }
done
sh -n "$here/kinboard-kiosk" "$here/kinboard-kiosk-screen" "$here/kinboard-kiosk-net" "$here/kinboard-kiosk-stale-chromium" \
	"$here/kinboard-kiosk-crash"

ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10)
tmp="$(ssh "${ssh_opts[@]}" "$KIOSK_HOST" 'mktemp -d /tmp/kinboard-kiosk.XXXXXX')"
trap 'ssh "${ssh_opts[@]}" "$KIOSK_HOST" "rm -rf \"$tmp\"" || true' EXIT

echo "==> copying files to $KIOSK_HOST:$tmp"
scp -q "${ssh_opts[@]}" "$here/kinboard-kiosk" "$here/kinboard-kiosk-screen" \
	"$here/kinboard-kiosk-screen.service" "$here/kinboard-kiosk-screen.timer" "$here/cage@.service" \
	"$here/kinboard-kiosk-net" "$here/kinboard-kiosk-net.service" "$here/kinboard-kiosk-net.timer" \
	"$here/kinboard-kiosk-restart.service" "$here/kinboard-kiosk-restart.timer" "$here/kinboard-kiosk-stale-chromium" \
	"$here/kinboard-kiosk-crash" "$here/kinboard-kiosk-crash.path" "$here/kinboard-kiosk-crash.service" \
	"$here/logrotate-kinboard-kiosk-net" "$here/apt.conf.d-kinboard-kiosk" \
	"$here/pam.d-cage" "$here/kinboard-kiosk.defaults.example" "$here/chromium-policy.json" "$KIOSK_HOST:$tmp/"

echo "==> installing (sudo on the kiosk)"
# shellcheck disable=SC2029  # $tmp/$UNIT/$restart are meant to expand here
ssh "${ssh_opts[@]}" "$KIOSK_HOST" "set -eu; t='$tmp'; u='$UNIT'; r='$restart'
	sudo -n install -m 755 -o root -g root \"\$t/kinboard-kiosk\" /usr/local/bin/kinboard-kiosk
	sudo -n install -m 644 -o root -g root \"\$t/cage@.service\" /etc/systemd/system/cage@.service
	sudo -n install -m 755 -o root -g root \"\$t/kinboard-kiosk-screen\" /usr/local/bin/kinboard-kiosk-screen
	sudo -n install -m 644 -o root -g root \"\$t/kinboard-kiosk-screen.service\" /etc/systemd/system/kinboard-kiosk-screen.service
	sudo -n install -m 644 -o root -g root \"\$t/kinboard-kiosk-screen.timer\" /etc/systemd/system/kinboard-kiosk-screen.timer
	sudo -n install -m 755 -o root -g root \"\$t/kinboard-kiosk-net\" /usr/local/bin/kinboard-kiosk-net
	sudo -n install -m 644 -o root -g root \"\$t/kinboard-kiosk-net.service\" /etc/systemd/system/kinboard-kiosk-net.service
	sudo -n install -m 644 -o root -g root \"\$t/kinboard-kiosk-net.timer\" /etc/systemd/system/kinboard-kiosk-net.timer
	sudo -n install -m 644 -o root -g root \"\$t/kinboard-kiosk-restart.service\" /etc/systemd/system/kinboard-kiosk-restart.service
	sudo -n install -m 644 -o root -g root \"\$t/kinboard-kiosk-restart.timer\" /etc/systemd/system/kinboard-kiosk-restart.timer
	sudo -n install -m 755 -o root -g root \"\$t/kinboard-kiosk-stale-chromium\" /usr/local/bin/kinboard-kiosk-stale-chromium
	sudo -n install -m 755 -o root -g root \"\$t/kinboard-kiosk-crash\" /usr/local/bin/kinboard-kiosk-crash
	sudo -n install -m 644 -o root -g root \"\$t/kinboard-kiosk-crash.path\" /etc/systemd/system/kinboard-kiosk-crash.path
	sudo -n install -m 644 -o root -g root \"\$t/kinboard-kiosk-crash.service\" /etc/systemd/system/kinboard-kiosk-crash.service
	sudo -n install -m 644 -o root -g root \"\$t/logrotate-kinboard-kiosk-net\" /etc/logrotate.d/kinboard-kiosk-net
	sudo -n install -m 644 -o root -g root \"\$t/apt.conf.d-kinboard-kiosk\" /etc/apt/apt.conf.d/52kinboard-kiosk
	sudo -n touch /var/log/kinboard-kiosk-net.log /var/log/kinboard-kiosk-crash.log
	sudo -n chmod 644 /var/log/kinboard-kiosk-crash.log
	sudo -n chmod 644 /var/log/kinboard-kiosk-net.log
	sudo -n install -m 644 -o root -g root \"\$t/pam.d-cage\" /etc/pam.d/cage
	sudo -n install -d -m 755 -o root -g root /etc/chromium/policies/managed
	sudo -n install -m 644 -o root -g root \"\$t/chromium-policy.json\" /etc/chromium/policies/managed/kinboard-kiosk.json
	if [ ! -e /etc/default/kinboard-kiosk ]; then
		sudo -n install -m 644 -o root -g root \"\$t/kinboard-kiosk.defaults.example\" /etc/default/kinboard-kiosk
		echo 'created /etc/default/kinboard-kiosk from the example'
	else
		echo 'kept existing /etc/default/kinboard-kiosk'
		if ! grep -q '^#*KIOSK_SCREEN_OFF=' /etc/default/kinboard-kiosk; then
			sed -n '/^# Nightly screen-off window/,\$p' \"\$t/kinboard-kiosk.defaults.example\" | sudo -n tee -a /etc/default/kinboard-kiosk >/dev/null
			echo 'appended KIOSK_SCREEN_OFF/ON defaults to /etc/default/kinboard-kiosk'
		fi
		if ! grep -q '^#*KIOSK_NET_FAILS=' /etc/default/kinboard-kiosk; then
			sed -n '/^# Wi-Fi reachability watchdog/,/^# Chromium crash auto-restart/{/^# Chromium crash auto-restart/!p}' \"\$t/kinboard-kiosk.defaults.example\" | sudo -n tee -a /etc/default/kinboard-kiosk >/dev/null
			echo 'appended KIOSK_NET_* defaults to /etc/default/kinboard-kiosk'
		fi
		if ! grep -q '^#*KIOSK_CRASH_MAX_PER_HOUR=' /etc/default/kinboard-kiosk; then
			{ echo; sed -n '/^# Chromium crash auto-restart/,\$p' \"\$t/kinboard-kiosk.defaults.example\"; } | sudo -n tee -a /etc/default/kinboard-kiosk >/dev/null
			echo 'appended KIOSK_CRASH_* defaults to /etc/default/kinboard-kiosk'
		fi
	fi
	# Force the connector status to connected: the BenQ pulses HDMI hotplug ~14 s after it loses
	# signal (entering standby); wlroots then destroys and recreates the output, which Cage brings back
	# up enabled at transform normal / scale 1, so a scheduled screen-off flashed back on every minute
	# (2026-09-10). With the status forced, wlroots sees no change and the output stays off.
	out=\$(sed -n 's/^KIOSK_OUTPUT=//p' /etc/default/kinboard-kiosk 2>/dev/null | tail -1); out=\${out:-HDMI-A-1}
	cmdline=/boot/firmware/cmdline.txt
	if [ -f \"\$cmdline\" ] && ! grep -q \"video=\$out:e\" \"\$cmdline\"; then
		sudo -n cp -n \"\$cmdline\" \"\$cmdline.bak\"
		sudo -n sed -i \"1s/[[:space:]]*\$/ video=\$out:e/\" \"\$cmdline\"
		echo \"appended video=\$out:e to \$cmdline (persists from the next reboot)\"
	fi
	for f in /sys/kernel/debug/dri/*/\"\$out\"/force; do
		[ -e \"\$f\" ] || continue
		[ \"\$(sudo -n cat \"\$f\")\" = on ] || { echo on | sudo -n tee \"\$f\" >/dev/null && echo \"forced \$out connected now via \$f\"; }
	done
	sudo -n systemctl daemon-reload
	[ \"\$(systemctl get-default)\" = graphical.target ] || sudo -n systemctl set-default graphical.target
	sudo -n systemctl enable \"\$u\" 2>&1 | grep -v '^\$' || true
	sudo -n systemctl enable --now kinboard-kiosk-screen.timer 2>&1 | grep -v '^\$' || true
	sudo -n systemctl enable --now kinboard-kiosk-net.timer 2>&1 | grep -v '^\$' || true
	sudo -n systemctl enable --now kinboard-kiosk-restart.timer 2>&1 | grep -v '^\$' || true
	sudo -n systemctl enable --now kinboard-kiosk-crash.path 2>&1 | grep -v '^\$' || true
	if [ \"\$r\" = 1 ]; then sudo -n systemctl restart \"\$u\"; sleep 3; fi
	echo \"==> \$u: \$(systemctl is-enabled \"\$u\") / \$(systemctl is-active \"\$u\" || true); default target \$(systemctl get-default)\"
	echo \"==> kinboard-kiosk-screen.timer: \$(systemctl is-active kinboard-kiosk-screen.timer || true); \$(/usr/local/bin/kinboard-kiosk-screen status 2>&1 || true)\"
	echo \"==> kinboard-kiosk-restart.timer: \$(systemctl is-active kinboard-kiosk-restart.timer || true), next \$(systemctl show kinboard-kiosk-restart.timer -p NextElapseUSecRealtime --value || true); \$(sudo -n /usr/local/bin/kinboard-kiosk-stale-chromium --check 2>&1 || true)\"
	echo \"==> kinboard-kiosk-crash.path: \$(systemctl is-active kinboard-kiosk-crash.path || true); \$(sudo -n tail -n 1 /var/log/kinboard-kiosk-crash.log 2>/dev/null || true)\"
	echo \"==> kinboard-kiosk-net.timer: \$(systemctl is-active kinboard-kiosk-net.timer || true); \$(sudo -n /usr/local/bin/kinboard-kiosk-net status 2>&1 || true)\"
"
