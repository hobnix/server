#!/usr/bin/env bash
# hs sys net plan|start setup (scripts/net-change.sh): connect the router with the API key on standard input. A stand-in for unifi.sh.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en
unset HS_CALLER HS_GUIDED_TTY
T=$'\t'
CALLS=$WORK/calls; : > "$CALLS"
export HS_STATE_DIR=$WORK/state; mkdir -p "$HS_STATE_DIR"
cat > "$WORK/unifi-stub.sh" <<STUB
#!/usr/bin/env bash
key=""; IFS= read -r key || true
echo "\$* [stdin=\$key]" >> "$CALLS"
[ "\${FAKE_FAIL:-}" = 1 ] && { echo "  ! UniFi answered 401 for GET rest/networkconf: no"; exit 1; }
exit 0
STUB
chmod +x "$WORK/unifi-stub.sh"; export HS_UNIFI=$WORK/unifi-stub.sh
run() { local in=$1; shift; rc=0; out=$(printf '%s' "$in" | timeout 20 bash "$SCRIPTS/net-change.sh" "$@" 2>/dev/null) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }

echo "-- plan"
run 'KEY123
' plan setup --address https://10.10.10.1;  check_eq "plan: exit 0" 0 "$rc"
has "connect the router at https://10.10.10.1" && pass "names the address" || fail "$out"
grep -q KEY123 <<<"$out" && fail "the plan must not print the key" || pass "the key is not printed"
run '' plan setup --address https://10.10.10.1;   check_eq "no key: needs" 2 "$rc"; has "^needs${T}key" && pass "needs the key" || fail "$out"
run 'K
' plan setup;                                    check_eq "no address: needs" 2 "$rc"; has "^needs${T}address" && pass "needs the address" || fail "$out"
run 'K
' plan setup --address 'https://x;rm -rf';       check_eq "a bad address is refused" 1 "$rc"
run 'K
' plan setup --address ftp://x;                  check_eq "only http(s) is accepted" 1 "$rc"
run 'K
' plan setup --address https://x --bogus;        check_eq "an unknown option is refused" 1 "$rc"
printf 'old\nkey\n' > "$HS_STATE_DIR/unifi"
run 'K
' plan setup --address https://r.test;           has "^warn${T}The address and key stored before are replaced" && pass "warns about the old connection" || fail "$out"
rm -f "$HS_STATE_DIR/unifi"

echo "-- start"
: > "$CALLS"; run 'SECRETKEY
' start setup --address https://r.test/;         check_eq "start: exit 0" 0 "$rc"
has "^status${T}done" && pass "done" || fail "$out"
grep -qx "setup --address https://r.test --stdin \[stdin=SECRETKEY\]" "$CALLS" && pass "unifi.sh got the address as an option and the key on stdin" || fail "$(cat "$CALLS")"
grep -q SECRETKEY <<<"$out" && fail "the answer must not hold the key" || pass "the key is not in the answer"
FAKE_FAIL=1 run 'K
' start setup --address https://r.test;           check_eq "a router that refuses: exit 1" 1 "$rc"
has "401" && pass "the reason is the last line of the check" || fail "$out"
run '' start setup --address https://r.test;      check_eq "start without a key: needs" 2 "$rc"
finish
