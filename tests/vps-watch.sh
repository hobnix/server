#!/usr/bin/env bash
# vps/hs-watch.sh with a fake curl: no root, no network.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'FAKE'
#!/usr/bin/env bash
# FAKE_BEAT=yes|no|down  FAKE_CODE_<n>  FAKE_SENT: file the alerts are appended to
args="$*"
case "$args" in
  *"json?poll=1"*)
    [ "$FAKE_BEAT" = down ] && exit 7
    [ "$FAKE_BEAT" = yes ] && echo '{"event":"message","message":"alive"}'
    exit 0 ;;
  *" -w "*) echo "${FAKE_CODE:-200}"; exit 0 ;;
  *) echo "${args//$'\n'/ }" >> "$FAKE_SENT"; exit 0 ;;   # the body has several lines: one line per message
esac
FAKE
chmod +x "$WORK/bin/curl"
export PATH=$WORK/bin:$PATH FAKE_SENT=$WORK/sent
cat > "$WORK/conf" <<CONF
HEARTBEAT_URL=https://ntfy.test/hb
ALERT_URL=https://ntfy.test/alert
SITES="https://a.test"
CONF
export HS_WATCH_CONF=$WORK/conf HS_WATCH_STATE=$WORK/state
W="bash $ROOT/vps/hs-watch.sh"
sent() { [ -f "$FAKE_SENT" ] && wc -l < "$FAKE_SENT" | tr -d ' ' || echo 0; }

export FAKE_BEAT=yes FAKE_CODE=200
check_out "all well, nothing to send" "Nothing to send" $W
check_eq "and nothing was sent" 0 "$(sent)"

export FAKE_BEAT=no
$W >/dev/null 2>&1
check_eq "a missing heartbeat sends one alarm" 1 "$(sent)"
grep -q "Priority: urgent" "$FAKE_SENT" && pass "the alarm is urgent" || fail "the alarm is urgent"
$W >/dev/null 2>&1
check_eq "the same problem is not sent twice" 1 "$(sent)"

export FAKE_BEAT=down
check_out "ntfy unreachable is not judged" "not judged" $W
check_eq "and keeps the alarm without repeating it" 1 "$(sent)"
export FAKE_BEAT=yes
$W >/dev/null 2>&1
check_eq "recovery was announced" 2 "$(sent)"

export FAKE_CODE=502
$W >/dev/null 2>&1
check_eq "a 5xx from a public address is reported" 3 "$(sent)"
export FAKE_CODE=000
$W >/dev/null 2>&1
check_eq "no answer at all is a different problem (sent again)" 4 "$(sent)"
export FAKE_CODE=404
$W >/dev/null 2>&1
check_eq "404 counts as reachable (all clear sent)" 5 "$(sent)"
echo "-- addresses from files"
printf 'https://ntfy.test/hb
' > "$WORK/hbfile"; printf 'https://ntfy.test/alert
' > "$WORK/alfile"
printf 'SITES=""
' > "$WORK/conf2"
rm -f "$WORK/sent" "$WORK/state"; export FAKE_BEAT=no
HS_WATCH_CONF=$WORK/conf2 HEARTBEAT_URL_FILE=$WORK/hbfile ALERT_URL_FILE=$WORK/alfile $W >/dev/null 2>&1
check_eq "URLs can come from files" 1 "$(sent)"
grep -q "ntfy.test/alert" "$WORK/sent" && pass "and the alarm goes to the alert file's address" || fail "and the alarm goes to the alert file's address"
finish
