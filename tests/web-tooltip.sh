#!/usr/bin/env bash
# Tooltip placement (web/src/ui/tooltip-place.js), run with node.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! command -v node >/dev/null 2>&1; then skip "node is not installed"; finish; exit 0; fi
node "$SCRIPTS/../tests/web-tooltip.mjs" >/dev/null
rc=$?
check_eq "the tooltip placement tests pass" 0 "$rc"
finish
