#!/usr/bin/env bash
# hs sys power started|stopping: the start and shutdown push messages. Fake curl, no root, no network.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test
export HS_RUN_DIR=$WORK/run HS_NOTIFY_URL=http://push.test/topic HS_NOTICE_WAIT=0 HS_NOTICE_TRIES=4
mkdir -p "$HS_RUN_DIR"
BIN=$WORK/bin; mkdir -p "$BIN"
CALLS=$WORK/curl.calls; COUNT=$WORK/curl.count
cat > "$BIN/curl" <<'FAKE'
#!/usr/bin/env bash
n=$(( $(cat "$COUNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$COUNT"
a="$*"; echo "curl ${a//$'\n'/ }" >> "$CALLS"   # one line per call, the body has several
[ "$n" -ge "${CURL_OK_AT:-1}" ]
FAKE
chmod +x "$BIN/curl"
export PATH="$BIN:$PATH" CALLS COUNT
reset() { : > "$CALLS"; echo 0 > "$COUNT"; }
P="bash $SCRIPTS/power-notice.sh"
export HS_EVENT_NOROOT=1 HS_STATE_DB=$WORK/ev.db
evs() { python3 "$SCRIPTS/state-db.py" event-list 100 | cut -f3-6,8 | tr '\t' ' '; }   # source kind subject level payload

echo "-- started long after boot (a rebuild restarted the unit): silent"
echo "5000.00 100.00" > "$WORK/uptime"; reset; export CURL_OK_AT=1
HS_PROC_UPTIME="$WORK/uptime" check "exit 0" $P started
check_eq "nothing sent" "0" "$(grep -c . "$CALLS")"
check_eq "and no event" "0" "$(evs | grep -c . || true)"
echo "60.00 100.00" > "$WORK/uptime"; export HS_PROC_UPTIME="$WORK/uptime"

echo "-- started, vault open"
rm -f "$HS_RUN_DIR/storage-locked"; reset; export CURL_OK_AT=1
check "exit 0" $P started
check_out "message names the start" "started" cat "$CALLS"
check_out "default priority" "Priority: default" cat "$CALLS"
check_out "event: started" "power started .* info" evs

echo "-- started, network comes on the third try"
reset; export CURL_OK_AT=3
check "exit 0" $P started
check_eq "retried until it arrived" "3" "$(grep -c . "$CALLS")"

echo "-- started, network never comes"
reset; export CURL_OK_AT=99
check "exit 0 (a failed push must not fail the boot)" $P started
check_eq "gave up after the tries" "4" "$(grep -c . "$CALLS")"

echo "-- started, storage locked: the unlock alarm speaks, not this one"
touch "$HS_RUN_DIR/storage-locked"; reset; export CURL_OK_AT=1
n_ev=$(evs | grep -c . || true)
check "exit 0" $P started
check_eq "no event either" "$n_ev" "$(evs | grep -c . || true)"
check_eq "nothing sent" "0" "$(grep -c . "$CALLS")"
rm -f "$HS_RUN_DIR/storage-locked"

echo "-- stopping"
reset; export CURL_OK_AT=1
HS_LIST_JOBS="echo 123 reboot.target start waiting" check "reboot" $P stopping
check_out "says rebooting" "rebooting" cat "$CALLS"
check_out "low priority" "Priority: low" cat "$CALLS"
check_out "event: stopping, reboot" "power stopping .* info {\"action\":\"reboot\"}" evs
reset
HS_LIST_JOBS="echo 77 poweroff.target start waiting" check "poweroff" $P stopping
check_out "says shutting down" "shutting down" cat "$CALLS"
check_out "event: stopping, poweroff" "power stopping .* info {\"action\":\"poweroff\"}" evs

echo "-- stopping without a shutdown job (rebuild restarts the unit): silent"
reset
n_ev=$(evs | grep -c . || true)
HS_LIST_JOBS="echo" check "exit 0" $P stopping
check_eq "nothing sent" "0" "$(grep -c . "$CALLS")"
check_eq "no event" "$n_ev" "$(evs | grep -c . || true)"

echo "-- through hs"
reset
check "hs sys power started" bash -c "bash $SCRIPTS/lib/hs.sh sys power started"

echo "-- unknown argument"
check "usage error" bash -c "! $P nonsense"
finish
