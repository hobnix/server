#!/usr/bin/env bash
# The recipe wizard logic (web/src/forms/ops/recipeSteps.js) with node; the Svelte dialog itself is not run here.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! command -v node >/dev/null 2>&1; then skip "node is not installed"; finish; exit 0; fi
node "$ROOT/tests/web-recipe-wizard.mjs"
rc=$?
check_eq "the recipe wizard tests pass" 0 "$rc"
finish
