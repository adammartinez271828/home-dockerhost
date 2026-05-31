#!/bin/bash
# Publish mDNS (.local) aliases for services hosted on this box.
#
# Reads one hostname per line from the aliases file (default: ./aliases next to
# this script) and publishes an mDNS address record for each, pointing at this
# host's LAN IP. Requires avahi-utils (provides avahi-publish).
#
# Run as a long-lived process (see mdns-aliases.service): each avahi-publish
# stays in the foreground for as long as the alias should be advertised. If any
# one publisher dies (e.g. a name collision), we exit non-zero so systemd
# (Restart=on-failure) re-publishes the whole set rather than leaving a name
# silently unadvertised. Uses bash for `wait -n`.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ALIASES_FILE="${ALIASES_FILE:-$SCRIPT_DIR/aliases}"
IP="${MDNS_IP:-192.168.86.197}"

pids=""
# `|| [ -n "$name" ]` so a final line without a trailing newline isn't dropped.
while IFS= read -r name || [ -n "$name" ]; do
	# skip blank lines and comments
	case "$name" in
		''|\#*) continue ;;
	esac
	# -a: publish an address record
	# -R: do NOT publish a reverse (PTR) record, so multiple names can share
	#     one IP without colliding
	avahi-publish -a -R "$name" "$IP" &
	pids="$pids $!"
done < "$ALIASES_FILE"

if [ -z "$pids" ]; then
	echo "mdns-aliases: no hostnames to publish in $ALIASES_FILE" >&2
	exit 1
fi

# All publishers should stay up forever; systemd terminates them on stop. If
# `wait -n` returns, one exited on its own — treat that as failure: stop the
# rest and exit non-zero so the service restarts and re-publishes everything.
wait -n || true
echo "mdns-aliases: a publisher exited unexpectedly; restarting all aliases" >&2
kill $pids 2>/dev/null || true
exit 1
