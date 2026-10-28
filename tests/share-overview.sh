#!/usr/bin/env bash
# scripts/share-overview.sh (hs sys shares overview|mounts|history): every share with disks, backup and who mounts it.
# Fake manage-shares --list, backup --shares, incus and zfs: no root, no Samba, no Incus. Needs jq.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test HS_MNT_BULK=$WORK/bulk
if ! command -v jq >/dev/null 2>&1; then skip "jq is not installed: share-overview tests not run"; finish; exit $?; fi
mkdir -p "$WORK/bulk/data-01/shares/media" "$WORK/bulk/data-02/shares/media" "$WORK/bulk/data-01/sensitive/immich"
echo snapraid > "$WORK/bulk-type"; export HS_BULK_TYPE_FILE=$WORK/bulk-type

cat > "$WORK/manage-shares" <<'FAKE'
#!/usr/bin/env bash
printf 'media\tshares\t/bulk/shares/media\toff\t1200000000000\t08.10. 03:10\n'
printf 'immich\tsensitive\t/bulk/sensitive/immich\ton\t612000000000\t08.10. 03:10\n'
printf 'temp-usb\tother\t/mnt/temp/usb\t-\t-\t08.10. 03:10\n'
FAKE
cat > "$WORK/backup" <<'FAKE'
#!/usr/bin/env bash
printf 'share\tmedia\toff\nshare\timmich\ton\nalways\tx\ton\n'
FAKE
cat > "$WORK/incus" <<'FAKE'
#!/usr/bin/env bash
cat <<'JSON'
[
 {"name":"jellyfin","expanded_devices":{"root":{"type":"disk","path":"/","pool":"default"},
   "media":{"type":"disk","source":"/bulk/shares/media","path":"/media","readonly":"true"}}},
 {"name":"sonarr","expanded_devices":{"tv":{"type":"disk","source":"/bulk/shares/media/tv","path":"/data","readonly":"false"},
   "dl":{"type":"disk","source":"/bulk/shares/media/tv","path":"/dl"}}},
 {"name":"immich","expanded_devices":{"photos":{"type":"disk","source":"/bulk/sensitive/immich","path":"/mnt/immich"},
   "db":{"type":"disk","pool":"default","source":"immich-db","path":"/var/lib/postgresql"}}}
]
JSON
FAKE
cat > "$WORK/zfs" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "list -H -o name bulk/shares/media") echo bulk/shares/media ;;
  "list -H -t snapshot"*) printf 'bulk/shares/media@manual-1\tWed Oct  7 21:00 2026\t1M\nbulk/shares/media@auto-d-2026-10-08\tThu Oct  8 03:00 2026\t0B\n' ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$WORK/manage-shares" "$WORK/backup" "$WORK/incus" "$WORK/zfs"
export HS_MANAGE_SHARES=$WORK/manage-shares HS_BACKUP=$WORK/backup HS_INCUS=$WORK/incus HS_ZFS=$WORK/zfs
O="bash $SCRIPTS/share-overview.sh"

echo "-- the overview"
out=$($O)
check_eq "one line per share, nine fields" "3 9" "$(wc -l <<<"$out" | tr -d ' ') $(awk -F'\t' 'NR == 1 { print NF }' <<<"$out")"
check_eq "media: two disks, not in the backup, three mounts (the folder inside counts for the share)" $'media\tshares\t/bulk/shares/media\toff\t1200000000000\t08.10. 03:10\toff\tdata-01,data-02\tjellyfin(ro),sonarr(rw)' "$(grep '^media' <<<"$out")"
check_eq "immich: in the backup, one disk, one mount" $'immich\tsensitive\t/bulk/sensitive/immich\ton\t612000000000\t08.10. 03:10\ton\tdata-01\timmich(rw)' "$(grep '^immich' <<<"$out")"
check_eq "another folder is shown as it is" $'temp-usb\tother\t/mnt/temp/usb\t-\t-\t08.10. 03:10\t-\t-\t-' "$(grep '^temp-usb' <<<"$out")"

echo "-- mounts"
check_eq "who mounts media" $'jellyfin\tmedia\t/media\tro\t/bulk/shares/media\nsonarr\ttv\t/data\trw\t/bulk/shares/media/tv\nsonarr\tdl\t/dl\trw\t/bulk/shares/media/tv' "$($O mounts media)"
check_eq "nobody mounts a share nobody mounts" "" "$($O mounts temp-usb)"
check_eq "an unknown share is empty, not an error" "" "$($O mounts nope)"

echo "-- history: SnapRAID has none, ZFS has the snapshots"
check_eq "SnapRAID: the backup is the history" "" "$($O history media)"
echo zfs > "$WORK/bulk-type"
out=$($O history media)
check_eq "ZFS: two snapshots, the auto one marked" $'manual-1\tWed Oct  7 21:00 2026\tmanual\t1M\nauto-d-2026-10-08\tThu Oct  8 03:00 2026\tauto\t0B' "$out"
check_eq "ZFS: the disks column is the pool" "bulk" "$($O | grep '^media' | cut -f8)"
check_out "a missing name prints the usage" "usage: share-overview.sh mounts" bash "$SCRIPTS/share-overview.sh" mounts

echo "-- the registry rows"
check_out "hs sys shares overview runs it" "media	shares" env HS_CALLER=test bash "$SCRIPTS/lib/hs.sh" sys shares overview
check_out "hs sys shares mounts runs it" "jellyfin" env HS_CALLER=test bash "$SCRIPTS/lib/hs.sh" sys shares mounts media
finish
