#!/bin/sh
# Publish mDNS (.local) aliases for services hosted on this box.
#
# Reads one hostname per line from the aliases file (default: ./aliases next to
# this script) and publishes an mDNS address record for each, pointing at this
# host's LAN IP. Requires avahi-utils (provides avahi-publish).
#
# Run as a long-lived process (see mdns-aliases.service): each avahi-publish
# stays in the foreground for as long as the alias should be advertised.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ALIASES_FILE="${ALIASES_FILE:-$SCRIPT_DIR/aliases}"
IP="${MDNS_IP:-192.168.86.197}"

while read -r name; do
	# skip blank lines and comments
	case "$name" in
		''|\#*) continue ;;
	esac
	# -a: publish an address record
	# -R: do NOT publish a reverse (PTR) record, so multiple names can share
	#     one IP without colliding
	avahi-publish -a -R "$name" "$IP" &
done < "$ALIASES_FILE"

# Wait on the background avahi-publish processes; systemd terminates them
# (and this script) on stop.
wait
