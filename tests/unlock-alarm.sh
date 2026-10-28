#!/usr/bin/env bash
# hs sys unlock alarm: while the "storage is locked" marker exists the "unlock needed" push is sent until it arrives
# (the boot message is often sent before the network is up). Fake curl, a temp run dir; no root, no network.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test
export HS_RUN_DIR=$WORK/run HS_STATE_DIR=$WORK/state HS_NOTIFY_URL=http://push.test/topic
export HS_ALARM_WAIT=0 HS_ALARM_TRIES=5
mkdir -p "$HS_RUN_DIR" "$HS_STATE_DIR"
BIN=$WORK/bin; mkdir -p "$BIN"
CALLS=$WORK/curl.calls; COUNT=$WORK/curl.count
# a curl that fails until it has been called $CURL_OK_AT times
cat > "$BIN/curl" <<'FAKE'
#!/usr/bin/env bash
n=$(( $(cat "$COUNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$COUNT"
a="$*"; echo "curl ${a//$'\n'/ }" >> "$CALLS"   # one line per call, the body has several
[ "$n" -ge "${CURL_OK_AT:-1}" ]
FAKE
chmod +x "$BIN/curl"
export PATH="$BIN:$PATH" CALLS COUNT
U="bash $SCRIPTS/unlock.sh --alarm"
reset() { : > "$CALLS"; echo 0 > "$COUNT"; }

echo "-- nothing locked: nothing is sent"
rm -f "$HS_RUN_DIR/storage-locked"; reset
check "exit 0" bash -c "$U"
check_eq "and no push message" "0" "$(grep -c . "$CALLS")"

echo "-- locked, the network is up at once"
touch "$HS_RUN_DIR/storage-locked"; reset; export CURL_OK_AT=1
check "exit 0" bash -c "$U"
check_eq "one push message" "1" "$(grep -c . "$CALLS")"
check_out "with the urgent priority" "Priority: urgent" cat "$CALLS"
check_out "naming the fix" "hs unlock" cat "$CALLS"

echo "-- locked, the network comes up on the third try"
reset; export CURL_OK_AT=3
check "exit 0" bash -c "$U"
check_eq "the message was retried until it arrived" "3" "$(grep -c . "$CALLS")"

echo "-- locked, the network never comes"
reset; export CURL_OK_AT=99
check "exit 0 after the last try (a failed push must not fail the boot)" bash -c "$U"
check_eq "it tried HS_ALARM_TRIES times" "5" "$(grep -c . "$CALLS")"

echo "-- unlocked while it was trying"
reset; export CURL_OK_AT=99
cat > "$BIN/sleep" <<'FAKE'
#!/usr/bin/env bash
rm -f "$HS_RUN_DIR/storage-locked"
FAKE
chmod +x "$BIN/sleep"
export HS_ALARM_WAIT=1
check "exit 0" bash -c "$U"
check_eq "it stopped after one try" "1" "$(grep -c . "$CALLS")"
rm -f "$BIN/sleep"

echo "-- through hs"
export HS_ALARM_WAIT=0; touch "$HS_RUN_DIR/storage-locked"; reset; export CURL_OK_AT=1
check "hs sys unlock alarm" bash -c "bash $SCRIPTS/lib/hs.sh sys unlock alarm"
check_eq "sends the message" "1" "$(grep -c . "$CALLS")"

finish
