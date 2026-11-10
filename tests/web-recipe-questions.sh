#!/usr/bin/env bash
# The question dialog logic of an interactive recipe run (web/src/forms/ops/recipeQuestions.js) with node; the Svelte dialog itself is not run here.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! command -v node >/dev/null 2>&1; then skip "node is not installed"; finish; exit 0; fi
node "$ROOT/tests/web-recipe-questions.mjs"
rc=$?
check_eq "the recipe question tests pass" 0 "$rc"
finish
