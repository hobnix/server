#!/usr/bin/env bash
# scripts/dev/web-inventory.py counts shared components vs raw markup per folder: a tiny fixture with known numbers, and the real tree runs.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
INV=$ROOT/scripts/dev/web-inventory.py
FX=$WORK/fixture
mkdir -p "$FX/ui" "$FX/pages"
cat > "$FX/ui/Button.svelte" <<'X'
<button class="btn"><slot /></button>
X
cat > "$FX/ui/index.js" <<'X'
export { default as Button } from './Button.svelte';
X
cat > "$FX/pages/P.svelte" <<'X'
<Button>go</Button>
<input class="card" />
<select class="card"></select>
<button>raw</button>
<!-- <input> in a comment -->
<style>
  .card { color: #abc; background: url(#ffffff); }
</style>
X
tsv=$(python3 "$INV" --root "$FX" --tsv 2>&1)
# columns: folder files ui_uses input select textarea button style style_lines hex ui:Button
check_eq "pages row counts" "pages	1	1	1	1	0	1	1	1	1	1" "$(printf '%s\n' "$tsv" | grep '^pages')"
check_eq "outside ui row counts" "outside ui	1	1	1	1	0	1	1	1	1	1" "$(printf '%s\n' "$tsv" | grep '^outside ui')"
check_eq "ui row counts raw button" "ui	1	0	0	0	0	1	0	0	0	0" "$(printf '%s\n' "$tsv" | grep '^ui')"
check_out "classes lists card" '^2	card$' python3 "$INV" --root "$FX" --classes
python3 "$INV" >/dev/null 2>&1; check_eq "real tree runs" 0 "$?"
check_out "real tree classes contain card" '[0-9]+	card$' python3 "$INV" --classes
finish
