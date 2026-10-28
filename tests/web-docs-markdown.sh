#!/usr/bin/env bash
# The Markdown renderer of the web interface (web/src/docs/markdown.js), run with node: syntax of the guides, nothing unsafe, every guide renders.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! command -v node >/dev/null 2>&1; then skip "node is not installed"; finish; exit 0; fi
node "$SCRIPTS/../tests/web-docs-markdown.mjs"
rc=$?
check_eq "the renderer tests pass" 0 "$rc"
finish
