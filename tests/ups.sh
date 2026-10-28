#!/usr/bin/env bash
# hs ups / hs sys ups status / the upsmon event handler / the health problems, with a fake upsc. No root needed.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1
U="bash $SCRIPTS/ups.sh"
export HS_UPS_CONF=$WORK/ups.conf HS_UPSC=$WORK/upsc HS_NOTIFY=$WORK/notify HS_SYSTEMD_RUN=$WORK/run HS_SYSTEMCTL=$WORK/ctl HS_UPSMON=$WORK/upsmon
export CALLS=$WORK/calls
: > "$CALLS"

# fake upsc: prints the file $WORK/upsc.out (missing = driver down)
cat > "$HS_UPSC" <<'EOF'
#!/usr/bin/env bash
[ -f "$(dirname "$0")/upsc.out" ] || exit 1
cat "$(dirname "$0")/upsc.out"
EOF
for f in notify run ctl upsmon; do printf '#!/usr/bin/env bash\necho "%s $*" >> "$CALLS"\n' "$f" > "$WORK/$f"; done
chmod +x "$WORK"/upsc "$WORK"/notify "$WORK"/run "$WORK"/ctl "$WORK"/upsmon
setups() { printf 'ups.status: %s\nbattery.charge: %s\nbattery.runtime: 1800\nups.load: 23\ninput.voltage: 231.0\nups.model: Back-UPS 700\n' "$1" "${2:-100}" > "$WORK/upsc.out"; }

echo "-- not configured"
check_eq "status says so" "configured	no" "$($U status)"
check_out "hs ups points at the guide" "No UPS is set up" $U show

printf 'name=ups\nshutdownMinutes=5\n' > "$HS_UPS_CONF"
echo "-- status"
setups OL 100
out=$($U status)
check_eq "online" "online" "$(sed -n 's/^state\t//p' <<<"$out")"
check_eq "charge" "100" "$(sed -n 's/^charge\t//p' <<<"$out")"
check_eq "runtime in seconds" "1800" "$(sed -n 's/^runtime\t//p' <<<"$out")"
check_eq "load" "23" "$(sed -n 's/^load\t//p' <<<"$out")"
check_eq "model" "Back-UPS 700" "$(sed -n 's/^model\t//p' <<<"$out")"
check_eq "no replace" "no" "$(sed -n 's/^replace\t//p' <<<"$out")"
setups "OB DISCHRG" 80
check_eq "on battery" "battery" "$($U status | sed -n 's/^state\t//p')"
setups "OB DISCHRG LB RB" 10
out=$($U status)
check_eq "low" "low" "$(sed -n 's/^state\t//p' <<<"$out")"
check_eq "replace" "yes" "$(sed -n 's/^replace\t//p' <<<"$out")"
rm -f "$WORK/upsc.out"
check_eq "unreachable" "no" "$($U status | sed -n 's/^reachable\t//p')"

echo "-- hs ups"
setups OL 100
check_out "mains power" "Power: mains power" $U show
check_out "charge shown" "Charge +100 %" $U show
check_out "runtime in minutes" "Runtime +30 min" $U show
check_out "the shutdown rule" "after 5 min on battery" $U show
setups "OB DISCHRG" 70
check_out "on battery" "ON BATTERY" $U show
rm -f "$WORK/upsc.out"
check_eq "unreachable fails" "1" "$($U show >/dev/null 2>&1; echo $?)"

echo "-- events"
: > "$CALLS"
NOTIFYTYPE=ONBATT $U event "UPS ups on battery"
check_out "power loss = alarm" "notify --category alarm .*power failure" cat "$CALLS"
check_out "the countdown starts" "run --unit=hs-ups-deadline --on-active=5m" cat "$CALLS"
: > "$CALLS"
NOTIFYTYPE=ONLINE $U event "UPS ups on line power"
check_out "power back = ok" "notify --category ok .*power is back" cat "$CALLS"
check_out "the countdown is stopped" "ctl stop hs-ups-deadline" cat "$CALLS"
: > "$CALLS"
NOTIFYTYPE=SHUTDOWN $U event "shutting down"
check_out "shutdown = stop" "notify --category stop" cat "$CALLS"
: > "$CALLS"
NOTIFYTYPE=COMMBAD $U event "lost"
check_out "lost contact = problem" "notify --category problem" cat "$CALLS"
printf 'name=ups\nshutdownMinutes=0\n' > "$HS_UPS_CONF"
: > "$CALLS"
NOTIFYTYPE=ONBATT $U event x
if grep -q "^run " "$CALLS"; then fail "0 minutes: no countdown"; else pass "0 minutes: no countdown"; fi
printf 'name=ups\nshutdownMinutes=5\n' > "$HS_UPS_CONF"

echo "-- deadline"
setups "OB DISCHRG" 50
: > "$CALLS"
$U deadline
check_out "still on battery: forced shutdown" "upsmon -c fsd" cat "$CALLS"
setups OL 100
: > "$CALLS"
$U deadline
check_eq "power is back: nothing" "" "$(cat "$CALLS")"

echo "-- health problems"
export HS_HEALTH_STATE=$WORK/health.state
H="bash $SCRIPTS/health-check.sh --dry-run"
setups OL 100
if $H 2>&1 | grep -q "ups"; then fail "healthy UPS: no problem"; else pass "healthy UPS: no problem"; fi
setups "OB DISCHRG" 60
check_out "on battery" "runs on the UPS battery \(charge 60%\)" $H
setups "OB LB" 5
check_out "battery low" "UPS battery is low" $H
setups "OL RB" 100
check_out "replace" "battery should be replaced" $H
rm -f "$WORK/upsc.out"
check_out "unreachable" "the UPS cannot be read" $H
rm -f "$HS_UPS_CONF"
if $H 2>&1 | grep -q "UPS"; then fail "not configured: nothing about the UPS"; else pass "not configured: nothing about the UPS"; fi

finish
