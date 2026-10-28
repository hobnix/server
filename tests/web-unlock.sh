#!/usr/bin/env bash
# Web interface: POST /api/unlock (scripts/web-serve.py) with a fake `hs sys unlock stdin`: no root, no disks.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi

echo "-- web unlock"
if out=$(python3 -I "$ROOT/tests/web-unlock-test.py" 2>&1); then pass "web unlock tests ($(grep -E '^Ran ' <<<"$out"))"; else fail "web unlock tests: $(tail -n 25 <<<"$out")"; fi
finish
