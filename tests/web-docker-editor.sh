#!/usr/bin/env bash
# The compose editor logic (web/src/editor/*.js, no CodeMirror): envmask, schema, yamlpath, lint, envlang; run with node.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! command -v node >/dev/null 2>&1; then skip "node is not installed"; finish; exit 0; fi
node "$SCRIPTS/../tests/web-docker-editor.mjs"
rc=$?
check_eq "the docker editor tests pass" 0 "$rc"
finish
