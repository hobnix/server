#!/usr/bin/env bash
# Regenerates the REAL outputs of scripts/fm.sh (test mode: folders stand in for the disks, as in tests/fm.sh) that tests/web-files-contract.mjs feeds
# through web/src/files/api.js. Run it when fm.sh changes its output:   bash tests/fixtures/fm/capture.sh
# Needs bash, flock, coreutils (WSL Debian or Linux). Writes <name>.out (stdout+stderr) and <name>.rc here. Nothing is written by hand.
set -u
here=$(cd "$(dirname "$0")" && pwd)
SCRIPTS=$(cd "$here/../../../scripts" && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
export HS_PLAIN=1 HS_LANG=en HS_CALLER=ui
B=$W/base
export HS_FM_TEST=1 HS_FM_SYNC=1 HS_FM_MARGIN=0 HS_FM_NO_RENAME=1 HS_STATE_DIR=$W/state HS_FM_DIR=$W/state/fm HS_DISKS_ROOT=$B/disks HS_DETACHED_ROOT=$B/detached \
  HS_FM_POOL_ROOT=$B/pool HS_FM_CACHE_ROOT=$B/cache HS_FM_TEMP_ROOT=$B/temp HS_FM_FAST_ROOT=$B/fast HS_BULK_TYPE_FILE=$W/bulk-type \
  HS_LOCK=$W/lock HS_LOCK_ADMIN=$W/admin HS_BULK_CLOSED=$W/state/bulk-closed HS_CAPABILITIES_FILE=$W/caps HS_LOCKED_MARKER=$W/locked-marker
echo snapraid > "$HS_BULK_TYPE_FILE"; echo storage > "$HS_CAPABILITIES_FILE"
mkdir -p "$B"/disks/data-04 "$B"/disks/data-05 "$B"/disks/data-06 "$B"/detached/data-08 "$B"/pool "$B"/cache "$B"/temp/usb "$B"/fast "$HS_STATE_DIR/recovering" "$HS_STATE_DIR/settings" "$HS_FM_DIR/busy"
echo data-06 > "$HS_BULK_CLOSED"
D4=$B/disks/data-04; D5=$B/disks/data-05
mkdir -p "$D4/shares/media/movies/Avatar" "$D4/shares/media/movies/Heat" "$D4/sensitive/vault" "$D4/lost+found" "$D5/shares/media/movies" "$B/pool/shares/media" "$B/temp/usb/photos"
head -c 300000 /dev/zero > "$D4/shares/media/movies/Avatar/Avatar.mkv"; echo poster > "$D4/shares/media/movies/Avatar/poster.jpg"
head -c 1000 /dev/zero > "$D4/shares/media/movies/Heat/Heat.mkv"
echo data > "$D4/shares/media/readme.txt"; echo more > "$D4/shares/media/notes.txt"
: > "$D4/shares/media/$(printf 'bad\001name.txt')"
mkdir -p "$D4/shares/media/busyfolder"; echo b > "$D4/shares/media/busyfolder/f"
printf 'pid\t%s\nitem\tbulk\tshares/media/busyfolder\tmove\t34\n' "$$" > "$HS_FM_DIR/busy/job1"
echo new > "$D5/shares/media/movies/Heat" 2>/dev/null || { rm -rf "$D5/shares/media/movies/Heat"; mkdir -p "$D5/shares/media/movies/Heat"; }
echo older > "$D5/shares/media/readme.txt"

out=$here
cap() { local name=$1; shift; local rc=0; "$@" > "$out/$name.out" 2>&1 < /dev/null || rc=$?; echo "$rc" > "$out/$name.rc"; }
capsel() { local name=$1; shift; local s=(); while [ "$1" != -- ]; do s+=("$1"); shift; done; shift; local rc=0
  printf '%s\0' "${s[@]}" | "$@" > "$out/$name.out" 2>&1 || rc=$?; echo "$rc" > "$out/$name.rc"; }
fm() { bash "$SCRIPTS/fm.sh" "$@"; }

echo true > "$HS_STATE_DIR/settings/fileManagerWrite"
cap locations fm locations
cap pair-ok fm pair disk:data-04 disk:data-05
cap pair-refused fm pair disk:data-04 pool:bulk
cap ls-disk-top fm ls disk:data-04 --path /
cap ls-folder fm ls disk:data-04 --path /shares/media
cap ls-page fm ls disk:data-04 --path /shares/media --limit 2
cap ls-pool-top fm ls pool:bulk --path /
cap ls-refused fm ls disk:data-04 --path /nope
capsel plan-copy Avatar Heat -- fm plan copy --from disk:data-04 --path /shares/media/movies --to disk:data-05 --to-path /shares/media/movies
capsel plan-copy-conflicts Avatar Heat -- fm plan copy --from disk:data-04 --path /shares/media/movies --to disk:data-05 --to-path /shares/media/movies --conflicts
capsel plan-copy-overwrite readme.txt -- fm plan copy --from disk:data-04 --path /shares/media --to disk:data-05 --to-path /shares/media --conflict overwrite
capsel plan-delete readme.txt notes.txt -- fm plan delete --from disk:data-04 --path /shares/media
capsel plan-refused readme.txt -- fm plan copy --from disk:data-04 --path /shares/media --to pool:bulk --to-path /shares/media
capsel plan-rename readme.txt -- fm plan rename --from disk:data-04 --path /shares/media --newname readme2.txt
capsel start-copy Avatar -- fm start copy --from disk:data-04 --path /shares/media/movies --to disk:data-05 --to-path /shares/media/movies
unit=$(awk -F'	' '$1 == "unit" { print $2; exit }' "$out/start-copy.out")
cap progress-done fm progress "${unit:-none}"
capsel start-copy-again Avatar -- fm start copy --from disk:data-04 --path /shares/media/movies --to disk:data-05 --to-path /shares/media/movies
unit=$(awk -F'	' '$1 == "unit" { print $2; exit }' "$out/start-copy-again.out")
cap progress-skipped fm progress "${unit:-none}"
capsel start-copy-fail Heat -- fm start copy --from disk:data-04 --path /shares/media/movies --to disk:data-05 --to-path /shares/media/movies
unit=$(awk -F'	' '$1 == "unit" { print $2; exit }' "$out/start-copy-fail.out")
cap progress-failed fm progress "${unit:-none}"
capsel start-confirm-missing readme.txt notes.txt -- fm start delete --from disk:data-04 --path /shares/media
capsel start-delete readme.txt notes.txt -- fm start delete --from disk:data-04 --path /shares/media --confirm "delete 2 files"
cap progress-unknown fm progress nothing
echo false > "$HS_STATE_DIR/settings/fileManagerWrite"
cap locations-write-off fm locations
capsel start-write-off readme2.txt -- fm start rename --from disk:data-04 --path /shares/media --newname x
capsel plan-write-off movies -- fm plan copy --from disk:data-04 --path /shares/media --to disk:data-05 --to-path /shares/media
touch "$W/locked-marker"
cap locations-locked fm locations
rm -f "$W/locked-marker"
echo "captured into $out"
