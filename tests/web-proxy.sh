#!/usr/bin/env bash
# Web interface backend: GET /api/proxy/status (scripts/web-serve.py) against a fake VPS status document: ok, not json, too big, timeout, off, cache, session.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi

echo "-- web proxy status"
if out=$(python3 -I "$ROOT/tests/web-proxy-test.py" 2>&1); then pass "proxy status tests ($(grep -E '^Ran ' <<<"$out"))"; else fail "proxy status tests: $(tail -n 25 <<<"$out")"; fi

echo "-- proxyserver tree dots and routes"
if have node; then
  if out=$(node "$ROOT/tests/web-proxy-status.mjs" 2>&1); then pass "tree dots from the status document, one path per row"; else fail "proxy tree dots: $(tail -n 15 <<<"$out")"; fi
else skip "node missing"; fi
finish
