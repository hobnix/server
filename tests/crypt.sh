#!/usr/bin/env bash
# Encrypted storage with real LUKS: hs unlock, the boot path, adopting LUKS disks, --encrypt.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
need_root
dm_works || { skip "device-mapper / dm-crypt is not available on this machine"; finish; exit $?; }

mkdir -p /etc/hs; echo snapraid > /etc/hs/bulk-type
export HS_PLAIN=1 HS_STATE_DIR=$WORK/state HS_RUN_DIR=$WORK/run HS_TEST_LOOP=1 HS_ADOPT_SKIP_MERGE=1
mkdir -p "$WORK/state" "$WORK/run"
PW=sharedpass
unlock() { bash "$SCRIPTS/unlock.sh" "$@"; }
pool() { bash "$SCRIPTS/manage-pool.sh" "$@"; }
luks_uuid() { cryptsetup luksUUID "$1"; }
mapper_of() { echo "/dev/mapper/hs-$(luks_uuid "$1" | tr -d - | cut -c1-12)"; }

# an Unraid-like encrypted disk: LUKS, ext4 inside with a share folder
make_luks() {   # make_luks <name> <passphrase>
  local dev m="$WORK/m-$1"
  dev=$(mkloop "$1" 100M)
  printf %s "$2" | cryptsetup luksFormat --batch-mode --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file - "$dev" >/dev/null 2>&1
  printf %s "$2" | cryptsetup open --key-file - "$dev" "tmp-$1" >/dev/null 2>&1
  mkfs.ext4 -q -F "/dev/mapper/tmp-$1"
  mkdir -p "$m"; mount "/dev/mapper/tmp-$1" "$m"
  mkdir -p "$m/Media"; echo "data-$1" > "$m/Media/$1.txt"
  umount "$m"; cryptsetup close "tmp-$1"
}
make_luks e1 "$PW"; make_luks e2 "$PW"; make_luks foreign otherpass
d1=$(readlink -f /dev/disk/by-id/ata-TEST_e1); d2=$(readlink -f /dev/disk/by-id/ata-TEST_e2); df=$(readlink -f /dev/disk/by-id/ata-TEST_foreign)

echo "-- hs unlock"
check_out "status shows closed disks" "LOCKED" unlock --status
export HS_DISK_PASSPHRASE=$PW
check "unlock opens the disks the passphrase fits" unlock
check "e1 is open" test -e "$(mapper_of "$d1")"
check "e2 is open" test -e "$(mapper_of "$d2")"
check "the foreign disk stays closed" test ! -e "$(mapper_of "$df")"
check_eq "only our two disks are recorded" 2 "$(wc -l < "$WORK/state/luks-uuids")"
for d in "$d1" "$d2"; do cryptsetup close "$(basename "$(mapper_of "$d")")"; done
HS_DISK_PASSPHRASE=nope check_out "a wrong passphrase opens nothing" "opens nothing|did not accept" unlock
unset HS_DISK_PASSPHRASE
check "the passphrase can come on standard input (tools that unlock over SSH)" bash -c "printf '%s\n' '$PW' | bash $SCRIPTS/unlock.sh --passphrase-stdin >/dev/null 2>&1; test -e $(mapper_of "$d1") && test -e $(mapper_of "$d2")"

echo "-- a disk this server does not know (an old system disk, somebody else's disk with the same passphrase)"
make_luks e3 "$PW"; d3=$(readlink -f /dev/disk/by-id/ata-TEST_e3)
for d in "$d1" "$d2"; do cryptsetup close "$(basename "$(mapper_of "$d")")"; done
export HS_DISK_PASSPHRASE=$PW
out=$(unlock 2>&1 || true)
check "the known disks open" bash -c "test -e $(mapper_of "$d1") && test -e $(mapper_of "$d2")"
check "the unknown disk stays closed" test ! -e "$(mapper_of "$d3")"
check_out "and the output says so" "Not opened" echo "$out"
check_eq "and it is not recorded" 2 "$(wc -l < "$WORK/state/luks-uuids")"
check "unlock --all opens it" bash -c "bash $SCRIPTS/unlock.sh --all >/dev/null 2>&1; test -e $(mapper_of "$d3")"
check_eq "and records it" 3 "$(wc -l < "$WORK/state/luks-uuids")"
cryptsetup close "$(basename "$(mapper_of "$d3")")"; sed -i "/$(cryptsetup luksUUID "$d3")/d" "$WORK/state/luks-uuids"
unset HS_DISK_PASSPHRASE

echo "-- the boot"
for d in "$d1" "$d2"; do cryptsetup close "$(basename "$(mapper_of "$d")")"; done
check "boot without a key file leaves the storage locked" bash -c "bash $SCRIPTS/unlock.sh --boot >/dev/null 2>&1; test -e $WORK/run/storage-locked"
check_out "the health check reports it" "locked" bash -c "HS_BACKUP_STATE=/nonexistent HS_HEALTH_STATE=$WORK/h bash $SCRIPTS/health-check.sh --dry-run"
printf '%s\n' "$PW" | unlock --setup-key >/dev/null 2>&1
check "the key file is root-only" test "$(stat -c %a "$WORK/state/disk-key" 2>/dev/null)" = 400
check "boot with the key file unlocks by itself" bash -c "bash $SCRIPTS/unlock.sh --boot >/dev/null 2>&1; test ! -e $WORK/run/storage-locked && test -e $(mapper_of "$d1")"
unlock --remove-key >/dev/null 2>&1

echo "-- adopting the encrypted disks"
for d in "$d1" "$d2"; do cryptsetup close "$(basename "$(mapper_of "$d")")" 2>/dev/null; done
rm -f "$WORK/state/luks-uuids"
export HS_DISK_PASSPHRASE=$PW
out=$(pool bulk --role adopt --disks ata-TEST_e1,ata-TEST_e2 --dry-run 2>&1 || true)
check_out "the dry run unlocks and looks inside" "encrypted" echo "$out"
echo bulk | pool bulk --role adopt --disks ata-TEST_e1,ata-TEST_e2 >"$WORK/adopt.log" 2>&1
check_eq "both disks are recorded as ours" 2 "$(wc -l < "$WORK/state/luks-uuids" 2>/dev/null || echo 0)"
mp1=$(findmnt -rn -S "$(mapper_of "$d1")" -o TARGET 2>/dev/null | head -1)
if [ -z "$mp1" ]; then fail "the adopted disk is mounted"; sed 's/^/        adopt.log: /' "$WORK/adopt.log" | tail -15; else pass "the adopted disk is mounted ($mp1)"; fi
check_out "the label is written inside the encryption" "^bulk-data-[0-9]+$" blkid -s LABEL -o value "$(mapper_of "$d1")"
check "the disk itself is still LUKS" test "$(blkid -p -o value -s TYPE "$d1")" = crypto_LUKS
check "the folder moved into shares/" bash -c "ls '$mp1/shares' | grep -qi media"
list=$(pool --list-disks 2>&1 || true)
if grep -q "ata-TEST_e1" <<<"$list"; then fail "an encrypted disk is not offered for wiping"; else pass "an encrypted disk is not offered for wiping"; fi
unset HS_DISK_PASSPHRASE

echo "-- --encrypt on a new disk"
mkloop fresh 100M >/dev/null
export HS_DISK_PASSPHRASE=$PW BULK_MINFREESPACE=1M
if have mergerfs && have snapraid; then
  echo bulk | pool bulk --role data --encrypt --disks ata-TEST_fresh >"$WORK/enc.log" 2>&1
  fresh=$(readlink -f /dev/disk/by-id/ata-TEST_fresh)
  check "the new disk is LUKS" test "$(blkid -p -o value -s TYPE "$fresh")" = crypto_LUKS
  check_eq "three disks are recorded now" 3 "$(wc -l < "$WORK/state/luks-uuids" 2>/dev/null || echo 0)"
  wrong=$(HS_DISK_PASSPHRASE=nope bash -c "echo bulk | bash $SCRIPTS/manage-pool.sh bulk --role data --encrypt --disks ata-TEST_fresh 2>&1" | tail -1)
  check_out "a wrong passphrase stops before anything is wiped" "." echo "$wrong"
else
  skip "mergerfs/snapraid missing: --encrypt on a new disk"
fi

rm -f /etc/hs/bulk-type
finish
