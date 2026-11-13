#!/usr/bin/env bash
# The network check (scripts/lib/netcheck.sh, hs sys net check, issue #179) with a fake ip, getent and /sys/class/net.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test
C="bash $SCRIPTS/net-check.sh --list"
B=$WORK/bin; mkdir -p "$B"
# the fake ip: the output comes from files in $WORK/fake
F=$WORK/fake; mkdir -p "$F"
cat > "$B/ip" <<'X'
#!/bin/sh
case "$*" in
  *"addr show"*) cat "$FAKE/addr" 2>/dev/null ;;
  *"route show"*) cat "$FAKE/route" 2>/dev/null ;;
esac
exit 0
X
cat > "$B/getent" <<'X'
#!/bin/sh
[ -f "$FAKE/dns" ] || exit 2
cat "$FAKE/dns"
X
chmod +x "$B/ip" "$B/getent"
export PATH="$B:$PATH" FAKE=$F HS_NETCHECK_NOW=1800000000
NET=$WORK/net; export HS_SYS_NET=$NET

card() {   # card <name> <carrier 0|1> [wireless]
  mkdir -p "$NET/$1/device"; printf '%s\n' "$2" > "$NET/$1/carrier"
  [ -z "${3:-}" ] || mkdir -p "$NET/$1/wireless"
}
good() {
  rm -rf "$NET"; mkdir -p "$NET"; card eth0 1
  printf '2: eth0    inet 192.168.1.5/24 brd 192.168.1.255 scope global dynamic eth0\n' > "$F/addr"
  printf 'default via 192.168.1.1 dev eth0 proto dhcp src 192.168.1.5 metric 100\n' > "$F/route"
  printf '140.82.121.3    github.com\n' > "$F/dns"
}
state() { printf '%s\n' "$2" | awk -F'\t' -v i="$1" '$1 == i { print $2 }'; }

echo "-- all ok"
good
out=$($C); rc=$?
check_eq "exit 0" 0 "$rc"
check_eq "six rows" 6 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
check_eq "item order" "link wireless address route dns clock" "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
check_eq "every row is 4 fields" 0 "$(printf '%s\n' "$out" | awk -F'\t' 'NF != 4 { n++ } END { print n + 0 }')"
check_eq "no empty field" 0 "$(printf '%s\n' "$out" | awk -F'\t' '{ for (i = 1; i <= NF; i++) if ($i == "") n++ } END { print n + 0 }')"
check_eq "states" "ok ok ok ok ok ok" "$(printf '%s\n' "$out" | cut -f2 | tr '\n' ' ' | sed 's/ $//')"
check_out "address value" "address	ok	192.168.1.5/24 on eth0	reserve this address on your router" echo "$out"
check_out "route value" "route	ok	192.168.1.1 on eth0" echo "$out"

echo "-- no link"
good; card eth0 0
out=$($C); rc=$?
check_eq "exit 1" 1 "$rc"
check_eq "link fails" fail "$(state link "$out")"
check_eq "address fails too" fail "$(state address "$out")"
check_eq "route fails too" fail "$(state route "$out")"
check_eq "dns fails too" fail "$(state dns "$out")"
check_eq "still six rows" 6 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
check_out "the fix points at the cable" "cable" echo "$out"

echo "-- no route"
good; : > "$F/route"
out=$($C || true)
check_eq "link ok" ok "$(state link "$out")"
check_eq "route fails" fail "$(state route "$out")"
check_eq "dns fails after it" fail "$(state dns "$out")"
check_out "dns names the route" "dns	fail	-	Fix the route first" echo "$out"

echo "-- no address"
good; : > "$F/addr"
out=$($C || true)
check_eq "address fails" fail "$(state address "$out")"
check_out "DHCP advice" "DHCP is off" echo "$out"

echo "-- no DNS"
good; rm -f "$F/dns"
out=$($C); rc=$?
check_eq "exit 1" 1 "$rc"
check_eq "dns fails" fail "$(state dns "$out")"
check_eq "route stays ok" ok "$(state route "$out")"
HS_NETCHECK_HOST=example.org check_out "the host knob is named" "example.org does not resolve" $C

echo "-- wrong clock"
good
out=$(HS_NETCHECK_NOW=1000000000 $C || true)
check_eq "clock fails" fail "$(state clock "$out")"
check_out "fix says date -s" "date -s" echo "$out"

echo "-- wireless only"
good; rm -rf "$NET"; mkdir -p "$NET"; card wlan0 1 w
out=$($C); rc=$?
check_eq "wireless warns" warn "$(state wireless "$out")"
check_eq "a warning alone does not fail" 0 "$rc"
check_out "needs a cable" "a server needs a cable" echo "$out"
good; card wlan1 0 w
check_eq "wired card present: no warning" ok "$(state wireless "$($C)")"

echo "-- netcheck_show"
good
out=$(bash -c ". '$SCRIPTS/lib/ui.sh'; . '$SCRIPTS/lib/netcheck.sh'; netcheck_show")
check_out "the table and the router advice" "Reserve this address on your router" echo "$out"
check_out "the header" "Item" echo "$out"
rm -f "$F/dns"
out=$(bash -c ". '$SCRIPTS/lib/ui.sh'; . '$SCRIPTS/lib/netcheck.sh'; netcheck_show")
check_eq "no advice when a check failed" 0 "$(grep -c 'Reserve this address' <<<"$out")"
check "netcheck_ok is false on a failure" bash -c ". '$SCRIPTS/lib/netcheck.sh'; ! netcheck_ok"

echo "-- usage"
check "an argument other than --list is refused" bash -c '! bash "$1" --nope' _ "$SCRIPTS/net-check.sh"
finish
