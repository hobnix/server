#!/usr/bin/env bash
# Live state: RESP client, collector, `hs sys live` output shapes, live_refresh without a socket.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi
echo "-- live state (collector, hs sys live)"
if out=$(python3 -I "$ROOT/tests/live-state-test.py" 2>&1); then pass "live state tests ($(grep -E '^Ran ' <<<"$out"))"; else fail "live state: $(tail -n 25 <<<"$out")"; fi
# live_refresh with no socket: exit 0, no output
out=$(HS_LIVE_SOCKET=/nonexistent/none.sock bash -c ". '$ROOT/scripts/lib/live.sh'; live_refresh --all" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass "live_refresh without a socket: silent, exit 0"; else fail "live_refresh without a socket: rc=$rc out=$out"; fi
finish
