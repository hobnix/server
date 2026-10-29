#!/usr/bin/env bash
# snapraid layout: --fs when adding disks, and remove: the files move, the parity run is left to the next sync.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
need_root
for t in mergerfs snapraid; do have "$t" || { skip "$t is not installed"; finish; exit $?; }; done
alt=""
for f in xfs btrfs; do fs_works "$f" && { alt=$f; break; }; done
[ -n "$alt" ] || { skip "neither xfs nor btrfs is available: --fs is not checked with another filesystem"; alt=ext4; }
mkdir -p /etc/hs /var/lib/hs /var/lib/snapraid
have setfattr || { skip "setfattr (package attr) is not installed"; finish; exit $?; }
made_user=false
id adminuser >/dev/null 2>&1 || { useradd -M -s /usr/sbin/nologin adminuser && made_user=true; }
echo snapraid > /etc/hs/bulk-type
rm -f /var/lib/hs/removals /var/lib/snapraid/members /var/lib/snapraid/snapraid.content*   # a left-over content file of another test knows other disks (UUID change)
export BULK_MINFREESPACE=1M HS_TEST_LOOP=1 HS_PLAIN=1 HS_STATE_DIR=$WORK/state
pool() { bash "$SCRIPTS/manage-pool.sh" "$@"; }
fstype() { blkid -s TYPE -o value "$(blkid -L "$1" 2>/dev/null)" 2>/dev/null; }

mkloop d1 400M >/dev/null; mkloop d2 400M >/dev/null; mkloop p1 600M >/dev/null

echo "-- add disks with a chosen filesystem"
echo bulk | pool bulk --role data --fs $alt --disks ata-TEST_d1 >"$WORK/add1.log" 2>&1
echo bulk | pool bulk --role data --disks ata-TEST_d2 >"$WORK/add2.log" 2>&1
echo bulk | pool bulk --role parity --disks ata-TEST_p1 >"$WORK/add3.log" 2>&1
check_eq "--fs $alt gives a $alt disk" "$alt" "$(fstype bulk-data-01)"
check_eq "the default is ext4" ext4 "$(fstype bulk-data-02)"
check_out "the plan names the filesystem" "($alt)" cat "$WORK/add1.log"
check "both data disks are mounted" mountpoint -q /mnt/bulk/data-02
check "the parity disk is mounted" mountpoint -q /mnt/bulk/parity-1
check "the SnapRAID config exists" test -s /var/lib/snapraid/snapraid.conf
for l in add1 add2 add3; do echo "   --- $l"; tail -n 6 "$WORK/$l.log" | sed "s/^/   | /"; done
check "--fs rejects unknown names" bash -c "! bash $SCRIPTS/manage-pool.sh bulk --fs zfs --dry-run"

echo "-- convert: empty a disk, format it again"
mkdir -p /bulk/shares/media
echo movie > /bulk/shares/media/m.txt
echo only-on-2 > /mnt/bulk/data-02/shares/media/two.txt 2>/dev/null || { mkdir -p /mnt/bulk/data-02/shares/media; echo only-on-2 > /mnt/bulk/data-02/shares/media/two.txt; }
out=$(echo data-02 | pool bulk --convert data-02 --fs "$alt" 2>&1 || true)
echo "$out" | tail -n 10 | sed "s/^/   | /"
check_out "convert reports it" "data-02 is converted" echo "$out"
check_eq "the disk has the new filesystem" "$alt" "$(fstype bulk-data-02)"
check_eq "and keeps its label" "bulk-data-02" "$(blkid -s LABEL -o value "$(blkid -L bulk-data-02)")"
check "it is mounted again" mountpoint -q /mnt/bulk/data-02
check_eq "its file moved to the other disk and is intact" only-on-2 "$(cat /bulk/shares/media/two.txt 2>/dev/null)"
check_eq "the conversion is recorded for the next sync" data-02 "$(cat /var/lib/hs/removals 2>/dev/null)"
bash "$SCRIPTS/bulk-sync.sh" --no-mover >/dev/null 2>&1
check "the next sync forgets it" test ! -s /var/lib/hs/removals
check_out "a parity disk cannot be converted" "only data disks" pool bulk --convert parity-1 --dry-run

echo "-- convert changes the filesystem, each way"
for f in ext4 xfs btrfs; do
  fs_works "$f" || { skip "mkfs.$f is not available: convert to $f not checked"; continue; }
  cur=$(fstype bulk-data-02)
  [ "$cur" != "$f" ] || { other=ext4; [ "$f" != ext4 ] || other=$alt; [ "$other" != "$f" ] || continue; echo data-02 | pool bulk --convert data-02 --fs "$other" >/dev/null 2>&1 || true; }
  echo data-02 | pool bulk --convert data-02 --fs "$f" >"$WORK/conv-$f.log" 2>&1 || true
  check_eq "convert gives a $f disk" "$f" "$(fstype bulk-data-02)"
  check "and it is mounted" mountpoint -q /mnt/bulk/data-02
done

echo "-- convert --discard: the files of the disk are not moved"
mkdir -p /mnt/bulk/data-02/shares/media; echo gone > /mnt/bulk/data-02/shares/media/discarded.txt
before_fs=$(fstype bulk-data-02)
to=ext4; [ "$before_fs" != ext4 ] || to=$alt
[ "$to" != "$before_fs" ] || to=ext4
out=$(echo data-02 | pool bulk --convert data-02 --discard --fs "$to" 2>&1 || true)
check_out "discard reports the conversion" "data-02 is converted" echo "$out"
check_eq "the filesystem changed" "$to" "$(fstype bulk-data-02)"
check "the discarded file is gone" test ! -e /bulk/shares/media/discarded.txt
check_eq "the other files are untouched" only-on-2 "$(cat /bulk/shares/media/two.txt 2>/dev/null)"

echo "-- convert: a file that cannot be moved aborts and changes nothing, a retry then works"
have chattr || skip "chattr is not installed: the unmovable file is not checked"
if have chattr; then
  mkdir -p /mnt/bulk/data-02/shares/media
  : > /mnt/bulk/data-02/shares/media/.hidden-stuck
  chattr +i /mnt/bulk/data-02/shares/media/.hidden-stuck 2>/dev/null
  if lsattr /mnt/bulk/data-02/shares/media/.hidden-stuck 2>/dev/null | grep -q '^....i'; then
    fs_now=$(fstype bulk-data-02); uuid_now=$(blkid -s UUID -o value "$(blkid -L bulk-data-02)")
    want=ext4; [ "$fs_now" != ext4 ] || want=$alt
    out=$(echo data-02 | pool bulk --convert data-02 --fs "$want" 2>&1); rc=$?
    check_eq "it exits with an error" 1 "$rc"
    check_out "it names how many files are left" "1 left" echo "$out"
    check_out "it says hidden files count" "hidden files count" echo "$out"
    check_out "and that the disk is not changed" "is not changed" echo "$out"
    check_eq "the disk is the same filesystem" "$fs_now" "$(fstype bulk-data-02)"
    check_eq "and the same filesystem UUID" "$uuid_now" "$(blkid -s UUID -o value "$(blkid -L bulk-data-02)")"
    chattr -i /mnt/bulk/data-02/shares/media/.hidden-stuck
    rm -f /mnt/bulk/data-02/shares/media/.hidden-stuck /bulk/shares/media/.hidden-stuck
    # the branch is gone from /bulk now (the failed run took it out): the retry must still go through
    out=$(echo data-02 | pool bulk --convert data-02 --fs "$want" 2>&1 || true)
    check_out "the retry converts" "data-02 is converted" echo "$out"
    check_eq "the retry changed the filesystem" "$want" "$(fstype bulk-data-02)"
  else
    skip "this filesystem has no immutable flag: the unmovable file is not checked"
  fi
fi
bash "$SCRIPTS/bulk-sync.sh" --no-mover >/dev/null 2>&1

echo "-- remove: files move, no parity run"
mkdir -p /bulk/shares/docs
for i in 1 2 3 4 5 6; do echo "file-$i" > "/bulk/shares/docs/f$i.txt"; done
# put some files on disk 01 explicitly
mkdir -p /mnt/bulk/data-01/shares/docs; echo only-on-1 > /mnt/bulk/data-01/shares/docs/one.txt
rm -f /var/lib/hs/removals
out=$(echo data-01 | pool bulk --remove data-01 2>&1 || true)
echo "$out" | tail -n 12 | sed "s/^/   | /"
check_out "remove reports the move" "removed from /bulk" echo "$out"
check_out "and says when the parity follows" "next scheduled sync" echo "$out"
check_eq "the file of the removed disk is still there" only-on-1 "$(cat /bulk/shares/docs/one.txt 2>/dev/null)"
check_eq "the removal is recorded" data-01 "$(cat /var/lib/hs/removals 2>/dev/null)"
check_out "the config keeps the disk, pointing at an empty folder" "data data-01 /var/lib/hs/removed/data-01" cat /var/lib/snapraid/snapraid.conf
if mountpoint -q /mnt/bulk/data-01; then fail "the disk is unmounted"; else pass "the disk is unmounted"; fi

echo "-- the next sync drops it"
out=$(bash "$SCRIPTS/bulk-sync.sh" --no-mover 2>&1 || true)
check_out "the sync announces the removed disk" "Dropping the removed disk" echo "$out"
check_out "and finishes" "Parity is up to date" echo "$out"
check "the record is gone" test ! -s /var/lib/hs/removals
if grep -q 'data-01' /var/lib/snapraid/snapraid.conf; then fail "the config no longer lists it"; else pass "the config no longer lists it"; fi
check_eq "the file survived the sync" only-on-1 "$(cat /bulk/shares/docs/one.txt 2>/dev/null)"

rm -f /etc/hs/bulk-type /var/lib/hs/removals /var/lib/snapraid/snapraid.content*
! $made_user || userdel adminuser 2>/dev/null
finish
