#!/usr/bin/env bash
# The node addresses (/node/<name>/...) and the redirect table of the web interface (web/src/redirects.js), run with node.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! command -v node >/dev/null 2>&1; then skip "node is not installed"; finish; exit 0; fi
node "$SCRIPTS/../tests/web-routes.mjs"
rc=$?
check_eq "the route tests pass" 0 "$rc"
finish
