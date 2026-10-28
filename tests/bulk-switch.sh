#!/usr/bin/env bash
# The disks of the array moved from /mnt/bulk/data-NN to /var/lib/hs/disks: bulk-mount.sh moves a RUNNING server's disks
# without remounting /bulk (mergerfs branches are swapped), and moves them back (a rollback). Real loop devices, mergerfs, mounts: needs root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
need_root
for t in mergerfs setfattr getfattr; do have "$t" || { skip "$t is not installed"; finish; exit $?; }; done
have mkfs.ext4 || { skip "mkfs.ext4 is not installed"; finish; exit $?; }
export HS_PLAIN=1 BULK_MINFREESPACE=1M HS_STATE_DIR=$WORK/state HS_BULK_CLOSED=$WORK/state/bulk-closed HS_DETACHED_DIR=$WORK/state/detached HS_RECOVER_DIR=$WORK/state/recovering
mkdir -p "$WORK/state"
made_user=false
id adminuser >/dev/null 2>&1 || { useradd -M -s /usr/sbin/nologin adminuser && made_user=true; }
if mountpoint -q /bulk 2>/dev/null; then skip "/bulk is mounted on this machine: not touching it"; finish; exit $?; fi
mkdir -p /var/lib/snapraid
old=/mnt/bulk new=/var/lib/hs/disks   # the real places: bulk-mount.sh knows exactly these two
for n in 91 92; do
  dev=$(mkloop "sw$n" 64M)
  mkfs.ext4 -q -F -L "bulk-data-$n" "$dev" || { skip "mkfs.ext4 does not work here"; finish; exit $?; }
done
mm() { bash "$SCRIPTS/bulk-mount.sh" 2>&1; }
br() { getfattr --only-values -n user.mergerfs.branches "$1/.mergerfs" 2>/dev/null; }
sum() { ( cd /bulk && find shares -type f -exec md5sum {} + | sort -k2 ); }

echo "-- the old layout (disks under /mnt/bulk)"
HS_DISKS_ROOT=$old HS_DETACHED_ROOT=$old mm >/dev/null
mountpoint -q $old/data-91 && mountpoint -q $old/data-92 && pass "disks mounted at the old place" || fail "old layout not mounted"
mkdir -p /bulk/shares/media
for i in 1 2 3 4; do head -c 3000000 /dev/urandom > "/bulk/shares/media/f$i.bin"; done
sum > "$WORK/before.md5"
case "$(br /bulk)" in *"$old/data-91"*"$old/data-92"*) pass "/bulk has the old branches" ;; *) fail "branches: $(br /bulk)" ;; esac
# a reader that holds a file open through the pool while the disks move
( exec 3< /bulk/shares/media/f1.bin; sleep 6; wc -c <&3 > "$WORK/reader.out" ) &
reader=$!
sleep 0.5

echo "-- the move (a running /bulk is not remounted)"
before_pid=$(pgrep -f "fsname=bulk," | head -n1 || true)
HS_DISKS_ROOT=$new HS_DETACHED_ROOT=$old mm >/dev/null
mountpoint -q "$new/data-91" && mountpoint -q "$new/data-92" && pass "disks are mounted at the new place" || fail "new place not mounted"
case "$(br /bulk)" in *"$old/data"*) fail "an old branch is left in /bulk: $(br /bulk)" ;; *"$new/data-91"*"$new/data-92"*) pass "/bulk has only the new branches" ;; *) fail "branches: $(br /bulk)" ;; esac
case "$(br /mnt/bulk/pool)" in *"$old/data"*) fail "an old branch is left in the pool view" ;; *) pass "the pool view too" ;; esac
[ "$(sum)" = "$(cat "$WORK/before.md5")" ] && pass "the same files with the same checksums, no duplicates" || fail "pool view differs"
echo hello > /bulk/shares/media/new.txt && [ "$(cat /bulk/shares/media/new.txt)" = hello ] && pass "writing works" || fail "write failed"
wait "$reader" 2>/dev/null; [ "$(cat "$WORK/reader.out" 2>/dev/null | tr -d ' ')" = 3000000 ] && pass "a file that was open during the move was read to the end" || fail "reader: $(cat "$WORK/reader.out" 2>/dev/null)"
mountpoint -q "$old/data-91" && fail "the old mount point is still mounted" || pass "the old mount points are let go"
grep -q "^data data-91 $new/data-91$" /var/lib/snapraid/snapraid.conf && pass "snapraid.conf names the new places" || fail "snapraid.conf: $(grep '^data' /var/lib/snapraid/snapraid.conf | tr '\n' ' ')"
HS_DISKS_ROOT=$new HS_DETACHED_ROOT=$old mm >/dev/null
[ "$(sum)" = "$(sed '/new.txt/d' <(sum))" ] || true
case "$(br /bulk)" in *"$new/data-91"*"$new/data-92"*) pass "a second run changes nothing" ;; *) fail "second run: $(br /bulk)" ;; esac

echo "-- and back (a rollback to the old scripts)"
HS_DISKS_ROOT=$old HS_DETACHED_ROOT=$old mm >/dev/null
mountpoint -q $old/data-91 && ! mountpoint -q "$new/data-91" && pass "the disks are back at the old place" || fail "not moved back"
case "$(br /bulk)" in *"$new/data"*) fail "a new branch is left: $(br /bulk)" ;; *"$old/data-91"*) pass "/bulk has the old branches again" ;; *) fail "branches: $(br /bulk)" ;; esac
sum | grep -q ' shares/media/new.txt$' && [ "$(sum | wc -l)" = 5 ] && pass "all five files, once each" || fail "files after the way back: $(sum | wc -l)"

for n in 91 92; do umount -l "$old/data-$n" "$new/data-$n" 2>/dev/null; rmdir "$old/data-$n" "$new/data-$n" 2>/dev/null; done
! $made_user || userdel adminuser 2>/dev/null
finish
