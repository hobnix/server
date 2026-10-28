#!/usr/bin/env bash
# hs share <share> snapshot|snapshots|rollback against a stateful fake zfs. No root needed.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1
BIN=$WORK/fake; mkdir -p "$BIN"
SNAPS=$WORK/snaps; : > "$SNAPS"
export SNAPS WORK
cat > "$BIN/zfs" <<'FAKE'
#!/usr/bin/env bash
# list -H -o name <ds> | list -H -t snapshot ... <ds> | snapshot <ds@n> | rollback [-r] <ds@n>
case "$1" in
  list)
    last=${*: -1}
    if [[ "$*" == *"-t snapshot"* ]]; then
      grep "^$last@" "$SNAPS" | while read -r s; do printf '%s\t2026-10-04 10:00\t0B\n' "$s"; done
    else
      case "$last" in bulk/shares/docs|bulk/sensitive/photos) echo "$last" ;; *) exit 1 ;; esac
    fi ;;
  snapshot) echo "$2" >> "$SNAPS" ;;
  rollback)
    if [ "$2" = -r ]; then t=$3; ds=${t%@*}
      n=$(grep -n "^$t\$" "$SNAPS" | cut -d: -f1)
      sed -i "$((n + 1)),\${/^${ds//\//\\/}@/d}" "$SNAPS"
    else t=$2; fi
    echo "$t" > "$WORK/rolled" ;;
esac
FAKE
chmod +x "$BIN/zfs"
export HS_ZFS=$BIN/zfs HS_BULK_TYPE=zfs
S="bash $SCRIPTS/share-snap.sh"

check_out "no snapshots yet says so" "No snapshots yet" $S docs snapshots
check_out "a snapshot with a name" "bulk/shares/docs@before" $S docs snapshot before
$S docs snapshot second >/dev/null
check_out "snapshots are listed" "second" $S docs snapshots
check_out "an unknown share is refused" "No share called 'nope'" $S nope snapshots
check_out "a bad name is refused" "not a snapshot name" $S docs snapshot 'a b'
check_out "a sensitive share is found too" "bulk/sensitive/photos@x" $S photos snapshot x
check_out "rollback without a terminal needs --yes" "Nothing is changed without --yes" $S docs rollback
check_out "rollback to the newest" "back at second" $S docs rollback --yes
check_eq "the newest snapshot was used" "bulk/shares/docs@second" "$(cat "$WORK/rolled")"
check_out "an older snapshot warns about the newer ones" "deletes every snapshot after it" $S docs rollback before --yes
check_eq "newer snapshots are gone" "before" "$($S docs snapshots | cut -f1)"
check_out "an unknown snapshot is refused" "No snapshot 'zzz'" $S docs rollback zzz --yes
HS_BULK_TYPE=snapraid check_out "the snapraid layout points to the backup" "hs share docs restore" $S docs snapshot
finish
