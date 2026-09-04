#!/bin/bash
# Dump the recipes Postgres DB and, with --upload, ship it to cloud storage.
# Runbook: docs/backup-restore.md.
#
#   scripts/db-backup.sh            dump to backups/recipes-<ts>.dump and prune
#                                   old local dumps (what `make backup-db` runs)
#   scripts/db-backup.sh --upload   ...then rclone the dump to
#                                   $RCLONE_REMOTE/db/daily, keep the first
#                                   dump of each month in db/monthly, copy
#                                   mediafiles/ (and env.d/ if BACKUP_ENV=1),
#                                   prune the remote per
#                                   retention, and ping $BACKUP_HEALTHCHECK_URL
#                                   (what the nightly cloud-backup.timer runs)
#
# Dumps are pg_dump "custom" format (-Fc): compressed, restorable with
# pg_restore into any Postgres >= the dump's version, and convertible to plain
# SQL with `pg_restore -f -`. The dump is a consistent snapshot; nothing needs
# to be stopped. Config comes from env.d/backup.env and env.d/recipes.env.
set -euo pipefail

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO_ROOT"

upload=0
case "${1:-}" in
	--upload) upload=1 ;;
	'') ;;
	*) echo "usage: $0 [--upload]" >&2; exit 2 ;;
esac

log() { printf '%s db-backup: %s\n' "$(date '+%F %T')" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

# env_get FILE KEY DEFAULT — read KEY=value from a dotenv-style file without
# sourcing it (comments/blank lines fine; last definition wins).
env_get() {
	local v
	v=$(grep -E "^$2=" "$1" 2>/dev/null | tail -n1 | cut -d= -f2-) || true
	printf '%s' "${v:-$3}"
}

DB_CONTAINER=${DB_CONTAINER:-con_db_recipes}
BACKUP_DIR=${BACKUP_DIR:-backups}
BACKUP_ENV_FILE=${BACKUP_ENV_FILE:-env.d/backup.env}
PGUSER=$(env_get env.d/recipes.env POSTGRES_USER djangouser)
PGDB=$(env_get env.d/recipes.env POSTGRES_DB djangodb)
LOCAL_KEEP_DAYS=$(env_get "$BACKUP_ENV_FILE" BACKUP_LOCAL_KEEP_DAYS 7)
HC_URL=$(env_get "$BACKUP_ENV_FILE" BACKUP_HEALTHCHECK_URL '')

# Report the outcome to the (optional) healthcheck URL, whatever happens.
finish() {
	local rc=$?
	if [ -n "$HC_URL" ] && command -v curl >/dev/null 2>&1; then
		if [ "$rc" -eq 0 ]; then
			curl -fsS -m 10 --retry 3 -o /dev/null "$HC_URL" || true
		else
			curl -fsS -m 10 --retry 3 -o /dev/null "$HC_URL/fail" || true
		fi
	fi
	if [ "$rc" -eq 0 ]; then log "done"; else log "FAILED (exit $rc)"; fi
}
trap finish EXIT

# --- 1. dump -----------------------------------------------------------------
docker inspect -f '{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null | grep -qx true \
	|| die "container $DB_CONTAINER is not running"

ts=$(date +%Y%m%d-%H%M%S)
name="recipes-$ts.dump"
mkdir -p "$BACKUP_DIR"
part="$BACKUP_DIR/.$name.part"
log "dumping $PGDB from $DB_CONTAINER"
docker exec -i "$DB_CONTAINER" pg_dump -U "$PGUSER" -d "$PGDB" -Fc > "$part"
# A custom-format archive starts with the magic "PGDMP"; and pg_restore --list
# parses the whole table of contents, so together they catch a truncated dump.
[ "$(head -c5 "$part")" = "PGDMP" ] || die "dump is not a pg_dump custom-format archive"
docker exec -i "$DB_CONTAINER" pg_restore --list < "$part" > /dev/null \
	|| die "pg_restore --list rejected the dump"
mv "$part" "$BACKUP_DIR/$name"
size=$(stat -c %s "$BACKUP_DIR/$name")
log "wrote $BACKUP_DIR/$name ($size bytes)"

# --- 2. prune local -----------------------------------------------------------
find "$BACKUP_DIR" -maxdepth 1 -name 'recipes-*.dump' -type f -mtime +"$LOCAL_KEEP_DAYS" -print -delete \
	| sed 's/^/pruned local: /' || true

[ "$upload" -eq 1 ] || exit 0

# --- 3. upload ----------------------------------------------------------------
command -v rclone >/dev/null 2>&1 || die "rclone not installed (curl -fsSL https://rclone.org/install.sh | sudo bash)"
REMOTE=$(env_get "$BACKUP_ENV_FILE" RCLONE_REMOTE '')
[ -n "$REMOTE" ] || die "RCLONE_REMOTE not set in $BACKUP_ENV_FILE (copy env.d/backup.env.example)"
KEEP_DAYS=$(env_get "$BACKUP_ENV_FILE" BACKUP_KEEP_DAYS 30)
KEEP_MONTHLY_DAYS=$(env_get "$BACKUP_ENV_FILE" BACKUP_KEEP_MONTHLY_DAYS 400)
DO_MEDIA=$(env_get "$BACKUP_ENV_FILE" BACKUP_MEDIA 1)
DO_ENV=$(env_get "$BACKUP_ENV_FILE" BACKUP_ENV 0)

# rpath SUBPATH — join $REMOTE ("name:" or "name:dir") with a subpath.
rpath() {
	case "${REMOTE%/}" in
		*:) printf '%s%s' "${REMOTE%/}" "$1" ;;
		*)  printf '%s/%s' "${REMOTE%/}" "$1" ;;
	esac
}

log "uploading $name to $(rpath db/daily)"
rclone copyto "$BACKUP_DIR/$name" "$(rpath "db/daily/$name")"
# rclone already md5-checks Drive uploads; this catches a wrong path or a partial file.
rsize=$(rclone lsf --format s "$(rpath "db/daily/$name")")
[ "$rsize" = "$size" ] || die "remote size ($rsize) != local size ($size) for $name"
log "verified remote copy ($rsize bytes)"

# First dump of the month is also kept under db/monthly (server-side copy).
month=${ts:0:6}
if ! rclone lsf "$(rpath db/monthly)" 2>/dev/null | grep -q "^recipes-$month"; then
	log "keeping $name as this month's long-term copy"
	rclone copyto "$(rpath "db/daily/$name")" "$(rpath "db/monthly/$name")"
fi

# mediafiles: `copy`, not `sync`, so a missing/empty bind mount or a bad day
# can never delete images from the remote. Orphans are cheap; losses aren't.
if [ "$DO_MEDIA" = 1 ]; then
	if [ -d mediafiles ] && [ -n "$(ls -A mediafiles 2>/dev/null)" ]; then
		log "copying mediafiles/"
		rclone copy --transfers 4 mediafiles "$(rpath mediafiles)"
	else
		log "mediafiles/ missing or empty; skipping"
	fi
fi

if [ "$DO_ENV" = 1 ]; then
	log "copying env.d/ (contains secrets; BACKUP_ENV=1 opted in)"
	rclone copy env.d "$(rpath env.d)"
fi

# Prune only after a verified upload, so a broken run can't thin the remote.
log "pruning remote: daily > ${KEEP_DAYS}d, monthly > ${KEEP_MONTHLY_DAYS}d"
rclone delete --min-age "${KEEP_DAYS}d" "$(rpath db/daily)"
rclone delete --min-age "${KEEP_MONTHLY_DAYS}d" "$(rpath db/monthly)"
log "remote now holds $(rclone lsf "$(rpath db/daily)" | wc -l) daily, $(rclone lsf "$(rpath db/monthly)" | wc -l) monthly dumps"
