#!/bin/bash
# Restore a recipes DB dump — by default into a THROWAWAY Postgres container,
# never the live one. Runbook: docs/backup-restore.md.
#
#   scripts/db-restore.sh --list                  list dumps on the cloud remote
#   scripts/db-restore.sh --from-cloud [NAME]     fetch NAME (default: newest
#                                                 daily) and restore it into a
#                                                 fresh con_db_restoretest
#   scripts/db-restore.sh FILE                    restore a local dump the same way
#   ... --live [--yes]                            restore into the LIVE db_recipes
#                                                 instead (stops the web app,
#                                                 takes a safety dump first,
#                                                 drops + recreates the DB)
#   ... --rm                                      remove the throwaway container
#                                                 after printing its stats
#
# Every restore ends with a table of row counts (tables / recipes / foods /
# users / newest recipe) so you can judge the result at a glance; in test mode
# the live DB's counts are shown alongside when it is running.
set -euo pipefail

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO_ROOT"

usage() {
	sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
	exit 2
}

log() { printf '%s db-restore: %s\n' "$(date '+%F %T')" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

env_get() {
	local v
	v=$(grep -E "^$2=" "$1" 2>/dev/null | tail -n1 | cut -d= -f2-) || true
	printf '%s' "${v:-$3}"
}

DB_CONTAINER=${DB_CONTAINER:-con_db_recipes}
TEST_CONTAINER=${TEST_CONTAINER:-con_db_restoretest}
BACKUP_DIR=${BACKUP_DIR:-backups}
BACKUP_ENV_FILE=${BACKUP_ENV_FILE:-env.d/backup.env}
PGUSER=$(env_get env.d/recipes.env POSTGRES_USER djangouser)
PGDB=$(env_get env.d/recipes.env POSTGRES_DB djangodb)
REMOTE=$(env_get "$BACKUP_ENV_FILE" RCLONE_REMOTE '')

rpath() {
	case "${REMOTE%/}" in
		*:) printf '%s%s' "${REMOTE%/}" "$1" ;;
		*)  printf '%s/%s' "${REMOTE%/}" "$1" ;;
	esac
}
need_remote() {
	command -v rclone >/dev/null 2>&1 || die "rclone not installed"
	[ -n "$REMOTE" ] || die "RCLONE_REMOTE not set in $BACKUP_ENV_FILE"
}

# --- args ---------------------------------------------------------------------
mode="test"; confirmed=0; rm_after=0; src=""; from_cloud=0; cloud_name=""
while [ $# -gt 0 ]; do
	case "$1" in
		--list)
			need_remote
			for d in daily monthly; do
				echo "== $(rpath db/$d)"
				rclone lsl "$(rpath db/$d)" 2>/dev/null || echo "  (empty)"
			done
			exit 0 ;;
		--from-cloud)
			from_cloud=1
			if [ $# -gt 1 ] && [ "${2#-}" = "$2" ]; then cloud_name=$2; shift; fi ;;
		--live) mode=live ;;
		--yes)  confirmed=1 ;;
		--rm)   rm_after=1 ;;
		-h|--help) usage ;;
		-*) echo "unknown option: $1" >&2; usage ;;
		*)  [ -z "$src" ] || usage; src=$1 ;;
	esac
	shift
done
[ "$from_cloud" -eq 1 ] || [ -n "$src" ] || usage
[ "$from_cloud" -eq 1 ] && [ -n "$src" ] && usage

# --- fetch --------------------------------------------------------------------
if [ "$from_cloud" -eq 1 ]; then
	need_remote
	if [ -z "$cloud_name" ]; then
		cloud_name=$(rclone lsf "$(rpath db/daily)" | grep '^recipes-.*\.dump$' | sort | tail -n1)
		[ -n "$cloud_name" ] || die "no dumps found in $(rpath db/daily)"
	fi
	sub=''
	for d in daily monthly; do
		if rclone lsf "$(rpath "db/$d/$cloud_name")" 2>/dev/null | grep -qx "$cloud_name"; then sub=$d; break; fi
	done
	[ -n "$sub" ] || die "$cloud_name not found in db/daily or db/monthly on $REMOTE"
	mkdir -p "$BACKUP_DIR/restore"
	src="$BACKUP_DIR/restore/$cloud_name"
	log "fetching db/$sub/$cloud_name -> $src"
	rclone copyto "$(rpath "db/$sub/$cloud_name")" "$src"
fi
[ -f "$src" ] || die "no such file: $src"
[ "$(head -c5 "$src")" = "PGDMP" ] || die "$src is not a pg_dump custom-format archive"
log "restoring $src ($(stat -c %s "$src") bytes)"

# --- helpers ------------------------------------------------------------------
db_image() {
	if [ -n "${RESTORE_IMAGE:-}" ]; then printf '%s' "$RESTORE_IMAGE"; return; fi
	sed -n '/^  db_recipes:/,/^  [a-z_]*:/p' docker-compose.yml | grep -m1 -E '^\s*image:' | awk '{print $2}'
}
container_running() { docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -qx true; }
wait_ready() { # wait_ready CONTAINER
	local _i
	for _i in $(seq 1 60); do
		if docker exec "$1" pg_isready -q -U "$PGUSER" -d "$PGDB" 2>/dev/null; then return 0; fi
		sleep 1
	done
	die "$1 did not become ready in 60s"
}
q() { # q CONTAINER SQL -> single value, or "?" if the query fails (e.g. table missing)
	docker exec "$1" psql -qtAX -U "$PGUSER" -d "$PGDB" -c "$2" 2>/dev/null </dev/null || printf '?'
}
stats() { # stats CONTAINER -> tab-separated stat line
	printf '%s\t%s\t%s\t%s\t%s\t%s' \
		"$(q "$1" "select count(*) from pg_tables where schemaname='public'")" \
		"$(q "$1" "select count(*) from cookbook_recipe")" \
		"$(q "$1" "select count(*) from cookbook_food")" \
		"$(q "$1" "select count(*) from cookbook_ingredient")" \
		"$(q "$1" "select count(*) from auth_user")" \
		"$(q "$1" "select to_char(max(created_at),'YYYY-MM-DD') from cookbook_recipe")"
}
print_stats() { # print_stats LABEL CONTAINER [LABEL CONTAINER]
	{
		printf 'source\ttables\trecipes\tfoods\tingredients\tusers\tnewest_recipe\n'
		while [ $# -gt 0 ]; do printf '%s\t%s\n' "$1" "$(stats "$2")"; shift 2; done
	} | column -t -s "$(printf '\t')"
}
do_restore() { # do_restore CONTAINER
	local logf rc=0
	logf="$BACKUP_DIR/restore-$(basename "$src" .dump)-$(date +%Y%m%d-%H%M%S).log"
	mkdir -p "$BACKUP_DIR"
	docker exec -i "$1" pg_restore -U "$PGUSER" -d "$PGDB" --no-owner --no-privileges < "$src" \
		> "$logf" 2>&1 || rc=$?
	if [ "$rc" -ne 0 ]; then
		log "WARNING: pg_restore exited $rc; see $logf. Last lines:"
		tail -n 5 "$logf" | sed 's/^/    /'
	else
		log "pg_restore OK (log: $logf)"
	fi
	return "$rc"
}

# --- test mode: throwaway container ------------------------------------------
if [ "$mode" = test ]; then
	image=$(db_image)
	[ -n "$image" ] || die "could not determine db_recipes image (set RESTORE_IMAGE=...)"
	docker rm -f "$TEST_CONTAINER" >/dev/null 2>&1 || true
	log "starting throwaway $TEST_CONTAINER ($image, no network, no volumes)"
	docker run -d --name "$TEST_CONTAINER" --network none --memory 512m \
		-e POSTGRES_USER="$PGUSER" -e POSTGRES_PASSWORD=restoretest -e POSTGRES_DB="$PGDB" \
		"$image" > /dev/null
	wait_ready "$TEST_CONTAINER"
	restore_rc=0; do_restore "$TEST_CONTAINER" || restore_rc=$?
	echo
	if container_running "$DB_CONTAINER"; then
		print_stats "restored($TEST_CONTAINER)" "$TEST_CONTAINER" "live($DB_CONTAINER)" "$DB_CONTAINER"
	else
		print_stats "restored($TEST_CONTAINER)" "$TEST_CONTAINER"
	fi
	echo
	if [ "$rm_after" -eq 1 ]; then
		docker rm -f "$TEST_CONTAINER" > /dev/null
		log "removed $TEST_CONTAINER"
	else
		log "left $TEST_CONTAINER running for inspection:"
		echo "    docker exec -it $TEST_CONTAINER psql -U $PGUSER -d $PGDB"
		echo "    make restore-test-clean     # remove it"
	fi
	exit "$restore_rc"
fi

# --- live mode ----------------------------------------------------------------
container_running "$DB_CONTAINER" || die "$DB_CONTAINER is not running"
echo
echo "!!! LIVE RESTORE into $DB_CONTAINER ($PGDB) from $src"
echo "    web_recipes/nginx_recipes will be stopped, the current DB dumped to"
echo "    $BACKUP_DIR/pre-restore-*.dump, then DROPPED and recreated from the file."
echo
if [ "$confirmed" -ne 1 ]; then
	printf "Type 'restore' to continue: "
	read -r answer
	[ "$answer" = restore ] || die "aborted"
fi

log "stopping web_recipes nginx_recipes"
docker compose stop web_recipes nginx_recipes
safety="$BACKUP_DIR/pre-restore-$(date +%Y%m%d-%H%M%S).dump"
log "safety dump of current DB -> $safety"
docker exec -i "$DB_CONTAINER" pg_dump -U "$PGUSER" -d "$PGDB" -Fc > "$safety"
log "dropping and recreating $PGDB"
docker exec "$DB_CONTAINER" dropdb -U "$PGUSER" --force --if-exists "$PGDB"
docker exec "$DB_CONTAINER" createdb -U "$PGUSER" -O "$PGUSER" "$PGDB"
restore_rc=0; do_restore "$DB_CONTAINER" || restore_rc=$?
log "starting web_recipes nginx_recipes"
docker compose up -d web_recipes nginx_recipes
echo
print_stats "live($DB_CONTAINER)" "$DB_CONTAINER"
echo
log "if this is wrong, roll back with: $0 $safety --live"
exit "$restore_rc"
