#!/usr/bin/env bash
# The tree of a remote node from its capabilities and the helpers of the node pages (web/src/nav.js, web/src/pages/nodes/nodes.js), run with node.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! command -v node >/dev/null 2>&1; then skip "node is not installed"; finish; exit 0; fi
node "$SCRIPTS/../tests/web-nodes.mjs"
rc=$?
check_eq "the node tests pass" 0 "$rc"
finish
