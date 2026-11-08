#!/usr/bin/env bash
# scripts/lib/answers.py and scripts/answers.sh: the answers file check. No root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi
echo "-- answers file"
if out=$(python3 -I "$ROOT/tests/answers-test.py" 2>&1); then pass "answers file tests ($(grep -E '^Ran ' <<<"$out"))"; else fail "answers file tests: $(tail -n 25 <<<"$out")"; fi
finish
