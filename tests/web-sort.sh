#!/usr/bin/env bash
# The sorting of the shared table (web/src/shell/sort.js) and the size parser, run with node.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! command -v node >/dev/null 2>&1; then skip "node is not installed"; finish; exit 0; fi
node "$SCRIPTS/../tests/web-sort.mjs"
rc=$?
check_eq "the sort tests pass" 0 "$rc"
finish
