# Backup & restore runbook

Nightly off-site backup of the Tandoor recipes stack to **Google Drive** via
[rclone](https://rclone.org), with a restore drill that never touches the
live database. Backups are plain files (not encrypted): the recipe data
isn't considered sensitive, and plain files mean a restore needs nothing but
rclone — or even just the Drive web UI.

| What | Where on the remote | Retention |
| --- | --- | --- |
| Postgres dump (`pg_dump -Fc`, the whole `djangodb`) | `db/daily/recipes-<ts>.dump` | 30 days (`BACKUP_KEEP_DAYS`) |
| First dump of each month | `db/monthly/recipes-<ts>.dump` | 400 days (`BACKUP_KEEP_MONTHLY_DAYS`) |
| `mediafiles/` (recipe images) | `mediafiles/` | forever — append-only, never deleted |
| `env.d/` — **off by default** (`BACKUP_ENV=1` to opt in) | `env.d/` | latest copy |

- **Remote:** `gdrive-backup:dockerhost-backups` — an rclone Google Drive
  remote with `drive.file` scope, so its token can only see files rclone
  itself created, not the rest of your Drive. In the Drive UI it's the
  `dockerhost-backups` folder.
- **Schedule:** `cloud-backup.timer` runs `scripts/db-backup.sh --upload`
  at 03:30 daily (`Persistent=true`: runs on next boot if missed).
- **Local copy too:** every run also leaves the dump in `backups/` (7 days).
- **Config:** `env.d/backup.env` (copy from `backup.env.example`).
- **`env.d/` is not uploaded by default** because those files hold real
  secrets (Django `SECRET_KEY`, DB password, API tokens) and the remote is
  plain. They're quick to regenerate on a rebuild (see *B* below). Set
  `BACKUP_ENV=1` if you'd rather have them in Drive anyway.

## One-time setup

### 1. On your desktop (has a browser)

First you need your own Google OAuth client: rclone's built-in shared
`client_id` is being retired during 2026 and rclone prints a NOTICE on every
run until you stop using it. Follow
<https://rclone.org/drive/#making-your-own-client-id> (Google Cloud console →
enable the Drive API → OAuth consent screen, External, add yourself as a test
user → create an OAuth client of type **Desktop app** → *Publish app*, so the
refresh token doesn't expire after 7 days). Only the `drive.file` scope is
needed, which is non-sensitive, so no app verification is required. An
existing Desktop-app client from another rclone remote can be reused.

```sh
GDRIVE_CLIENT_ID=...apps.googleusercontent.com GDRIVE_CLIENT_SECRET=... \
  ./scripts/backup-setup-rclone.sh
```

Creates the `gdrive-backup` remote (opens Google sign-in) and does a
write/read/delete round trip in `dockerhost-backups/`. Safe to re-run; it
keeps an existing remote, or upgrades one that still uses the shared
client (re-opens sign-in). Note that `drive.file` access is per OAuth
client: after switching clients the remote no longer sees files uploaded
under the old one, so move or delete the old `dockerhost-backups` folder in
the Drive web UI first or you get two same-named folders.

Then push the config section to the Pi (the script prints this too; the
Pi's `rclone.conf` holds only this remote, so overwrite it):

```sh
rclone config show gdrive-backup \
  | ssh pi@dockerhost 'mkdir -p ~/.config/rclone && cat > ~/.config/rclone/rclone.conf && chmod 600 ~/.config/rclone/rclone.conf'
```

Keeping the same remote on the desktop means you can list and restore
backups from there too (`scripts/db-restore.sh --list`), which is exactly what
you'd do if the Pi were dead.

### 2. On the Pi

```sh
curl -fsSL https://rclone.org/install.sh | sudo bash   # current static build; bullseye's apt rclone (1.53, 2020) is too old
cp env.d/backup.env.example env.d/backup.env    # defaults are fine
rclone lsd gdrive-backup:                       # should list dockerhost-backups
make backup-cloud                               # first real backup
make restore-test                               # prove it restores (see below)
make restore-test-clean
make backup-install                             # enable the nightly timer (sudo)
```

Optional: create a check at [healthchecks.io](https://healthchecks.io) with a
daily period and put its ping URL in `BACKUP_HEALTHCHECK_URL`. You'll then be
emailed when a night's backup fails *or doesn't run at all* — the failure mode
that otherwise goes unnoticed for months.

## Day to day

```sh
make backup-status   # next timer run + last run's log
make backup-list     # dumps on the remote (daily + monthly)
make backup-cloud    # run a backup right now (e.g. before an upgrade)
make backup-db       # local-only dump into backups/ (no upload)
```

The remote is never pruned unless the new upload was verified (size match),
so a broken run can't thin out your history.

## Restore drill (safe; run monthly or after any change here)

```sh
make restore-test              # newest cloud dump
make restore-test N=recipes-20260801-033000.dump   # a specific one
make restore-test F=backups/recipes-20260829-033000.dump   # a local file
```

This fetches the dump, starts a **throwaway** Postgres container
`con_db_restoretest` (same image as `db_recipes`, no network, no volumes —
it cannot reach the live DB or its data dir), restores into it, and prints
row counts next to the live DB's for comparison:

```
source                        tables  recipes  foods  ingredients  users  newest_recipe
restored(con_db_restoretest)  87      412      930    5120         2      2026-08-28
live(con_db_recipes)          87      414      932    5140         2      2026-08-29
```

Counts equal or slightly behind live (last night's snapshot) = a good backup.
The container is left running so you can poke at it
(`docker exec -it con_db_restoretest psql -U djangouser -d djangodb`); remove
it with `make restore-test-clean`. Add `--rm` to the script to auto-remove.

This works on the desktop as well (needs Docker + the rclone remote); the
live column is simply omitted.

## Real restore

### A. Roll the live DB back to a snapshot (bad edit, botched upgrade)

```sh
make backup-list                                          # pick a dump
./scripts/db-restore.sh --from-cloud recipes-<ts>.dump --live
# or a local one:  ./scripts/db-restore.sh backups/recipes-<ts>.dump --live
```

`--live` asks you to type `restore`, then: stops `web_recipes`
→ dumps the *current* DB to `backups/pre-restore-<ts>.dump` (your undo) →
`dropdb` + `createdb` → `pg_restore` → starts the web containers → prints
the counts. To undo: `./scripts/db-restore.sh backups/pre-restore-<ts>.dump --live`.

If the restore is to a snapshot from before a Tandoor upgrade, also roll the
`web_recipes` image back to the matching version (the `# image: ...` line
above it in `docker-compose.yml`) before bringing it up, or run its
migrations forward again with `make up`.

### B. Rebuild from nothing (dead Pi / SD card)

1. Provision the host (`README.md` → *Setup on the Pi*, `scripts/setup.sh`),
   clone this repo, `curl -fsSL https://rclone.org/install.sh | sudo bash`.
2. Put the `gdrive-backup` remote on the new host — copy it from the desktop
   as in setup step 1. (If the desktop is gone too: `rclone config create
   gdrive-backup drive scope=drive.file client_id=... client_secret=...
   config_is_local=false` and paste the token from
   `rclone authorize "drive" '{"scope":"drive.file","client_id":"...","client_secret":"..."}'`
   run on any machine with a browser. The client ID/secret are in the Google
   Cloud console under *APIs & Services → Credentials*; the **same** client
   must be used, since `drive.file` only sees files that client uploaded.)
   Check with `rclone lsl gdrive-backup:dockerhost-backups/db/daily`.
3. Recreate the env files: `cp env.d/*.env.example` → fill in
   `recipes.env` (new `SECRET_KEY`, any `POSTGRES_PASSWORD`),
   `speedtest.env` (new `APP_KEY`), `backup.env`. Existing Tandoor logins
   keep working — password hashes live in the DB, not in `SECRET_KEY`;
   only active sessions are invalidated. If `BACKUP_ENV=1` was on, just
   `rclone copy gdrive-backup:dockerhost-backups/env.d env.d` instead.
4. Restore media, start the DB, restore into it:
   ```sh
   rclone copy gdrive-backup:dockerhost-backups/mediafiles mediafiles
   make up                                   # fresh, empty djangodb gets created
   ./scripts/db-restore.sh --from-cloud --live
   ```
5. Check `http://recipes.local` — recipes, images, logins. Then
   `make backup-install` so the new host backs itself up.

### C. Inspect a dump without restoring it

```sh
docker run --rm -i postgres:16.8-alpine pg_restore --list < backups/recipes-<ts>.dump   # table of contents
docker run --rm -i postgres:16.8-alpine pg_restore -f - < backups/recipes-<ts>.dump > dump.sql  # plain SQL
```

Or download it straight from the Drive UI (`dockerhost-backups/db/daily/`)
and run `make restore-test F=<file>`.

## Why these choices

- **Google Drive** over Dropbox/iCloud: all three would need rclone; Drive
  and Dropbox both have mature, headless-friendly rclone backends, but
  Drive's `drive.file` scope gives least-privilege with no extra setup, you
  already had an rclone Drive remote on the desktop, and iCloud's rclone
  backend needs an interactive 2FA session that doesn't suit a cron job.
- **No encryption:** recipes aren't sensitive; skipping it removes a secret
  that could be lost and lets you restore from the Drive UI alone. The
  consequence is that `env.d/` (real secrets) stays out of the backup by
  default. If that ever changes, rclone's `crypt` backend wraps this remote
  transparently — only `RCLONE_REMOTE` would change.
- **`pg_dump -Fc`** over `pg_dumpall` SQL: compressed, `pg_restore` handles
  ordering and `--no-owner`, and it restores cleanly into the fresh DB the
  Postgres image creates — no `pg_extract.sh` slicing (that script and
  `docs/db-migration.md` remain for major-version upgrades).
- **`rclone copy` for media, not `sync`:** an empty or unmounted
  `mediafiles/` on a bad night must never delete images from the backup.
