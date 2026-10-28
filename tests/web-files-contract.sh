#!/usr/bin/env bash
# The contract between the file manager backend (scripts/fm.sh, real outputs in tests/fixtures/fm) and the page (web/src/files/api.js): the fixtures go through the
# web server's own parsing (scripts/web-serve.py) and then through the page's parsers. Refresh the fixtures with tests/fixtures/fm/capture.sh.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! command -v node >/dev/null 2>&1; then skip "node is not installed"; finish; exit 0; fi
if ! have python3; then skip "python3 missing"; finish; exit 0; fi
python3 -I "$ROOT/tests/web-files-contract-build.py" "$ROOT/tests/fixtures/fm" "$WORK/bundle.json" || { fail "building the bundle"; finish; exit 1; }
FM_BUNDLE=$WORK/bundle.json node "$ROOT/tests/web-files-contract.mjs"
check_eq "the file manager contract test passes" 0 "$?"
finish
