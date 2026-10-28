#!/usr/bin/env bash
# hs expiry: the list file, the stages (ok / soon / due / expired) and what the health check makes of them. No root needed.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test HS_STATE_DIR=$WORK/state HS_HEALTH_STATE=$WORK/h.state HS_EXPIRY_TODAY=2026-10-11
export HS_REPO=$WORK/norepo HS_BACKUP_STATE=$WORK/none HS_HEARTBEAT_URL=
mkdir -p "$HS_STATE_DIR"
E="bash $SCRIPTS/expiry.sh"
hc() { bash "$SCRIPTS/health-check.sh" --dry-run 2>&1 || true; }

echo "-- empty"
check_out "nothing entered" "Nothing is entered" $E list
check_eq "--list is empty" "" "$($E --list)"

echo "-- add"
check "add with a hint" $E add "dc1 certificate" 2028-09-01 "hs recipe domain, then replace the certificate"
check "add without a hint" $E add domain 2026-11-30
check "add soon" $E add cloudflare-token 2026-10-25 "make a new tunnel token in the dashboard"
check "add due" $E add offsite 2026-10-15 "new B2 key"
check "add expired" $E add old 2026-10-01 "pay"
check_out "a bad date is refused" "not a date" $E add x 2026-13-45
check_out "a date in words is refused" "not a date" $E add x tomorrow
check "usage without a date" bash -c "! $E add onlyname"
check_eq "the file has five lines" 5 "$(wc -l < "$HS_STATE_DIR/expiry" | tr -d ' ')"

echo "-- stages"
l=$($E --list)
st() { awk -F'\t' -v n="$1" '$1 == n {print $4}' <<<"$l"; }
check_eq "far away is ok" ok "$(st "dc1 certificate")"
check_eq "50 days is ok" ok "$(st domain)"
check_eq "14 days is soon" soon "$(st cloudflare-token)"
check_eq "4 days is due" due "$(st offsite)"
check_eq "past is expired" expired "$(st old)"
check_eq "days left counted" 14 "$(awk -F'\t' '$1 == "cloudflare-token" {print $3}' <<<"$l")"
check_eq "30 days left is soon" soon "$(HS_EXPIRY_TODAY=2026-10-31 $E --list | awk -F"	" '$1 == "domain" {print $4}')"
check_eq "31 days left is ok" ok "$(HS_EXPIRY_TODAY=2026-10-30 $E --list | awk -F"	" '$1 == "domain" {print $4}')"
check_eq "exactly 7 days is due" due "$(HS_EXPIRY_TODAY=2026-10-08 $E --list | awk -F'\t' '$1 == "offsite" {print $4}')"
check_eq "the day itself is due (0 left)" due "$(HS_EXPIRY_TODAY=2026-10-15 $E --list | awk -F'\t' '$1 == "offsite" {print $4}')"
check_out "list shows the how" "new tunnel token|tunnel token in the dashboard" $E list

echo "-- change and remove"
$E add offsite 2027-01-01 "new key" >/dev/null
check_eq "same name changes the date" ok "$($E --list | awk -F'\t' '$1 == "offsite" {print $4}')"
check_eq "and stays one line" 1 "$(grep -c '^offsite	' "$HS_STATE_DIR/expiry")"
check "remove" $E remove old
check_out "remove of an unknown name" "No entry called" $E remove old
check_eq "gone" 0 "$(grep -c '^old	' "$HS_STATE_DIR/expiry")"
$E add offsite 2026-10-15 "new B2 key" >/dev/null
$E add old 2026-10-01 pay >/dev/null

echo "-- the health check"
out=$(hc)
grep -q "dc1 certificate" <<<"$out" && fail "a far date is no problem" || pass "a far date is no problem"
grep -q "domain runs out" <<<"$out" && fail "50 days is no problem" || pass "50 days is no problem"
grep -q "cloudflare-token runs out on 2026-10-25 (in 14 days)\..*Renew: make a new tunnel token" <<<"$out" && pass "soon is reported with the way to renew" || fail "soon: $out"
grep -q "offsite runs out on 2026-10-15 (in 4 day(s)): renew it now\." <<<"$out" && pass "due is reported" || fail "due: $out"
grep -q "old ran out on 2026-10-01 (10 day(s) ago)" <<<"$out" && pass "expired is reported" || fail "expired: $out"
printf 'broken\tnot-a-date\tx\n' >> "$HS_STATE_DIR/expiry"
check_out "a broken date is reported" "entry broken .*not YYYY-MM-DD" hc

echo "-- registry and help"
check_out "hs expiry is a command" "Days left|Nothing is entered" bash "$SCRIPTS/lib/hs.sh" expiry
check_out "help explains it" "30 and 7 days|expiry" bash "$SCRIPTS/lib/hs.sh" help expiry

finish
