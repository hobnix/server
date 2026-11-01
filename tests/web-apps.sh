#!/usr/bin/env bash
# The row button of the Apps page (web/src/pages/apps.js), run with node.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! command -v node >/dev/null 2>&1; then skip "node is not installed"; finish; exit 0; fi
node "$SCRIPTS/../tests/web-apps.mjs"
rc=$?
check_eq "the apps tests pass" 0 "$rc"
finish
