#!/bin/bash
# One-time: create the rclone remote the cloud backup uses. Run this on a
# machine WITH a web browser (the Google sign-in opens in it), then copy the
# resulting config section to the Pi — the script prints the command.
#
#   gdrive-backup   Google Drive, scope=drive.file: the token can only see
#                   files rclone itself created, not the rest of your Drive.
#                   Backups land in the folder dockerhost-backups/ (plain
#                   files; nothing here is considered sensitive).
set -euo pipefail

DRIVE_REMOTE=${DRIVE_REMOTE:-gdrive-backup}
FOLDER=${BACKUP_FOLDER:-dockerhost-backups}

command -v rclone >/dev/null 2>&1 || { echo "rclone not installed (https://rclone.org/install/)"; exit 1; }

if rclone listremotes | grep -qx "$DRIVE_REMOTE:"; then
	echo "remote $DRIVE_REMOTE already exists; keeping it"
else
	echo "Creating $DRIVE_REMOTE (Google Drive, drive.file scope) — a browser window will open for sign-in..."
	rclone config create "$DRIVE_REMOTE" drive scope=drive.file
fi

echo "Round-trip test through $DRIVE_REMOTE:$FOLDER ..."
echo "ok $(date -Is)" | rclone rcat "$DRIVE_REMOTE:$FOLDER/.setup-check"
rclone cat "$DRIVE_REMOTE:$FOLDER/.setup-check"
rclone delete "$DRIVE_REMOTE:$FOLDER/.setup-check"
echo "OK: write/read/delete works."

cat <<MSG

Next: put the same remote on the Pi (run from this machine):

  rclone config show $DRIVE_REMOTE \\
    | ssh pi@dockerhost 'mkdir -p ~/.config/rclone && cat >> ~/.config/rclone/rclone.conf && chmod 600 ~/.config/rclone/rclone.conf'

Then on the Pi:  curl -fsSL https://rclone.org/install.sh | sudo bash   # not apt: bullseye ships rclone 1.53
                 cp env.d/backup.env.example env.d/backup.env           # RCLONE_REMOTE=$DRIVE_REMOTE:$FOLDER
                 make backup-cloud && make restore-test && make backup-install
MSG
