#!/usr/bin/env bash
# A test that ran nothing (its summary says 0 ok and some skipped) counts as skipped in the final line of scripts/dev/t and
# tests/run-all.sh, and the skipped names are listed. ui.sh `table` also works without column(1).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

T=$WORK/tree
mkdir -p "$T/scripts/dev" "$T/tests"
cp "$ROOT/scripts/dev/t" "$T/scripts/dev/t"
cp "$ROOT/tests/run-all.sh" "$T/tests/run-all.sh"
printf '%s\n' '. /dev/null' 'echo "  ok    a"' 'echo "  -> 1 ok, 0 failed, 0 skipped"' > "$T/tests/good.sh"
printf '%s\n' 'echo "  skip  setfattr is not installed"' 'echo "  -> 0 ok, 0 failed, 1 skipped"' > "$T/tests/nothing.sh"
printf '%s\n' 'echo "  FAIL  x"' 'echo "  -> 0 ok, 1 failed, 0 skipped"; exit 1' > "$T/tests/bad.sh"

out=$(HS_T_LOG=$WORK/log bash "$T/scripts/dev/t" quick good nothing 2>&1)
check_eq "t: a test with 0 ok and a skip is counted as skipped, and named" "2 tests: 1 ok, 1 skipped (nothing), 0 failed" "$out"
out=$(HS_T_LOG=$WORK/log bash "$T/scripts/dev/t" quick good nothing bad 2>&1 | tail -n1)
check_eq "t: failed and skipped together" "3 tests: 1 ok, 1 skipped (nothing), 1 failed (bad)" "$out"

out=$(HS_T_LOG=$WORK/log bash "$T/scripts/dev/t" vm good 2>&1)
check_eq "t vm: a name that is not a VM test is refused" "good: not a VM test (zfs-vm rebuild-vm)" "$out"
printf '%s\n' 'echo "  ok    a"' 'echo "  -> 1 ok, 0 failed, 0 skipped"' > "$T/tests/zfs-vm.sh"
out=$(HS_T_LOG=$WORK/log bash "$T/scripts/dev/t" vm zfs-vm 2>&1)
check_eq "t vm: only the named VM test runs" "1 tests: 1 ok, 0 skipped, 0 failed" "$out"

out=$(bash "$T/tests/run-all.sh" --only good --only nothing 2>&1)
case "$out" in *"== 1 passed, 0 failed, 1 skipped"*"skipped: nothing"*) pass "run-all: the same, with the name listed" ;; *) fail "run-all: $out" ;; esac

# ui.sh table without column(1)
mkdir -p "$WORK/nocol"
for p in /usr/bin/* /bin/*; do [ "${p##*/}" = column ] || ln -sf "$p" "$WORK/nocol/${p##*/}" 2>/dev/null; done
got=$(PATH=$WORK/nocol HS_PLAIN=1 "$WORK/nocol/bash" -c ". '$ROOT/scripts/lib/ui.sh'; printf 'name\tsize\nab\t1\nlonger\t22\n' | table" 2>&1)
want=$(printf 'name    size\nab      1\nlonger  22')
check_eq "ui table: padded columns without column(1)" "$want" "$got"

finish
