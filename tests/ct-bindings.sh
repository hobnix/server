#!/usr/bin/env bash
# scripts/ct-bindings.sh (hs sys ct bindings) and the two new fields of manage-ct.sh --list: the storage of an instance with pool,
# disks, size, backup, cache and who else mounts the folder. Fake incus, manage-ct --storage and backup --shares: no root, no Incus.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test HS_STATE_DIR=$WORK/state HS_MNT_BULK=$WORK/bulk
if ! command -v jq >/dev/null 2>&1; then skip "jq is not installed: ct-bindings tests not run"; finish; exit $?; fi
mkdir -p "$WORK/state" "$WORK/bulk/data-01/shares/media" "$WORK/bulk/data-02/shares/media" "$WORK/bulk/data-01/sensitive/immich"
printf '/bulk/shares/media\t1200000000000\n/bulk/sensitive/immich\t612000000000\n' > "$WORK/state/share-sizes"
echo snapraid > "$WORK/bulk-type"; export HS_BULK_TYPE_FILE=$WORK/bulk-type

cat > "$WORK/incus" <<'FAKE'
#!/usr/bin/env bash
cat <<'JSON'
[
 {"name":"jellyfin","type":"container","status":"Running","expanded_devices":{"root":{"type":"disk","path":"/","pool":"default"},
   "media":{"type":"disk","source":"/bulk/shares/media","path":"/media","readonly":"true"}}},
 {"name":"sonarr","type":"container","status":"Running","expanded_devices":{"root":{"type":"disk","path":"/","pool":"default"},
   "tv":{"type":"disk","source":"/bulk/shares/media","path":"/data","readonly":"false"}}},
 {"name":"immich","type":"container","status":"Running","expanded_devices":{"root":{"type":"disk","path":"/","pool":"default"},
   "photos":{"type":"disk","source":"/bulk/sensitive/immich","path":"/mnt/immich"},
   "db":{"type":"disk","pool":"default","source":"immich-db","path":"/var/lib/postgresql"}}}
]
JSON
FAKE
cat > "$WORK/manage-ct" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  jellyfin) printf 'media\tshares\t/bulk/shares/media\t/media\tread\toff\n' ;;
  immich)   printf 'photos\tsensitive\t/bulk/sensitive/immich\t/mnt/immich\twrite\toff\ndb\tfast\tvolume immich-db\t/var/lib/postgresql\twrite\t-\n' ;;
esac
FAKE
cat > "$WORK/backup" <<'FAKE'
#!/usr/bin/env bash
printf 'share\tmedia\toff\nshare\timmich\ton\nalways\tx\ton\n'
FAKE
chmod +x "$WORK/incus" "$WORK/manage-ct" "$WORK/backup"
export HS_INCUS=$WORK/incus HS_MANAGE_CT=$WORK/manage-ct HS_BACKUP=$WORK/backup
B="bash $SCRIPTS/ct-bindings.sh"

echo "-- a share bound read only, also used by another instance"
out=$($B jellyfin)
check_eq "one line, twelve fields" "1 12" "$(wc -l <<<"$out" | tr -d ' ') $(awk -F'\t' 'NR == 1 { print NF }' <<<"$out")"
check_eq "the whole line" $'media\tshares\tbulk\t/bulk/shares/media\t/media\tread\toff\toff\tmedia\t1200000000000\tdata-01,data-02\tsonarr(rw)' "$out"

echo "-- a sensitive folder and a fast volume"
out=$($B immich)
check_eq "the sensitive folder: in the backup, on data-01 only, nobody else mounts it" $'photos\tsensitive\tbulk\t/bulk/sensitive/immich\t/mnt/immich\twrite\toff\ton\timmich\t612000000000\tdata-01\t-' "$(grep '^photos' <<<"$out")"
check_eq "the volume: pool fast, nothing to say about backup, size or disks" $'db\tfast\tfast\tvolume immich-db\t/var/lib/postgresql\twrite\t-\t-\t-\t-\t-\t-' "$(grep '^db' <<<"$out")"

echo "-- an instance without storage, and a missing name"
check_eq "no output for an instance with no bindings" "" "$($B dc1)"
check_out "a missing name prints the usage and fails" "usage: ct-bindings.sh" bash "$SCRIPTS/ct-bindings.sh"

echo "-- ZFS layout: the disks column is the pool"
echo zfs > "$WORK/bulk-type"
check_out "on ZFS the folder is on the pool" $'\tbulk\tsonarr' $B jellyfin

echo "-- the registry row"
check_out "hs sys ct bindings runs it" "media	shares" env HS_CALLER=test bash "$SCRIPTS/lib/hs.sh" sys ct bindings jellyfin
finish
