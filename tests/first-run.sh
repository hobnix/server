#!/usr/bin/env bash
# First-run setup (docs/adr/0022-first-run-console-token.md): token, flag, expiry, burn, POST /api/setup, and `hs setup-code` on a temp state folder.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi

echo "-- first-run token and endpoint"
if out=$(python3 -I "$ROOT/tests/first-run-test.py" 2>&1); then pass "first-run tests ($(grep -E '^Ran ' <<<"$out"))"; else fail "first-run tests: $(tail -n 25 <<<"$out")"; fi

echo "-- hs setup-code"
export HS_FIRST_RUN_FILE="$WORK/first-run.json" HS_CALLER=
check "status with no flag says nothing is waiting" bash -c "bash '$SCRIPTS/setup-code.sh' status 2>&1 | grep -q 'No first setup'"
check "boot with no flag prints nothing" bash -c "out=\$(HS_SETUP_WAIT=1 HS_SETUP_ADDRS='' bash '$SCRIPTS/setup-code.sh' boot 2>&1); test -z \"\$out\""
out=$(bash "$SCRIPTS/setup-code.sh" issue 2>&1); rc=$?
check "issue succeeds" test "$rc" = 0
check "issue prints a code" grep -Eq '[A-HJ-NP-Z2-9]{5}(-[A-HJ-NP-Z2-9]{5}){3}' <<<"$out"
check "the state file holds no code" bash -c "! grep -Eq '[A-HJ-NP-Z2-9]{5}-[A-HJ-NP-Z2-9]{5}' '$HS_FIRST_RUN_FILE'"
check "status says a code is waiting" bash -c "bash '$SCRIPTS/setup-code.sh' status 2>&1 | grep -q 'waiting'"
check "boot prints a code and both addresses while pending" bash -c "out=\$(HS_SETUP_WAIT=1 HS_SETUP_ADDRS='192.168.1.50' bash '$SCRIPTS/setup-code.sh' boot 2>&1); grep -Eq '[A-HJ-NP-Z2-9]{5}(-[A-HJ-NP-Z2-9]{5}){3}' <<<\"\$out\" && grep -q '\.local:8480' <<<\"\$out\" && grep -q 'http://192.168.1.50:8480' <<<\"\$out\""
check "reset removes the flag" bash -c "bash '$SCRIPTS/setup-code.sh' reset && test ! -e '$HS_FIRST_RUN_FILE'"
echo "-- arm (the installer)"
bash "$SCRIPTS/setup-code.sh" arm
check "arm makes a pending flag without a code" bash -c "bash '$SCRIPTS/setup-code.sh' status 2>&1 | grep -q 'expired'"
check "boot then issues the first code" bash -c "HS_SETUP_WAIT=1 HS_SETUP_ADDRS='10.0.0.2' bash '$SCRIPTS/setup-code.sh' boot 2>&1 | grep -Eq '[A-HJ-NP-Z2-9]{5}(-[A-HJ-NP-Z2-9]{5}){3}'"
bash "$SCRIPTS/setup-code.sh" arm
check "arm never overwrites a flag that exists" bash -c "bash '$SCRIPTS/setup-code.sh' status 2>&1 | grep -q 'waiting'"
printf '%s' '{"state":"done","user":"adminuser","done":1}' > "$HS_FIRST_RUN_FILE"
check "boot after done prints nothing, not even on stderr" bash -c "out=\$(HS_SETUP_WAIT=1 HS_SETUP_ADDRS='' bash '$SCRIPTS/setup-code.sh' boot 2>&1); test -z \"\$out\""
echo "-- the boot unit"
check "both Nix configurations use the shared unit" bash -c "grep -q 'setup-code-unit.nix' '$ROOT/install.nix' && grep -q 'setup-code-unit.nix' '$ROOT/configuration.nix'"
check "the unit prints to the tty only" bash -c "grep -q 'StandardOutput = \"tty\"' '$ROOT/setup-code-unit.nix' && grep -q 'TTYPath = \"/dev/console\"' '$ROOT/setup-code-unit.nix' && ! grep -q '/etc/issue' '$ROOT/setup-code-unit.nix'"
finish
