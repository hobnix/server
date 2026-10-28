#!/usr/bin/env bash
# Web interface, share forms: the allowed and refused shapes of the `shares` changes in scripts/web-serve.py (add, perm, rename, delete, purge, restore).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi

echo "-- web share forms"
if out=$(python3 -I "$ROOT/tests/web-forms-shares-test.py" 2>&1); then pass "share form shapes ($(grep -E '^Ran ' <<<"$out"))"; else fail "share form shapes: $(tail -n 25 <<<"$out")"; fi
finish
