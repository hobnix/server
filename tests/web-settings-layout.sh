#!/usr/bin/env bash
# The Settings subpages (web/src/settings/layout.gen.json, layout.js, the tree children in nav.js), run with node.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! command -v node >/dev/null 2>&1; then skip "node is not installed"; finish; exit 0; fi
KEYS=$(python3 "$SCRIPTS/schema-gen.py" list | cut -f1 | tr -d '\r' | tr '\n' ' ')
SETTABLE=$(python3 "$SCRIPTS/schema-gen.py" list | awk -F'\t' '$3 == "yes" {print $1}' | tr -d '\r' | tr '\n' ' ')
HS_KEYS="$KEYS" HS_SETTABLE="$SETTABLE" node "$SCRIPTS/../tests/web-settings-layout.mjs"
rc=$?
check_eq "the settings layout tests pass" 0 "$rc"
finish
