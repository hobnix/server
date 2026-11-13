#!/usr/bin/env bash
# Live state on the state database (ADR 0026 step 1): DbStore, the live functions of state-db.py, the collector in db mode.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi
echo "-- live state on the state database"
if out=$(python3 -I "$ROOT/tests/live-db-test.py" 2>&1); then pass "live db tests ($(grep -E '^Ran ' <<<"$out"))"; else fail "live db: $(tail -n 25 <<<"$out")"; fi
finish
