#!/usr/bin/env bash
# Web interface backend: GET /api/board (scripts/web-serve.py): variant web, dashboardOpen, private address, Host name, session, shape.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi

echo "-- web board"
if out=$(python3 -I "$ROOT/tests/web-board-test.py" 2>&1); then pass "board tests ($(grep -E '^Ran ' <<<"$out"))"; else fail "board tests: $(tail -n 25 <<<"$out")"; fi
finish
