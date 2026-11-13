#!/usr/bin/env bash
# Case B: after the disks were formatted again SnapRAID refuses the sync ("Too many disks have changed UUIDs"). bulk-sync.sh must not force it
# by itself: it names the step (hs pool bulk sync --force-uuid), and with --force-uuid it syncs once more. Fake snapraid, no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en HS_CALLER=ui
unset HS_GUIDED_TTY
export HS_STATE_DIR=$WORK/state HS_DETACHED_DIR=$WORK/state/detached HS_RECOVER_DIR=$WORK/state/recovering HS_LOCK=$WORK/lock HS_LOCK_ADMIN=$WORK/admin
mkdir -p "$HS_DETACHED_DIR" "$HS_RECOVER_DIR" "$WORK/bin"
echo snapraid > "$WORK/bulk-type"; echo "parity /nonexistent/snapraid.parity" > "$WORK/snapraid.conf"
export HS_BULK_TYPE_FILE=$WORK/bulk-type HS_SNAPRAID_CONF=$WORK/snapraid.conf CALLS=$WORK/calls
cat > "$WORK/bin/snapraid" <<'FAKE'
#!/usr/bin/env bash
echo "snapraid $*" >> "$CALLS"
case "$*" in
  *" diff"*) exit 0 ;;
  *--force-uuid*) echo "Everything OK"; exit 0 ;;
  *" sync"*) echo "Too many disks have changed UUIDs since the last 'sync'."; exit 2 ;;
esac
FAKE
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/mountpoint"   # the members file of the host must not matter
chmod +x "$WORK/bin/snapraid" "$WORK/bin/mountpoint"; export PATH=$WORK/bin:$PATH
sync_() { : > "$CALLS"; rc=0; out=$(timeout 60 bash "$SCRIPTS/bulk-sync.sh" --no-mover "$@" 2>&1 </dev/null) || rc=$?; }

echo "-- without the flag: refused, the step is named, nothing is forced"
sync_
check_eq "exit 1" 1 "$rc"
grep -q "hs pool bulk sync --force-uuid" <<<"$out" && pass "names the step" || fail "no hint: $out"
check_eq "snapraid never saw --force-uuid" 0 "$(grep -c -e '--force-uuid' "$CALLS" || true)"

echo "-- with the flag: one more sync with --force-uuid"
sync_ --force-uuid
check_eq "exit 0" 0 "$rc"
check_eq "snapraid got --force-uuid" 1 "$(grep -c 'sync --force-uuid' "$CALLS" || true)"
finish
