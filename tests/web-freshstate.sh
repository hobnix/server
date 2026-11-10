#!/usr/bin/env bash
# The worst status of a page's reads for the top bar (web/src/freshstate.js), run with node.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! command -v node >/dev/null 2>&1; then skip "node is not installed"; finish; exit 0; fi
node "$SCRIPTS/../tests/web-freshstate.mjs" >/dev/null
rc=$?
check_eq "the fresh state tests pass" 0 "$rc"
finish
