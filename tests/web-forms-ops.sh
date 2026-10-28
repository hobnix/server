#!/usr/bin/env bash
# Web interface: the ops forms (reboot / shutdown, wake a game PC, expiry entries): the CHANGES allowlist in scripts/web-serve.py and the
# scripts behind them (their own tests: web-system-reboot.sh, web-pc-change.sh, web-expiry-change.sh).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi

echo "-- web CHANGES"
if out=$(python3 -I "$ROOT/tests/web-forms-ops-test.py" 2>&1); then pass "ops forms allowlist ($(grep -E '^Ran ' <<<"$out"))"; else fail "ops forms allowlist: $(tail -n 25 <<<"$out")"; fi

finish
