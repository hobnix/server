#!/usr/bin/env bash
# hs sys expiry plan|start (scripts/expiry-change.sh): add and remove an expiry entry from the web interface, against the real expiry.sh in a
# temporary state folder. No root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en
unset HS_CALLER HS_GUIDED_TTY
export HS_STATE_DIR=$WORK/state; mkdir -p "$HS_STATE_DIR"
printf 'domain\t2030-01-31\tcloudflare dashboard\n' > "$HS_STATE_DIR/expiry"
run() { rc=0; out=$(timeout 20 bash "$SCRIPTS/expiry-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }
list() { bash "$SCRIPTS/expiry.sh" --list | cut -f1,2,5 | tr '\t' '|' | paste -sd, -; }

echo "-- add: plan"
run plan add cert
check_eq "no date: needs" "2 status	needs
needs	date" "$rc $out"
run plan add cert --date 2028-09-01 --renew "run the renew script"
check_eq "plan: exit 0" 0 "$rc"
has '^status	ok$' && has '^heading	add cert to the expiry dates$' && has '2028-09-01' && has 'run the renew script' && has '^long	no$' && pass "plan names the date and the hint" || fail "plan: $out"
has '^warn' && fail "a new name has no warning" || pass "a new name has no warning"
check_eq "plan writes nothing" "domain|2030-01-31|cloudflare dashboard" "$(list)"
run plan add domain --date 2031-02-01
has '^warn	domain is on the list already' && pass "an existing name is announced as replaced" || fail "exists: $out"
run plan add cert --date 2028-13-45
check_eq "an impossible date: refused" 1 "$rc"
run plan add cert --date tomorrow
check_eq "not ISO: refused" 1 "$rc"
run plan add '../x' --date 2028-09-01
check_eq "a bad name: refused" 1 "$rc"
run plan add cert --date 2028-09-01 --frob x
check_eq "an unknown option: refused" 1 "$rc"
run plan add cert --date 2028-09-01 --renew "$(printf 'a\tb')"
check_eq "a tab in the hint: refused" 1 "$rc"

echo "-- add: start"
run start add cert --date 2028-09-01 --renew "run the renew script"
check_eq "start: exit 0" 0 "$rc"
has '^status	done$' && pass "status done" || fail "start: $out"
check_eq "the entry is on the list" "domain|2030-01-31|cloudflare dashboard,cert|2028-09-01|run the renew script" "$(list)"
run start add domain --date 2031-02-01
check_eq "an existing name changes its date" "cert|2028-09-01|run the renew script,domain|2031-02-01|" "$(list)"

echo "-- remove"
run plan remove nothere
check_eq "remove an unknown entry: refused" 1 "$rc"
run plan remove cert
check_eq "remove plan: exit 0" 0 "$rc"
has '^heading	remove cert from the expiry dates$' && has '^command	bash .*expiry.sh remove cert$' && pass "remove plan" || fail "remove plan: $out"
has '^danger' && fail "remove is not red" || pass "remove is not red"
check_eq "plan removes nothing" "cert|2028-09-01|run the renew script,domain|2031-02-01|" "$(list)"
run start remove cert
check_eq "remove start: exit 0" 0 "$rc"
check_eq "the entry is gone" "domain|2031-02-01|" "$(list)"
run plan remove cert extra
check_eq "extra argument: refused" 1 "$rc"
run plan frobnicate x
check_eq "unknown action: refused" 1 "$rc"

finish
