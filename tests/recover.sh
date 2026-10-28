#!/usr/bin/env bash
# The data part of docs/backup-and-recovery.md as a rehearsal: back up, lose everything on the "server" (state dir, host files, shares),
# bring it back with the commands of the runbook (plain restic for the host files, hs backup restore for the shares) and compare.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
need_root
have restic || { skip "restic is not installed"; finish; exit $?; }
made_user=false
id adminuser >/dev/null 2>&1 || { useradd -M -s /usr/sbin/nologin adminuser && made_user=true; }

dev=$(mkloop backupdisk 300M)
export HS_STATE_DIR=$WORK/state HS_BACKUP_MOUNT=$WORK/mnt HS_BACKUP_DEV=$dev HS_BULK=$WORK/bulk
export HS_BACKUP_CACHE=$WORK/cache HS_BACKUP_HOST_FILES="$WORK/host/machine.nix $WORK/state" HS_RUN_DIR=$WORK/run HS_PLAIN=1
export HS_BACKUP_YES=1 HS_INCUS_ROOT=$WORK/incus
mkdir -p "$WORK/bulk/shares/docs" "$WORK/bulk/shares/media" "$WORK/bulk/sensitive/photos" "$WORK/host" "$WORK/state" "$WORK/safe"
for i in 1 2 3; do head -c 50000 /dev/urandom > "$WORK/bulk/shares/docs/d$i.bin"; done
head -c 80000 /dev/urandom > "$WORK/bulk/shares/media/m.bin"; head -c 70000 /dev/urandom > "$WORK/bulk/sensitive/photos/p.jpg"
echo 'hostName = "homeserver";' > "$WORK/host/machine.nix"
echo "api-key-123" > "$WORK/state/unifi"; chmod 600 "$WORK/state/unifi"
hsb() { bash "$SCRIPTS/backup.sh" "$@"; }
sums() { (cd "$WORK" && find bulk host state -type f ! -path 'state/backup*' ! -path 'state/*.state' ! -name '*.new' -print0 2>/dev/null | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16); }

echo "-- the backup"
hsb init "$dev" >/dev/null 2>&1
cp "$WORK/state/restic-password" "$WORK/safe/pw"      # "the password in your password manager"
hsb now >/dev/null 2>&1
check "a backup exists" bash -c "mount $dev $WORK/mnt && restic -r $WORK/mnt/restic --password-file $WORK/safe/pw snapshots --compact | grep -q host; r=\$?; umount $WORK/mnt; exit \$r"
for k in unifi restic-password; do cp "$WORK/state/$k" "$WORK/safe/$k.orig"; done
before=$(sums)

echo "-- the disaster: state, host files and shares are gone"
rm -rf "$WORK/state" "$WORK/host" "$WORK/secrets" "$WORK/bulk/shares" "$WORK/bulk/sensitive"
mkdir -p "$WORK/bulk"
check "nothing is left" test ! -e "$WORK/bulk/shares/docs/d1.bin"

echo "-- runbook step: host files with plain restic (no hs yet)"
mount "$dev" "$WORK/mnt"
restic -r "$WORK/mnt/restic" --password-file "$WORK/safe/pw" restore latest --tag host --target "$WORK/hostrestore" >/dev/null 2>&1
umount "$WORK/mnt"
check "machine.nix came back" test -s "$WORK/hostrestore$WORK/host/machine.nix"
check "the state directory came back" test -d "$WORK/hostrestore$WORK/state"
mkdir -p "$WORK/state" "$WORK/host"
cp -a "$WORK/hostrestore$WORK/state/." "$WORK/state/"
cp -a "$WORK/hostrestore$WORK/host/machine.nix" "$WORK/host/machine.nix"
check_eq "the UniFi key is back" "api-key-123" "$(cat "$WORK/state/unifi" 2>/dev/null)"
check_eq "and root-only" "600" "$(stat -c %a "$WORK/state/unifi" 2>/dev/null)"
# the password is NOT in the backup (it would be locked inside what it opens): it comes from your password manager
check "the backup does not hold its own password" test ! -e "$WORK/hostrestore$WORK/state/restic-password"
install -m 600 "$WORK/safe/pw" "$WORK/state/restic-password"
check_eq "the password is put back by hand" "$(cat "$WORK/safe/restic-password.orig")" "$(cat "$WORK/state/restic-password")"

echo "-- runbook step: shares with hs backup restore, in place (--to /)"
check "docs, media come back" hsb restore latest "$WORK/bulk/shares" --to /
check "sensitive comes back" hsb restore latest "$WORK/bulk/sensitive" --to /
check_eq "the files are identical to before the disaster" "$before" "$(sums)"
check_eq "owned by adminuser" "adminuser" "$(stat -c %U "$WORK/bulk/shares/docs/d1.bin")"

echo "-- the chown stays inside what was restored"
mkdir -p "$WORK/target"; touch "$WORK/target/sentinel"; chown nobody "$WORK/target/sentinel" 2>/dev/null
hsb restore latest "$WORK/bulk/shares/docs" --to "$WORK/target" >/dev/null 2>&1
check_eq "a file next to it keeps its owner" "nobody" "$(stat -c %U "$WORK/target/sentinel")"
check_eq "what was restored belongs to adminuser" "adminuser" "$(stat -c %U "$WORK/target$WORK/bulk/shares/docs/d1.bin")"

! $made_user || userdel adminuser 2>/dev/null
finish
