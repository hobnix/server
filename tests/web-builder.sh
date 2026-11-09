#!/usr/bin/env bash
# The form model of the package builder (web/src/pages/builder.js) and the web allowlist for `pkg check-draft`, run with node and python.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! command -v node >/dev/null 2>&1; then skip "node is not installed"; finish; exit 0; fi
node "$SCRIPTS/../tests/web-builder.mjs"
check_eq "the form model tests pass" 0 "$?"
python3 -I "$SCRIPTS/../tests/web-builder-test.py"
check_eq "the allowlist tests pass" 0 "$?"
finish
