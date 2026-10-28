#!/usr/bin/env bash
# Web interface: the SSH key change and read the browser may ask for (CHANGES["ssh-key"], READS in scripts/web-serve.py): allowed and refused shapes and
# injection attempts in the key argument. Fake `hs`, no root needed.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi

echo "-- web ssh-key (backend)"
if out=$(python3 -I "$ROOT/tests/web-ssh-key-test.py" 2>&1); then pass "web ssh-key tests ($(grep -E '^Ran ' <<<"$out"))"; else fail "web ssh-key tests: $(tail -n 25 <<<"$out")"; fi

finish
