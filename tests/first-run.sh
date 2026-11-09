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
out=$(bash "$SCRIPTS/setup-code.sh" issue 2>&1); rc=$?
check "issue succeeds" test "$rc" = 0
check "issue prints a code" grep -Eq '[A-HJ-NP-Z2-9]{5}(-[A-HJ-NP-Z2-9]{5}){3}' <<<"$out"
check "the state file holds no code" bash -c "! grep -Eq '[A-HJ-NP-Z2-9]{5}-[A-HJ-NP-Z2-9]{5}' '$HS_FIRST_RUN_FILE'"
check "status says a code is waiting" bash -c "bash '$SCRIPTS/setup-code.sh' status 2>&1 | grep -q 'waiting'"
check "reset removes the flag" bash -c "bash '$SCRIPTS/setup-code.sh' reset && test ! -e '$HS_FIRST_RUN_FILE'"
finish
