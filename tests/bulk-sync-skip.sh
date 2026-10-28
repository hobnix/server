#!/usr/bin/env bash
# bulk-sync.sh skips (exit 0, says why) while a data disk is detached by hand or out for a recovery (a disk that is simply missing still fails: tests/pool.sh);
# `hs sys disk marks` lists both kinds; the health check complains about a recovery that was never finished. No root: knobs instead of the real files.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en HS_CALLER=ui
unset HS_GUIDED_TTY
T=$'\t'
export HS_STATE_DIR=$WORK/state HS_DETACHED_DIR=$WORK/state/detached HS_RECOVER_DIR=$WORK/state/recovering HS_LOCK=$WORK/lock HS_LOCK_ADMIN=$WORK/admin
mkdir -p "$HS_DETACHED_DIR" "$HS_RECOVER_DIR"
echo snapraid > "$WORK/bulk-type"; echo "parity /nonexistent/snapraid.parity" > "$WORK/snapraid.conf"
export HS_BULK_TYPE_FILE=$WORK/bulk-type HS_SNAPRAID_CONF=$WORK/snapraid.conf
sync_() { rc=0; out=$(timeout 30 bash "$SCRIPTS/bulk-sync.sh" 2>&1 </dev/null) || rc=$?; }

echo "-- the sync skips for a disk that is away on purpose"
echo $(date +%s) > "$HS_DETACHED_DIR/data-04"
sync_
check_eq "detached: exit 0" 0 "$rc"
grep -q "data-04 is detached. Not syncing" <<<"$out" && pass "says which disk and why" || fail "detached: $out"
rm -f "$HS_DETACHED_DIR/data-04"
: > "$HS_RECOVER_DIR/data-05"
sync_
check_eq "recovery: exit 0" 0 "$rc"
grep -q "data-05 is out of the pool for a recovery. Not syncing" <<<"$out" && pass "says so, and how to give it back" || fail "recovery: $out"

echo "-- hs sys disk marks"
echo 1700000000 > "$HS_DETACHED_DIR/data-04"; : > "$HS_RECOVER_DIR/data-05"; touch -d @1700000100 "$HS_RECOVER_DIR/data-05"
out=$(bash "$SCRIPTS/disk-detach.sh" marks)
grep -q "^data-04${T}detached${T}1700000000$" <<<"$out" && grep -q "^data-05${T}recovering${T}1700000100$" <<<"$out" && pass "both kinds, with the time" || fail "marks: $out"
rm -f "$HS_DETACHED_DIR/data-04" "$HS_RECOVER_DIR/data-05"
out=$(bash "$SCRIPTS/disk-detach.sh" marks); [ -z "$out" ] && pass "nothing out: an empty list" || fail "empty: $out"
grep -q '^sys	sys disk marks	disk-detach.sh' "$SCRIPTS/lib/registry.tsv" && grep -q '("disk", "marks")' "$SCRIPTS/web-serve.py" && pass "registry row and read allowlist" || fail "wiring"

echo "-- the health check: a recovery nobody finished"
export HS_HEALTH_STATE=$WORK/h.state
: > "$HS_RECOVER_DIR/data-05"; touch -d "5 days ago" "$HS_RECOVER_DIR/data-05"
out=$(bash "$SCRIPTS/health-check.sh" --dry-run 2>&1 || true)
grep -q "data-05 has been out of the pool for 5 days for a recovery" <<<"$out" && pass "5 days is reported" || fail "5 days: $(head -c 300 <<<"$out")"
touch "$HS_RECOVER_DIR/data-05"
out=$(bash "$SCRIPTS/health-check.sh" --dry-run 2>&1 || true)
grep -q "for a recovery" <<<"$out" && fail "a fresh recovery is no problem" || pass "a fresh recovery is fine"

finish
