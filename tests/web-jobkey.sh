#!/usr/bin/env bash
# The key that ties a running job to the button that started it (web/src/jobkey.js), run with node.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! command -v node >/dev/null 2>&1; then skip "node is not installed"; finish; exit 0; fi
node "$SCRIPTS/../tests/web-jobkey.mjs"
rc=$?
check_eq "the job key tests pass" 0 "$rc"
finish
