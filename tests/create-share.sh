#!/usr/bin/env bash
# scripts/create-share.sh: a plain create refuses a name that exists in any tier; with --ct an existing share is mounted as before;
# --fast makes the dataset fast/<kind>/<name>. Fake zfs, incus, chown, chmod on PATH, a stub sync-shares: no root, no ZFS.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_BULK=$WORK/bulk HS_FAST=$WORK/fast HS_STATE_DIR=$WORK/state
unset HS_CALLER HS_GUIDED_TTY
BIN=$WORK/bin; mkdir -p "$BIN" "$HS_BULK/shares/media" "$HS_FAST/shares/notes" "$WORK/s/lib"
export CALLS=$WORK/calls; : > "$CALLS"
cat > "$BIN/zfs" <<'FAKE'
#!/usr/bin/env bash
echo "zfs $*" >> "$CALLS"
case "$*" in
  "list -H -o name fast"|"list -H -o name fast/shares"|"list -H -o name fast/shares/notes") exit 0 ;;
  list*) exit 1 ;;
esac
FAKE
cat > "$BIN/incus" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "info "*) ;;
  "config device get "*) exit 1 ;;
  "config device add "*) echo "incus $*" >> "$CALLS" ;;
  "config get "*) ;;
  query*) echo '{}' ;;
esac
exit 0
FAKE
cat > "$BIN/net" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
for c in chown chmod; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$c"; done
chmod +x "$BIN"/*
export PATH=$BIN:$PATH
echo zfs > "$WORK/bulk-type"; export HS_BULK_TYPE_FILE=$WORK/bulk-type
cp "$SCRIPTS/create-share.sh" "$SCRIPTS/machine-toml.py" "$WORK/s/"; cp "$SCRIPTS"/lib/*.sh "$WORK/s/lib/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/s/sync-shares.sh"
C="bash $WORK/s/create-share.sh"

echo "-- a plain create of an existing name is refused (bulk and fast)"
check_eq "bulk name" 1 "$($C media >/dev/null 2>&1; echo $?)"
check_eq "fast name, asked for on bulk" 1 "$($C notes >/dev/null 2>&1; echo $?)"
check_eq "case-insensitive" 1 "$($C MEDIA >/dev/null 2>&1; echo $?)"
check_eq "nothing was created" "0" "$(grep -c 'zfs create' "$CALLS" || true)"

echo "-- mounting an existing share still works"
check_eq "bulk share into an instance" 0 "$($C media --ct app /data >/dev/null 2>&1; echo $?)"
check_eq "the device was added" "1" "$(grep -c 'device add app media disk' "$CALLS" || true)"
: > "$CALLS"
check_eq "fast share into an instance" 0 "$($C notes --fast --ct app /data >/dev/null 2>&1; echo $?)"
check_eq "the existing dataset is not created again" "0" "$(grep -c 'zfs create' "$CALLS" || true)"
check_eq "the device points at /fast" "1" "$(grep -c "source=$HS_FAST/shares/notes" "$CALLS" || true)"

echo "-- a new fast share"
: > "$CALLS"
check_eq "exit 0" 0 "$($C fresh --fast >/dev/null 2>&1; echo $?)"
check_eq "the parent exists: only the dataset" "zfs create fast/shares/fresh" "$(grep 'zfs create' "$CALLS")"
: > "$CALLS"
check_eq "exit 0 (sensitive)" 0 "$($C vault2 --fast --sensitive >/dev/null 2>&1; echo $?)"
check_eq "parent made on first use, then the dataset" "zfs create -o mountpoint=/fast/sensitive fast/sensitive
zfs create fast/sensitive/vault2" "$(grep 'zfs create' "$CALLS")"

echo "-- pools tank (data) and ssd (apps): --pool, --fast, the default"
export HS_MACHINE_FILE=$WORK/machine.toml HS_POOLS_ROOT=$WORK/pr
printf 'pools = { tank = { role = "data", kind = "zfs" }, ssd = { role = "apps", kind = "zfs" } }
' > "$HS_MACHINE_FILE"
: > "$CALLS"
check_eq "default: the data pool" 0 "$($C d1 >/dev/null 2>&1; echo $?)"
check_eq "dataset tank/shares/d1" "zfs create -p tank/shares/d1" "$(grep 'zfs create' "$CALLS")"
: > "$CALLS"
check_eq "--pool tank" 0 "$($C d2 --pool tank --sensitive >/dev/null 2>&1; echo $?)"
check_eq "dataset tank/sensitive/d2" "zfs create -p tank/sensitive/d2" "$(grep 'zfs create' "$CALLS")"
: > "$CALLS"
check_eq "--fast is the apps pool" 0 "$($C d3 --fast >/dev/null 2>&1; echo $?)"
check_eq "parent with its mountpoint, then the dataset" "zfs create -o mountpoint=/ssd/shares ssd/shares
zfs create ssd/shares/d3" "$(grep 'zfs create' "$CALLS")"
: > "$CALLS"
check_eq "--pool ssd is the same" 0 "$($C d4 --pool ssd >/dev/null 2>&1; echo $?)"
check_eq "dataset ssd/shares/d4" "1" "$(grep -c 'zfs create ssd/shares/d4' "$CALLS" || true)"
: > "$CALLS"
out=$($C d5 --pool nosuch 2>&1 || true)
check_out "--pool nosuch is refused and lists the pools" "Pools for shares: ssd, tank" echo "$out"
check_eq "nothing was created" "0" "$(grep -c 'zfs create' "$CALLS" || true)"
unset HS_MACHINE_FILE HS_POOLS_ROOT
finish
