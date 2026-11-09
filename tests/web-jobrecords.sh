#!/usr/bin/env bash
# The job record helpers of the Jobs panel (web/src/jobrecords.js), run with node.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! command -v node >/dev/null 2>&1; then skip "node is not installed"; finish; exit 0; fi
node "$SCRIPTS/../tests/web-jobrecords.mjs"
rc=$?
check_eq "the job records helper tests pass" 0 "$rc"
finish
