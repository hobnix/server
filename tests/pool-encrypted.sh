#!/usr/bin/env bash
# snapraid layout with real LUKS: convert a plain data disk to an encrypted one, and replace a disk by an
# encrypted one (rebuilt from parity). Needs dm-crypt, mergerfs, snapraid: CI has them, most sandboxes do not.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
need_root
dm_works || { skip "device-mapper / dm-crypt is not available on this machine"; finish; exit $?; }
for t in mergerfs snapraid setfattr; do have "$t" || { skip "$t is not installed"; finish; exit $?; }; done
mkdir -p /etc/hs /var/lib/hs /var/lib/snapraid "$WORK/state" "$WORK/run"
made_user=false
id adminuser >/dev/null 2>&1 || { useradd -M -s /usr/sbin/nologin adminuser && made_user=true; }
echo snapraid > /etc/hs/bulk-type
rm -f /var/lib/hs/removals /var/lib/snapraid/members /var/lib/snapraid/snapraid.content*   # a left-over content file of another test knows other disks (UUID change)
PW=sharedpass
export BULK_MINFREESPACE=1M HS_TEST_LOOP=1 HS_PLAIN=1 HS_STATE_DIR=$WORK/state HS_RUN_DIR=$WORK/run HS_DISK_PASSPHRASE=$PW
pool() { bash "$SCRIPTS/manage-pool.sh" "$@"; }
mapper_of() { echo "/dev/mapper/hs-$(cryptsetup luksUUID "$1" | tr -d - | cut -c1-12)"; }
disk_of() { readlink -f "/dev/disk/by-id/ata-TEST_$1"; }
docs_sum() { (cd /bulk/shares/docs 2>/dev/null && sha256sum -- * | sort | sha256sum | cut -c1-16); }

mkloop d1 400M >/dev/null; mkloop d2 400M >/dev/null; mkloop p1 600M >/dev/null; mkloop n1 400M >/dev/null
echo bulk | pool bulk --role data --disks ata-TEST_d1 >/dev/null 2>&1
echo bulk | pool bulk --role data --disks ata-TEST_d2 >/dev/null 2>&1
echo bulk | pool bulk --role parity --disks ata-TEST_p1 >/dev/null 2>&1
check "the plain pool is up" mountpoint -q /mnt/bulk/data-02
mkdir -p /bulk/shares/docs
for i in 1 2 3 4 5 6 7 8; do head -c 300000 /dev/urandom > "/bulk/shares/docs/f$i.bin"; done
mkdir -p /mnt/bulk/data-01/shares/docs; head -c 200000 /dev/urandom > /mnt/bulk/data-01/shares/docs/only-on-1.bin
before=$(docs_sum)
sync_() { bash "$SCRIPTS/bulk-sync.sh" --no-mover >"$WORK/sync.log" 2>&1; local rc=$?; [ "$rc" -eq 0 ] || { echo "   sync failed ($rc):"; tail -n 12 "$WORK/sync.log" | sed 's/^/   | /'; }; return $rc; }
sync_
check "a first sync wrote the parity" test -s /mnt/bulk/parity-1/snapraid.parity

echo "-- convert a plain disk to an encrypted one"
out=$(echo data-01 | pool bulk --convert data-01 --encrypt 2>&1 || true)
echo "$out" | tail -n 8 | sed 's/^/   | /'
check_out "convert reports it" "data-01 is converted" echo "$out"
d1=$(disk_of d1)
check "the disk is LUKS now" test "$(blkid -p -o value -s TYPE "$d1")" = crypto_LUKS
check_out "the label is inside the encryption" "^bulk-data-01$" blkid -s LABEL -o value "$(mapper_of "$d1")"
check "it is mounted through the mapper" bash -c "findmnt -rn -S '$(mapper_of "$d1")' -o TARGET | grep -q /mnt/bulk/data-01"
check_eq "the disk is recorded as ours" 1 "$(wc -l < "$WORK/state/luks-uuids" 2>/dev/null | tr -d ' ')"
check_eq "all files are intact" "$before" "$(docs_sum)"
check_eq "also the one that was on the converted disk" "yes" "$(test -s /bulk/shares/docs/only-on-1.bin && echo yes)"
sync_
check "the next sync forgot the conversion" test ! -s /var/lib/hs/removals

echo "-- replace a disk by an encrypted one (rebuilt from parity)"
sync_
out=$(echo data-02 | pool bulk --replace data-02 --disks ata-TEST_n1 --encrypt 2>&1 || true)
echo "$out" | tail -n 8 | sed 's/^/   | /'
check_out "replace reports it" "data-02 is replaced" echo "$out"
n1=$(disk_of n1)
check "the new disk is LUKS" test "$(blkid -p -o value -s TYPE "$n1")" = crypto_LUKS
check "it is mounted as data-02" bash -c "findmnt -rn -S '$(mapper_of "$n1")' -o TARGET | grep -q /mnt/bulk/data-02"
check_eq "the files are back" "$before" "$(docs_sum)"
check_eq "both encrypted disks are recorded" 2 "$(wc -l < "$WORK/state/luks-uuids" 2>/dev/null | tr -d ' ')"
check_out "the old disk is free again (no pool label)" "^$" bash -c "blkid -s LABEL -o value $(disk_of d2) || echo"

rm -f /etc/hs/bulk-type /var/lib/hs/removals /var/lib/snapraid/snapraid.content*
! $made_user || userdel adminuser 2>/dev/null
finish
