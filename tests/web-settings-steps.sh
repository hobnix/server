#!/usr/bin/env bash
# The guided steps of a capability page (web/src/settings/steps.js), run with node.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! command -v node >/dev/null 2>&1; then skip "node is not installed"; finish; exit 0; fi
node "$SCRIPTS/../tests/web-settings-steps.mjs"
rc=$?
check_eq "the settings steps tests pass" 0 "$rc"
finish
