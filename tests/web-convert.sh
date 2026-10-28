#!/usr/bin/env bash
# Web interface, pool convert and ct update-all (scripts/web-serve.py, CHANGES): allowed and refused shapes, the passphrase on stdin only.
# The commands behind them are tested in tests/ct-change.sh (update-all) and tests/pool-change.sh. No root, no helpers needed (the run of `hs` is replaced).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi

echo "-- convert and update-all"
if out=$(python3 -I "$ROOT/tests/web-convert-test.py" 2>&1); then pass "convert and update-all tests ($(grep -E '^Ran ' <<<"$out"))"; else fail "convert and update-all tests: $(tail -n 25 <<<"$out")"; fi

finish
