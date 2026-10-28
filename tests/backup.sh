#!/usr/bin/env bash
# hs backup on a loop device: init, nightly run, retention tags, restore, the disk stays hidden.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
need_root
have restic || { skip "restic is not installed"; finish; exit $?; }

dev=$(mkloop backupdisk 300M)
export HS_STATE_DIR=$WORK/state HS_BACKUP_MOUNT=$WORK/mnt HS_BACKUP_DEV=$dev HS_BULK=$WORK/bulk
export HS_BACKUP_CACHE=$WORK/cache HS_BACKUP_HOST_FILES="$WORK/host/machine.nix $WORK/state/backup-inventory $WORK/hostdir" HS_DISKS_ROOT=$WORK/hostdir/disks HS_RUN_DIR=$WORK/run HS_PLAIN=1
export HS_BACKUP_YES=1 HS_INCUS_ROOT=$WORK/incus
mkdir -p "$WORK/bulk/shares/docs" "$WORK/bulk/shares/restored" "$WORK/bulk/sensitive/pelican-backups" "$WORK/host"
echo "hello" > "$WORK/bulk/shares/docs/a.txt"; echo "game" > "$WORK/bulk/sensitive/pelican-backups/w.tar"
echo "machine" > "$WORK/host/machine.nix"
# the pool disks are mounted inside a host path (/var/lib/hs/disks): restic must not follow into them, or the host snapshot holds the whole array
mkdir -p "$WORK/hostdir/disks/data-01/shares/media"; echo "film" > "$WORK/hostdir/disks/data-01/shares/media/film.mkv"; echo "note" > "$WORK/hostdir/note.txt"
hsb() { bash "$SCRIPTS/backup.sh" "$@"; }
repo() { restic -r "$WORK/mnt/restic" --password-file "$WORK/state/restic-password" "$@"; }

echo "-- init"
check_out "init refuses a mounted device" "mounted" bash -c "mkdir -p $WORK/m2 && mount $dev $WORK/m2 2>/dev/null || mkfs.ext4 -q -F $dev && mount $dev $WORK/m2 && HS_BACKUP_YES=1 bash $SCRIPTS/backup.sh init $dev; umount $WORK/m2"
check "init formats and creates the repository" hsb init "$dev"
check_eq "the disk is labelled backup" backup "$(blkid -s LABEL -o value "$dev")"
check "password file is root-only" test "$(stat -c %a "$WORK/state/restic-password")" = 600
check "the disk is unmounted again" bash -c "! mountpoint -q $WORK/mnt"
check_out "pelican-backups and restored start off" "pelican-backups" cat "$WORK/state/backup-off"

echo "-- backup run"
check "backup now succeeds" hsb now
check "the disk is unmounted again after a run" bash -c "! mountpoint -q $WORK/mnt"
mount "$dev" "$WORK/mnt"
check_out "tags shares and host exist" "shares" repo snapshots --compact
check_out "docs is in the backup" "a.txt" repo ls --recursive latest --tag shares
check_out "machine.nix is in the host snapshot" "host/machine.nix" repo ls --recursive latest --tag host
check_out "a file of the host folder is in the host snapshot" "hostdir/note.txt" repo ls --recursive latest --tag host
out=$(repo ls --recursive latest --tag host 2>&1)
grep -q "film.mkv" <<<"$out" && fail "the pool disks are not in the host snapshot (film.mkv is)" || pass "the pool disks are not in the host snapshot"
mkdir -p "$WORK/keyrestore"
check "machine.nix restores" repo restore latest --tag host --target "$WORK/keyrestore" --include "$WORK/host/machine.nix"
check_eq "with its content" "machine" "$(cat "$WORK/keyrestore$WORK/host/machine.nix" 2>/dev/null)"
out=$(repo ls --recursive latest --tag shares 2>&1)
if grep -q "pelican-backups/w.tar" <<<"$out"; then fail "pelican-backups is left out"; else pass "pelican-backups is left out"; fi
umount "$WORK/mnt"

echo "-- switching a share off and on"
check "docs off" hsb docs off
check_out "docs is listed as left out" "left out" hsb status
check "docs on" hsb docs on
check_out "unknown share is refused" "No share" hsb nosuch off

echo "-- restore"
echo "changed" > "$WORK/bulk/shares/docs/a.txt"
check "restore into the restored share" hsb restore latest "$WORK/bulk/shares/docs" --to "$WORK/bulk/shares/restored"
check_eq "restored file has the old content" hello "$(cat "$WORK/bulk/shares/restored$WORK/bulk/shares/docs/a.txt" 2>/dev/null)"
check "the live copy is untouched" test "$(cat "$WORK/bulk/shares/docs/a.txt")" = changed
if hsb restore latest "$WORK/bulk/shares/nothing-here" --to "$WORK/bulk/shares/restored" >/dev/null 2>&1; then fail "restoring a path that is not in the backup fails"; else pass "restoring a path that is not in the backup fails"; fi

echo "-- drill"
check_out "the restore drill restores random files" "restored" hsb drill 2
check_out "status remembers the drill" "Restore drill +[0-9]+ min" hsb status

echo "-- size estimate"
printf '%s\t%s\n' "$WORK/bulk/shares/docs" 5000000 > "$WORK/state/share-sizes"
check_out "status shows the size of what is included" "about 4.8M" hsb status

echo "-- inventory and database dumps (fake incus)"
mkdir -p "$WORK/fakebin" "$WORK/incus/web/rootfs/etc" "$WORK/state/backup-dump"
cat > "$WORK/fakebin/incus" <<'FAKE'
#!/bin/sh
case "$1 $2" in
  "info web") exit 0 ;;
  "info "*) exit 1 ;;
  "exec web") shift 3; echo "$*" >> "$HS_FAKE_LOG"; exit 0 ;;
  "config show") echo "name: $4"; exit 0 ;;
esac
case "$1" in
  list) case "$*" in *csv*) echo web ;; *) echo '[{"name":"web"}]' ;; esac ;;
  profile) case "$2" in list) echo default ;; show) echo "profile: $3" ;; esac ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$WORK/fakebin/incus"
echo "pg_dumpall > /var/backups/db.sql" > "$WORK/state/backup-dump/web"
echo "conf" > "$WORK/incus/web/rootfs/etc/app.conf"
export HS_FAKE_LOG=$WORK/fake.log
PATH="$WORK/fakebin:$PATH" hsb ct web on >/dev/null 2>&1
check "backup now with a container and a dump hook" env PATH="$WORK/fakebin:$PATH" bash "$SCRIPTS/backup.sh" now
check_out "the dump command ran inside the container" "pg_dumpall" cat "$WORK/fake.log"
mount "$dev" "$WORK/mnt"
check_out "the container files are in the backup" "app.conf" repo ls --recursive latest --tag ct:web
check_out "the inventory is in the host backup" "backup-inventory/incus-instances.json" repo ls --recursive latest --tag host
umount "$WORK/mnt"

echo "-- off-site copy"
off=$WORK/offsite-repo
check "offsite set creates the second repository" hsb offsite set "$off"
check "offsite now copies" hsb offsite now
check_out "the second repository holds the snapshots" "shares" restic -r "$off" --password-file "$WORK/state/restic-password" snapshots --compact
check "the next nightly run copies as well" env PATH="$WORK/fakebin:$PATH" bash "$SCRIPTS/backup.sh" now
check_out "status shows the off-site copy" "Off-site copy" hsb status
hsb offsite off >/dev/null 2>&1
check "offsite off removes the setting" test ! -s "$WORK/state/backup-offsite"

echo "-- health"
export HS_BACKUP_STATE=$WORK/state/backup.state HS_HEALTH_STATE=$WORK/h.state
out=$(bash "$SCRIPTS/health-check.sh" --dry-run 2>&1 || true)
if grep -qi "backup" <<<"$out"; then fail "no backup problem after a good run"; else pass "no backup problem after a good run"; fi
sed -i 's/^last_ok=.*/last_ok=1/' "$WORK/state/backup.state"
check_out "an old backup is reported" "hours old" bash "$SCRIPTS/health-check.sh" --dry-run

echo "-- the backup disk never looks free"
list=$(HS_TEST_LOOP=1 bash "$SCRIPTS/manage-pool.sh" --list-disks 2>&1 || true)
if grep -q "ata-TEST_backupdisk" <<<"$list"; then fail "manage-pool does not offer the backup disk"; else pass "manage-pool does not offer the backup disk"; fi

finish
