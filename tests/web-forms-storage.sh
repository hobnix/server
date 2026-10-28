#!/usr/bin/env bash
# Web interface, storage forms (scripts/web-serve.py, areas pool and disk of CHANGES): allowed and refused shapes, the passphrase on stdin only.
# The command behind disk is tested in tests/web-disk-change.sh. No root, no helpers needed (the run of `hs` is replaced).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi

echo "-- storage forms"
if out=$(python3 -I "$ROOT/tests/web-forms-storage-test.py" 2>&1); then pass "storage form tests ($(grep -E '^Ran ' <<<"$out"))"; else fail "storage form tests: $(tail -n 25 <<<"$out")"; fi

finish
