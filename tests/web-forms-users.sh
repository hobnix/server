#!/usr/bin/env bash
# Web interface: the user and group changes the browser may ask for (CHANGES["users"] in scripts/web-serve.py): allowed and refused shapes,
# the password only on standard input and never in an argument or a log line. Fake `hs`, no domain and no root needed.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi

echo "-- web user and group forms (backend)"
if out=$(python3 -I "$ROOT/tests/web-forms-users-test.py" 2>&1); then pass "web user forms tests ($(grep -E '^Ran ' <<<"$out"))"; else fail "web user forms tests: $(tail -n 25 <<<"$out")"; fi

finish
