#!/usr/bin/env bash
# scripts/notify.sh routing (scripts/lib/notify-route.sh): quiet hours, held messages and their digest, the second channel.
# Fake curl and logger, no network, no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
mkdir -p "$WORK/bin" "$WORK/state"
cat > "$WORK/bin/curl" <<'FAKE'
#!/usr/bin/env bash
a="$*"; echo "${a//$'\n'/ ¶ }" >> "$CALLS"
case "$a" in *"$CURL_FAIL_ON"*) [ -n "${CURL_FAIL_ON:-}" ] && exit 22 ;; esac
exit 0
FAKE
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/logger"
chmod +x "$WORK/bin/curl" "$WORK/bin/logger"
export PATH=$WORK/bin:$PATH CALLS=$WORK/calls NTFY_HOST=Home HS_STATE_DIR=$WORK/state HS_HELD_DIR=$WORK/held HS_LANG=en
export HS_NOTIFY_URL=https://one.test/t HS_NOTIFY_URL_SECOND= HS_NOTIFY_SECOND_MIN=high
N="bash $SCRIPTS/notify.sh"
: > "$CALLS"
calls() { cat "$CALLS"; }

echo "-- the quiet window"
. "$SCRIPTS/lib/notify-route.sh"
q() { HS_QUIET_HOURS=$1 HS_NOW_HM=$2 route_quiet_now && echo yes || echo no; }
check_eq "inside, before midnight" yes "$(q 22:00-07:00 23:30)"
check_eq "inside, after midnight" yes "$(q 22:00-07:00 03:10)"
check_eq "outside" no "$(q 22:00-07:00 12:00)"
check_eq "the end is outside" no "$(q 22:00-07:00 07:00)"
check_eq "the start is inside" yes "$(q 22:00-07:00 22:00)"
check_eq "a window inside one day" yes "$(q 13:00-14:00 13:30)"
check_eq "off without a setting" no "$(q '' 03:00)"
check_eq "nonsense is off" no "$(q 25:99-xx 03:00)"
check_eq "an empty window is off" no "$(q 08:00-08:00 08:00)"

echo "-- held and sent"
export HS_QUIET_HOURS=22:00-07:00 HS_NOW_HM=03:00
$N --category ok "Home: all clear" "All clear." default
check_eq "an ordinary message is held" "" "$(calls)"
check_eq "and kept" 1 "$(route_held_count)"
$N --category problem "Home: 1 problem(s)" "Needs attention" high
check_out "a problem goes at once" "Title: Home: 1 problem" calls
$N --category alarm "Home: down" "Something is down" urgent
check_out "an alarm goes at once" "Priority: urgent" calls
check_eq "the held one is still waiting (still quiet)" 1 "$(route_held_count)"
$N --category start "Home: started" "Server started" low
check_eq "two are waiting" 2 "$(route_held_count)"
: > "$CALLS"
$N --flush
check_eq "flush inside the window sends nothing" "" "$(calls)"
export HS_NOW_HM=07:30
$N --flush
check_out "after the window ONE digest goes" "Title: .*: 2 messages from the quiet hours" calls
check_eq "exactly one call" 1 "$(wc -l < "$CALLS" | tr -d ' ')"
check_out "the digest lists them" "all clear" calls
check_eq "nothing is held afterwards" 0 "$(route_held_count)"
: > "$CALLS"
$N --flush
check_eq "flush with nothing held sends nothing" "" "$(calls)"

echo "-- an ordinary message after the window brings the digest first"
export HS_NOW_HM=03:00
$N --category ok "Home: updated" "Updated" default
export HS_NOW_HM=08:00
: > "$CALLS"
$N --category ok "Home: later" "Later" default
check_eq "digest and the message: two calls" 2 "$(wc -l < "$CALLS" | tr -d ' ')"
check_out "the digest came first" "^.*quiet hours.*" head -n1 "$CALLS"

echo "-- dry run"
export HS_NOW_HM=03:00
check_out "dry run says it is held" "held until the quiet hours end" $N --dry-run --category ok T M default
export HS_NOW_HM=09:00
out=$($N --dry-run --category ok T M default 2>&1)
if grep -q "held until" <<<"$out"; then fail "outside the window nothing is held"; else pass "outside the window nothing is held"; fi

echo "-- the second channel"
unset HS_QUIET_HOURS
export HS_NOTIFY_URL_SECOND=https://two.test/t HS_NOTIFY_SECOND_MIN=high
: > "$CALLS"
$N --category ok T M default
check_eq "a default message goes to the first channel only" 1 "$(wc -l < "$CALLS" | tr -d ' ')"
check_out "which is the first" "one.test" calls
: > "$CALLS"
$N --category problem T M high
check_eq "a problem goes to both" 2 "$(wc -l < "$CALLS" | tr -d ' ')"
check_out "the second one too" "two.test" calls
: > "$CALLS"
CURL_FAIL_ON=one.test $N --category problem T M high; rc=$?
check_eq "a dead first channel does not stop the second" 0 "$rc"
check_out "the second still got it" "two.test" calls
HS_NOTIFY_SECOND_MIN=low $N --dry-run --category start T M low > "$WORK/dry"
check_out "dry run names the second channel" "also to:" cat "$WORK/dry"
: > "$CALLS"
CURL_FAIL_ON=t HS_NOTIFY_STRICT=1 $N --category problem T M high; rc=$?
check_eq "strict callers learn that nothing arrived" 1 "$rc"
HS_NOTIFY_URL= HS_NOTIFY_URL_SECOND= $N --category problem T M high; rc=$?
check_eq "no channel at all is fine" 0 "$rc"

finish
