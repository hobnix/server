#!/usr/bin/env bash
# Form field components (web/src/ui Field, TextInput, Select, Textarea, Checkbox, fieldaria.js): aria helpers and the static contract, run with node.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! command -v node >/dev/null 2>&1; then skip "node is not installed"; finish; exit 0; fi
out=$(node "$SCRIPTS/../tests/web-formfields.mjs" 2>&1)
rc=$?
check_eq "form field components keep their aria and markup contract" 0 "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$out"
finish
