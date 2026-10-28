#!/usr/bin/env bash
# Tooltips: no native title= attribute on a plain html element in web/src (web/src/ui/tooltip.svelte.js is the one tooltip), run with node.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! command -v node >/dev/null 2>&1; then skip "node is not installed"; finish; exit 0; fi
out=$(node "$SCRIPTS/../tests/web-tips.mjs" 2>&1)
rc=$?
check_eq "no plain element has a title= attribute (use:tip instead)" 0 "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$out"
finish
