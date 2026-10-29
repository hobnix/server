#!/usr/bin/env bash
# The grouping, ordering and icons of the dashboard tiles (web/src/dashboard/board.js), run with node.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! command -v node >/dev/null 2>&1; then skip "node is not installed"; finish; exit 0; fi
node "$SCRIPTS/../tests/web-board.mjs"
rc=$?
check_eq "the dashboard tile tests pass" 0 "$rc"
finish
