#!/usr/bin/env bash
# Raw input/select/textarea/own <style>/hex colours per file of web/src may only go down (tests/web-ratchet-test.py, baseline
# tests/web-ratchet.tsv): the real tree passes, a fixture shows rising, new and lowered counts failing and --update fixing it.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
RT=$ROOT/tests/web-ratchet-test.py
python3 "$RT" >/dev/null 2>&1; check_eq "real tree matches the baseline" 0 "$?"
FX=$WORK/fixture
BASE=$WORK/base.tsv
mkdir -p "$FX/ui" "$FX/pages"
printf '<input /><input />\n' > "$FX/pages/A.svelte"
python3 "$RT" --root "$FX" --baseline "$BASE" --update >/dev/null 2>&1
python3 "$RT" --root "$FX" --baseline "$BASE" >/dev/null 2>&1; check_eq "fresh baseline passes" 0 "$?"
printf '<input /><input /><input />\n' > "$FX/pages/A.svelte"
out=$(python3 "$RT" --root "$FX" --baseline "$BASE" 2>&1); rc=$?
check_eq "rising count fails" 1 "$rc"
check_match "rising count names the file" 'pages/A.svelte: input 3 > 2' "$out"
printf '<input /><input />\n' > "$FX/pages/A.svelte"
printf '<input />\n' > "$FX/pages/B.svelte"
out=$(python3 "$RT" --root "$FX" --baseline "$BASE" 2>&1); rc=$?
check_eq "new file with a raw input fails" 1 "$rc"
check_match "new file is named" 'pages/B.svelte: input 1 > 0' "$out"
rm "$FX/pages/B.svelte"
printf '<input />\n' > "$FX/pages/A.svelte"
out=$(python3 "$RT" --root "$FX" --baseline "$BASE" 2>&1); rc=$?
check_eq "lowered count fails" 1 "$rc"
check_match "lowered count gives the hint" 'input 1 < 2: lower the number' "$out"
python3 "$RT" --root "$FX" --baseline "$BASE" --update >/dev/null 2>&1
python3 "$RT" --root "$FX" --baseline "$BASE" >/dev/null 2>&1; check_eq "after --update it passes" 0 "$?"
finish
