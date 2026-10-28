#!/usr/bin/env bash
# The read cache of the web interface (scripts/web-serve.py Reads, Warmer): survives a restart, keeps every read without arguments and everything
# that was asked for warm, shows an old answer at once while a new one is read. `hs` is not called (the runner is replaced).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi
echo "-- read cache"
if out=$(python3 -I "$ROOT/tests/web-cache-test.py" 2>&1); then pass "read cache tests ($(grep -E '^Ran ' <<<"$out"))"; else fail "read cache: $(tail -n 25 <<<"$out")"; fi

echo "-- the pages' first reads are allowlisted reads (prefetch)"
if have node; then
  if o=$(node "$ROOT/tests/web-prefetch.mjs" 2>&1); then pass "prefetch paths ($(grep -E '^  -> ' <<<"$o"))"; else fail "prefetch: $(tail -n 12 <<<"$o")"; fi
else skip "node missing"; fi
finish
