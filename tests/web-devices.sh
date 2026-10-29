#!/usr/bin/env bash
# The hardware passthrough helpers of the Instances page (web/src/pages/instances/devices.js), run with node.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! command -v node >/dev/null 2>&1; then skip "node is not installed"; finish; exit 0; fi
node "$SCRIPTS/../tests/web-devices.mjs"
rc=$?
check_eq "the device tests pass" 0 "$rc"
finish
