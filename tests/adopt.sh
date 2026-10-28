#!/usr/bin/env bash
# hs pool bulk add --role adopt: disks that already hold files keep them (ext4, xfs, btrfs).
set -uo pipefail
. "$(dirname "$0")/lib.sh"
need_root
mkdir -p /etc/hs
echo snapraid > /etc/hs/bulk-type
export HS_TEST_LOOP=1 HS_ADOPT_SKIP_MERGE=1 HS_PLAIN=1 HS_STATE_DIR=$WORK/state
pool() { bash "$SCRIPTS/manage-pool.sh" "$@"; }

# a disk the way Unraid leaves it: share folders in the root, a hidden folder, a loose file
make_disk() {   # make_disk <name> <fs>
  local dev m="$WORK/m-$1"
  dev=$(mkloop "$1" 300M)
  case "$2" in xfs) mkfs.xfs -q -f "$dev" ;; btrfs) mkfs.btrfs -q -f "$dev" ;; *) mkfs.ext4 -q -F "$dev" ;; esac >/dev/null 2>&1
  mkdir -p "$m"; mount "$dev" "$m"
  mkdir -p "$m/Media/Movies" "$m/Backups" "$m/.Recycle.Bin"
  echo "film-$1" > "$m/Media/Movies/a.mkv"; echo "bk-$1" > "$m/Backups/b.zip"
  echo trash > "$m/.Recycle.Bin/r"; echo loose > "$m/loosefile"
  umount "$m"
}

next=0
for fs in ext4 xfs btrfs; do
  echo "-- $fs"
  if ! fs_works "$fs"; then skip "$fs is not available on this machine"; continue; fi
  next=$((next + 1)); name="$fs$next"
  make_disk "$name" "$fs"
  mp="/mnt/bulk/data-$(printf '%02d' "$next")"
  rm -rf "/mnt/bulk/data-0$next" 2>/dev/null
  out=$(pool bulk --role adopt --disks "ata-TEST_$name" --dry-run 2>&1 || true)
  check_out "$fs: the dry run lists the folders" "Media" echo "$out"
  dev=$(readlink -f "/dev/disk/by-id/ata-TEST_$name")
  case "$(blkid -s LABEL -o value "$dev" 2>/dev/null)" in bulk-*) fail "$fs: the dry run changes nothing" ;; *) pass "$fs: the dry run changes nothing" ;; esac
  echo bulk | pool bulk --role adopt --disks "ata-TEST_$name" >"$WORK/adopt-$name.log" 2>&1
  check "$fs: adopting succeeds" test -d "$mp/shares"
  label=$(blkid -s LABEL -o value "$(findmnt -no SOURCE "$mp" 2>/dev/null)" 2>/dev/null)
  check_eq "$fs: the label is bulk-data-$(printf '%02d' "$next")" "bulk-data-$(printf '%02d' "$next")" "$label"
  media=$(find "$mp/shares" -maxdepth 1 -name '*media*' -o -maxdepth 1 -name 'Media' | head -1)
  check_eq "$fs: the file is intact in its share" "film-$name" "$(cat "$media/Movies/a.mkv" 2>/dev/null)"
  check "$fs: the hidden folder stays" test -f "$mp/.Recycle.Bin/r"
  check "$fs: the loose file stays" test -f "$mp/loosefile"
  check "$fs: nothing is left of Media in the root" test ! -e "$mp/Media"
done

echo "-- the disk with a dirty or foreign filesystem is refused, not changed"
dev=$(mkloop ntfsish 100M)
printf 'NTFS    ' | dd of="$dev" bs=1 seek=3 conv=notrunc 2>/dev/null
out=$(pool bulk --role adopt --disks ata-TEST_ntfsish --dry-run 2>&1 || true)
if grep -qiE "expected exactly one|temp-disk|not a free" <<<"$out"; then pass "an unsupported disk is refused"; else fail "an unsupported disk is refused ($out)"; fi

rm -f /etc/hs/bulk-type
finish
