#!/usr/bin/env bash
# Web interface, Instances forms: the `ct` entries of CHANGES (scripts/web-serve.py) accept the shapes of the forms and nothing else.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi

echo "-- instance forms"
if out=$(python3 -I "$ROOT/tests/web-forms-instances-test.py" 2>&1); then pass "instance form tests ($(grep -E '^Ran ' <<<"$out"))"; else fail "instance form tests: $(tail -n 25 <<<"$out")"; fi
finish
