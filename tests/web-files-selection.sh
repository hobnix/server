#!/usr/bin/env bash
# The pure logic of the file manager (web/src/files/selection.js), run with node.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! command -v node >/dev/null 2>&1; then skip "node is not installed"; finish; exit 0; fi
node "$SCRIPTS/../tests/web-files-selection.mjs"
rc=$?
check_eq "the file manager selection tests pass" 0 "$rc"
finish
