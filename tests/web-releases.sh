#!/usr/bin/env bash
# The Releases page of Settings (web/src/settings/releases.js, nav.js, routes.js, i18n.js), run with node.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! command -v node >/dev/null 2>&1; then skip "node is not installed"; finish; exit 0; fi
node "$SCRIPTS/../tests/web-releases.mjs"
rc=$?
check_eq "the releases page tests pass" 0 "$rc"
finish
