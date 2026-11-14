#!/usr/bin/env bash
# The drill rows of the Backup page (web/src/pages/backup-drill.js), run with node.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! command -v node >/dev/null 2>&1; then skip "node is not installed"; finish; exit 0; fi
node "$SCRIPTS/../tests/web-backup-drill.mjs" >/dev/null
rc=$?
check_eq "the backup drill tests pass" 0 "$rc"
finish
