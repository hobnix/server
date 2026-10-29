#!/usr/bin/env bash
# Web interface, plan cache, cancel and timing lines (scripts/web-serve.py): same plan answered again, never for stdin or secrets, killed when the browser goes away.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi

echo "-- plan cache"
if out=$(python3 -I "$ROOT/tests/web-plan-cache-test.py" 2>&1); then pass "plan cache tests ($(grep -E '^Ran ' <<<"$out"))"; else fail "plan cache tests: $(tail -n 25 <<<"$out")"; fi

finish
