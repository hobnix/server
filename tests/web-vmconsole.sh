#!/usr/bin/env bash
# Graphical VM console (scripts/web_vmconsole.py + the glue in scripts/web-serve.py, ADR 0021): the Incus VGA console against a fake Incus API,
# tickets, limits, the upgrade against the real server, the relay. No incus needed. NOT VERIFIED against a real VM.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi

echo "-- web vm console"
if out=$(python3 -I "$ROOT/tests/web-vmconsole-test.py" 2>&1); then pass "web vm console tests ($(grep -E '^Ran ' <<<"$out"))"; else fail "web vm console tests: $(tail -n 25 <<<"$out")"; fi
finish
