#!/usr/bin/env bash
# The pool names bulk/fast per code file may only go down (tests/pool-names-ratchet-test.py, baseline tests/pool-names-ratchet.tsv):
# the real tree passes, a fixture shows rising, new, lowered and removed files failing and --update fixing it.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
RT=$ROOT/tests/pool-names-ratchet-test.py
python3 "$RT" >/dev/null 2>&1; check_eq "real tree matches the baseline" 0 "$?"
FX=$WORK/fixture
BASE=$WORK/base.tsv
mkdir -p "$FX/scripts" "$FX/tests"
printf 'echo bulk fast\n' > "$FX/scripts/x.sh"
printf 'bulk\n' > "$FX/tests/ignored.sh"
python3 "$RT" --root "$FX" --baseline "$BASE" --update >/dev/null 2>&1
check_eq "baseline counts matches, skips tests/" "$(printf 'file\tcount\nscripts/x.sh\t2\n')" "$(cat "$BASE")"
python3 "$RT" --root "$FX" --baseline "$BASE" >/dev/null 2>&1; check_eq "fresh baseline passes" 0 "$?"
printf 'echo bulk fast bulk\n' > "$FX/scripts/x.sh"
out=$(python3 "$RT" --root "$FX" --baseline "$BASE" 2>&1); rc=$?
check_eq "rising count fails" 1 "$rc"
check_match "rising count names the file" 'scripts/x.sh: pool names 3 > 2' "$out"
printf 'echo bulk fast\n' > "$FX/scripts/x.sh"
printf 'fast\n' > "$FX/scripts/y.sh"
out=$(python3 "$RT" --root "$FX" --baseline "$BASE" 2>&1); rc=$?
check_eq "new file with a match fails" 1 "$rc"
check_match "new file is named" 'scripts/y.sh: pool names 1 > 0' "$out"
rm "$FX/scripts/y.sh"
printf 'echo bulk\n' > "$FX/scripts/x.sh"
out=$(python3 "$RT" --root "$FX" --baseline "$BASE" 2>&1); rc=$?
check_eq "lowered count fails" 1 "$rc"
check_match "lowered count gives the hint" 'scripts/x.sh: pool names 1 < 2: lower the number' "$out"
rm "$FX/scripts/x.sh"
out=$(python3 "$RT" --root "$FX" --baseline "$BASE" 2>&1); rc=$?
check_eq "removed file fails" 1 "$rc"
check_match "removed file asks to remove the row" 'scripts/x.sh: .*remove the row' "$out"
python3 "$RT" --root "$FX" --baseline "$BASE" --update >/dev/null 2>&1
python3 "$RT" --root "$FX" --baseline "$BASE" >/dev/null 2>&1; check_eq "after --update it passes" 0 "$?"
finish
