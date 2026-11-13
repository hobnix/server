#!/usr/bin/env bash
# The first-run wizard steps (web/src/setup/steps.js), run with node.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! command -v node >/dev/null 2>&1; then skip "node is not installed"; finish; exit 0; fi
node "$SCRIPTS/../tests/web-first-run-steps.mjs"
rc=$?
check_eq "the first-run steps tests pass" 0 "$rc"
finish
