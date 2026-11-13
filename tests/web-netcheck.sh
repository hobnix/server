#!/usr/bin/env bash
# The Network step logic (web/src/wizard/netcheck.js) with node; the Svelte dialog itself is not run here.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! command -v node >/dev/null 2>&1; then skip "node is not installed"; finish; exit 0; fi
node "$ROOT/tests/web-netcheck.mjs"
rc=$?
check_eq "the network step tests pass" 0 "$rc"
finish
