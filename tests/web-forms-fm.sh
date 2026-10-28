#!/usr/bin/env bash
# Web interface: the file manager (fm.sh): the READS and CHANGES entries in scripts/web-serve.py, the selection on stdin (the script itself: tests/fm.sh).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi

echo "-- web READS and CHANGES"
if out=$(python3 -I "$ROOT/tests/web-forms-fm-test.py" 2>&1); then pass "file manager allowlists ($(grep -E '^Ran ' <<<"$out"))"; else fail "file manager allowlists: $(tail -n 25 <<<"$out")"; fi

finish
