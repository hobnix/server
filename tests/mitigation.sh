#!/usr/bin/env bash
# Mitigation level 1 (pause the sync, scrub and cache mover), acknowledging problems, the pause marker in bulklock.sh
#. A fake zpool makes a degraded pool; no root, no real pools.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
mkdir -p "$WORK/bin" "$WORK/state"
cat > "$WORK/bin/zpool" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "list -H -o name") echo tank ;;
  "status -x tank") echo "pool 'tank' is DEGRADED" ;;
  "list -H -o health tank") cat "$HS_STATE_DIR/poolstate" 2>/dev/null || echo DEGRADED ;;
  "list -Hp -o name,alloc,size") printf 'tank\t100\t1000\n' ;;
  "list -H -o name,cap") printf 'tank\t10%%\n' ;;
  "status tank") echo "  scan: scrub repaired 0B in 00:01:00 with 0 errors on Sun Oct  4 00:24:01 2099" ;;
esac
FAKE
printf '#!/usr/bin/env bash
exit 0
' > "$WORK/bin/flock"   # the lock itself is tests/bulklock.sh's business
chmod +x "$WORK/bin/zpool" "$WORK/bin/flock"
export PATH=$WORK/bin:$PATH HS_PLAIN=1 HS_CALLER=test HS_LANG=en
export HS_STATE_DIR=$WORK/state HS_HEALTH_STATE=$WORK/h.state HS_ACK_FILE=$WORK/ack HS_BULK_PAUSE=$WORK/paused
export HS_BACKUP_STATE=$WORK/none HS_TEMP_ROOT=$WORK/t HS_RUN_DIR=$WORK/run HS_REPO=$WORK/norepo HS_NOTIFY_URL= HS_HEARTBEAT_URL=
export HS_CAP_CACHE=$WORK/nocache HS_SELFTEST_STATE=$WORK/none HS_SCRUB_STATE=$WORK/none
mkdir -p "$WORK/run" "$WORK/t"
HC="bash $SCRIPTS/health-check.sh"
HA="bash $SCRIPTS/health-ack.sh"
keys() { $HC --keys 2>/dev/null; }

echo "-- the degraded pool is a problem and a trigger"
check_out "the pool key is listed" "^zfs:tank:DEGRADED" keys
export HS_AUTO_MITIGATE=false
$HC >/dev/null 2>&1 || true
[ ! -e "$WORK/paused" ] && pass "off by default: nothing is paused" || fail "off by default: nothing is paused"
export HS_AUTO_MITIGATE=true
$HC >/dev/null 2>&1 || true
[ -e "$WORK/paused" ] && pass "on: the pause marker is written" || fail "on: the pause marker is written"
check_out "the marker names the cause" "^keys=zfs:tank:DEGRADED" cat "$WORK/paused"
check_out "the pause is itself a problem" "^mitigation:paused" keys
check_out "the message says what is paused" "paused because of zfs:tank:DEGRADED. Nothing was deleted" $HC --dry-run

echo "-- the jobs skip while paused"
export HS_LOCK=$WORK/lock HS_LOCK_ADMIN=$WORK/admin
out=$(bash -c ". '$SCRIPTS/lib/bulklock.sh'; bulk_lock_job 1; echo RAN" 2>&1)
check_out "a timer job exits quietly" "Paused by the health check" echo "$out"
if grep -q RAN <<<"$out"; then fail "the job did not continue"; else pass "the job did not continue"; fi
out=$(HS_IGNORE_PAUSE=1 bash -c ". '$SCRIPTS/lib/bulklock.sh'; bulk_lock_job 1; echo RAN" 2>&1)
check_out "HS_IGNORE_PAUSE runs it anyway" "RAN" echo "$out"
out=$(bash -c ". '$SCRIPTS/lib/bulklock.sh'; bulk_lock_admin 1; echo RAN" 2>&1)
check_out "a pool change is never paused" "RAN" echo "$out"

echo "-- the pause lifts itself when the cause is gone"
cat > "$WORK/bin/zpool" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "list -H -o name") echo tank ;;
  "status -x tank") echo "pool 'tank' is healthy" ;;
  "list -Hp -o name,alloc,size") printf 'tank\t100\t1000\n' ;;
  "list -H -o name,cap") printf 'tank\t10%%\n' ;;
  "status tank") echo "  scan: scrub repaired 0B in 00:01:00 with 0 errors on Sun Oct  4 00:24:01 2099" ;;
esac
FAKE
$HC >/dev/null 2>&1 || true
[ ! -e "$WORK/paused" ] && pass "healthy again: the marker is gone" || fail "healthy again: the marker is gone"

echo "-- hs health resume acknowledges the cause"
cat > "$WORK/bin/zpool" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "list -H -o name") echo tank ;;
  "status -x tank") echo "pool 'tank' is DEGRADED" ;;
  "list -H -o health tank") cat "$HS_STATE_DIR/poolstate" 2>/dev/null || echo DEGRADED ;;
  "list -Hp -o name,alloc,size") printf 'tank\t100\t1000\n' ;;
  "list -H -o name,cap") printf 'tank\t10%%\n' ;;
  "status tank") echo "  scan: scrub repaired 0B in 00:01:00 with 0 errors on Sun Oct  4 00:24:01 2099" ;;
esac
FAKE
$HC >/dev/null 2>&1 || true
check_out "paused again" "keys=zfs:tank:DEGRADED" cat "$WORK/paused"
check_out "resume says so" "Lifted" $HA resume
[ ! -e "$WORK/paused" ] && pass "resume removes the marker" || fail "resume removes the marker"
check_out "the cause is acknowledged" "^zfs:tank:DEGRADED" cut -f1 "$WORK/ack"
$HC >/dev/null 2>&1 || true
[ ! -e "$WORK/paused" ] && pass "the next run does not pause again" || fail "the next run does not pause again"
check_out "the problem is marked acknowledged in the list" "zfs:tank:DEGRADED	.*	acked" $HC --list

echo "-- acknowledging"
out=$($HC --dry-run 2>&1)
if grep -q "ZFS pool tank" <<<"$out"; then fail "an acknowledged problem is not shown"; else pass "an acknowledged problem is not shown"; fi
check_out "the count is mentioned" "1 acknowledged problem" echo "$out"
check_out "unack puts it back" "Back in the reports" $HA unack zfs:tank:DEGRADED
check_out "it is listed again" "ZFS pool tank is not healthy" $HC --dry-run
check_out "an unknown id is refused" "not an active problem" $HA ack nonsense:id
check_out "ack of a real id works" "Acknowledged zfs:tank:DEGRADED" $HA ack zfs:tank:DEGRADED
echo "-- an entry whose problem cleared is dropped"
printf 'gone:thing\t1\n' >> "$WORK/ack"
$HC >/dev/null 2>&1 || true
if grep -q '^gone:thing' "$WORK/ack"; then fail "the cleared entry is dropped"; else pass "the cleared entry is dropped"; fi
check_out "the live one stays" "^zfs:tank:DEGRADED" cut -f1 "$WORK/ack"

echo "-- since when, and which channels were told"
rm -f "$WORK/health-since"
check_out "a new problem is open since now" "^zfs:tank:DEGRADED	.*	acked	1000	-$" env HS_NOW=1000 $HC --list
check_out "a later run keeps the first time" "acked	1000	-$" env HS_NOW=2000 $HC --list
mkdir -p "$WORK/state/notify-channels"
printf 'zfs:tank:FAULTED	5	main,second
' > "$WORK/state/notify-channels/.told"
echo FAULTED > "$WORK/state/poolstate"
check_out "a changed key starts again, with the channels that were told" "^zfs:tank:FAULTED	.*	-	3000	main,second$" env HS_NOW=3000 $HC --list
if grep -q '^zfs:tank:DEGRADED' "$WORK/health-since"; then fail "the cleared key is dropped from the since file"; else pass "the cleared key is dropped from the since file"; fi
check_out "the acknowledge command still lists the problem" "^zfs:tank:FAULTED" $HA ack
rm -f "$WORK/state/poolstate"

finish
