#!/usr/bin/env bash
# The Events page logic (web/src/pages/events.js) and its wiring, run with node.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! command -v node >/dev/null 2>&1; then skip "node is not installed"; finish; exit 0; fi
node "$SCRIPTS/../tests/web-events.mjs"
rc=$?
check_eq "the events page tests pass" 0 "$rc"
check "event list is a read with source and after" grep -q '("event", "list"):.*"source".*"after"' "$SCRIPTS/web-serve.py"
finish
