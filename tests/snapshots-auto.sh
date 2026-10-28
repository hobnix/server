#!/usr/bin/env bash
# Automatic snapshots (hs snapshots, hs share <share> auto): taking, naming, pruning, exclusions. Fake zfs, no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1
BIN=$WORK/fake; mkdir -p "$BIN"
SNAPS=$WORK/snaps; : > "$SNAPS"
export SNAPS
cat > "$BIN/zfs" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  list)
    last=${*: -1}
    if [[ "$*" == *"-t snapshot"* ]]; then
      grep "^$last@" "$SNAPS" || true
    else
      case "$last" in
        bulk/shares) printf 'bulk/shares\nbulk/shares/docs\nbulk/shares/media\n' ;;
        bulk/sensitive) printf 'bulk/sensitive\nbulk/sensitive/photos\nbulk/sensitive/pelican-backups\n' ;;
      esac
    fi ;;
  snapshot) echo "$2" >> "$SNAPS" ;;
  destroy) if [ "$2" = bulk/shares/stuck@auto-h-2026100100 ]; then exit 1; fi; sed -i "\\#^$2\$#d" "$SNAPS" ;;
esac
FAKE
chmod +x "$BIN/zfs"
export HS_ZFS=$BIN/zfs HS_BULK_TYPE=zfs HS_STATE_DIR=$WORK/state HS_SNAPSHOTS_SWITCH=$WORK/switch HS_LOCKED_MARKER=$WORK/locked
mkdir -p "$HS_STATE_DIR"
A="bash $SCRIPTS/snapshots-auto.sh"
t0=$(date -d '2026-10-05 10:00' +%s)

check_out "off by default" "Automatic snapshots are off" env HS_NOW=$t0 $A run
check_eq "and nothing was taken" "0" "$(wc -l < "$SNAPS")"
echo on > "$WORK/switch"
check_out "the first run takes hourly, daily and weekly" "9 taken, 0 old ones deleted" env HS_NOW=$t0 $A run
check_out "named by hour, day and week" "bulk/shares/docs@auto-h-2026100510" cat "$SNAPS"
check_out "the week number is ISO" "bulk/shares/docs@auto-w-2026W41" cat "$SNAPS"
check_eq "pelican-backups is out from the start" "0" "$(grep -c pelican "$SNAPS")"
check_out "again in the same hour: nothing new" "0 taken" env HS_NOW=$((t0 + 600)) $A run
check_out "the next hour: only an hourly one" "3 taken" env HS_NOW=$((t0 + 3600)) $A run
check_eq "daily and weekly were not repeated" "1" "$(grep -c '^bulk/shares/docs@auto-d-' "$SNAPS")"
for h in $(seq 2 30); do HS_NOW=$((t0 + h * 3600)) $A run >/dev/null; done
check_eq "hourly snapshots stop at 24" "24" "$(grep -c '^bulk/shares/docs@auto-h-' "$SNAPS")"
check_eq "the newest hourly one is kept" "1" "$(grep -c "^bulk/shares/docs@auto-h-$(date -d "@$((t0 + 30 * 3600))" +%Y%m%d%H)\$" "$SNAPS")"
for d in 1 2 3 4 5 6 7 8 9 10; do HS_NOW=$((t0 + d * 86400)) $A run >/dev/null; done
check_eq "daily snapshots stop at 7" "7" "$(grep -c '^bulk/shares/docs@auto-d-' "$SNAPS")"
for w in 1 2 3 4 5 6 7 8; do HS_NOW=$((t0 + w * 7 * 86400)) $A run >/dev/null; done
check_eq "weekly snapshots stop at 4" "4" "$(grep -c '^bulk/shares/docs@auto-w-' "$SNAPS")"
echo "bulk/shares/docs@manual-x" >> "$SNAPS"
HS_NOW=$((t0 + 99 * 86400)) $A run >/dev/null
check_eq "manual snapshots are never touched" "1" "$(grep -c 'docs@manual-x' "$SNAPS")"

echo "-- shares in and out"
check_out "a share can be left out" "left out of the automatic snapshots" $A media off
: > "$SNAPS"
HS_NOW=$t0 $A run >/dev/null
check_eq "and gets no snapshot" "0" "$(grep -c 'shares/media' "$SNAPS")"
check_out "a share can be taken back" "included in the automatic snapshots" $A media on
check_out "an unknown share is refused" "No share called 'nope'" $A nope off
check_out "list shows the switch and the shares" "pelican-backups	off" $A list
check_out "list shows an included share" "docs	on" $A list

echo "-- special cases"
: > "$SNAPS"
: > "$WORK/locked"
check_out "locked storage: nothing" "locked" env HS_NOW=$t0 $A run
rm -f "$WORK/locked"
check_out "--dry-run only says" "would take bulk/shares/docs@auto-h-2026100510" env HS_NOW=$t0 $A run --dry-run
check_eq "and takes nothing" "0" "$(wc -l < "$SNAPS")"
check_out "snapraid: points to the backup" "backup is the history" env HS_BULK_TYPE=snapraid $A run

finish
