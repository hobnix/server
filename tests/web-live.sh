#!/usr/bin/env bash
# Live state of the web interface (scripts/web-serve.py StateStore): mode off answers as before, `_sys` goes through app.store.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi
echo "-- live state (store interface, modes off and redis with a fake Redis, /api/events)"
if out=$(python3 -I "$ROOT/tests/web-live-test.py" 2>&1); then pass "live state tests ($(grep -E '^Ran ' <<<"$out"))"; else fail "live state: $(tail -n 25 <<<"$out")"; fi
if have node; then
  if o=$(node "$ROOT/tests/web-live.mjs" 2>&1); then pass "poll timing ($(grep -E '^  -> ' <<<"$o"))"; else fail "poll timing: $(tail -n 12 <<<"$o")"; fi
else skip "node missing"; fi
finish
