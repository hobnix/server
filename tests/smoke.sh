#!/usr/bin/env bash
# hs smoke: tools check and read-only probes, against a fake dispatcher and a PATH without the tools. No root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1
BIN=$WORK/bin; mkdir -p "$BIN"
for c in bash awk sed grep cut paste sort head tail cat basename dirname date timeout tr wc ls printf mktemp rm mkdir env uname cp mv sleep true false id hostname; do
  p=$(command -v "$c" 2>/dev/null) && ln -sf "$p" "$BIN/$c"
done
# a fake dispatcher: "ok" answers, "bad" prints a shell error, "fail" exits 1, "slow" hangs, "one" exits 1 which is allowed
cat > "$WORK/hs.sh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  help) echo "list" ;;
  good) echo "fine" ;;
  bad) echo "x.sh: line 3: foo: command not found" ;;
  broken) echo "oops"; exit 1 ;;
  slow) sleep 5 ;;
  one) echo "problems"; exit 1 ;;
esac
FAKE
printf '# kind\nuser\tgood\tx.sh\t-\th\th\t-\nuser\tbad\tx.sh\t-\th\th\t-\nuser\tbroken\tx.sh\t-\th\th\t-\nuser\tslow\tx.sh\t-\th\th\t-\nuser\tone\tx.sh\t-\th\th\t-\nuser\tshare <share> show\tx.sh\t-\th\th\t-\n' > "$WORK/registry.tsv"
printf 'a good one\tgood\t0\nthe shell error\tbad\t0\nexit code\tbroken\t0\nhangs\tslow\t0\nallowed 1\tone\t0 1\nnot allowed\tone\t0\nunknown\tnope\t0\nwith a value\tshare docs show\t0\n' > "$WORK/probes"
export HS_SMOKE_HS=$WORK/hs.sh HS_REGISTRY=$WORK/registry.tsv HS_SMOKE_PROBES=$WORK/probes HS_SMOKE_TIMEOUT=1
S="env PATH=$BIN bash $SCRIPTS/smoke.sh"

echo "-- probes"
out=$($S --no-run 2>&1; true)
check_out "--no-run runs no probe" "Programs the scripts need" echo "$out"
list=$(HS_SMOKE_TOOLS="" $S --list 2>&1 || true)
check_out "a good command is ok" "probe	a good one	ok" echo "$list"
check_out "a shell error is a failure even with exit code 0" "probe	the shell error	fail	.*command not found" echo "$list"
check_out "an exit code is a failure" "probe	exit code	fail	exit code 1" echo "$list"
check_out "a command that hangs is stopped" "probe	hangs	fail	no answer after 1 seconds" echo "$list"
check_out "an allowed exit code is fine" "probe	allowed 1	ok" echo "$list"
check_out "another one is not" "probe	not allowed	fail" echo "$list"
check_out "a command this version lacks is skipped" "probe	unknown	skip	no such command" echo "$list"
check_out "a <value> in the registry matches" "probe	with a value	ok" echo "$list"
check_eq "exit status 1 when something failed" "1" "$(HS_SMOKE_TOOLS="" $S >/dev/null 2>&1; echo $?)"
printf 'a good one\tgood\t0\n' > "$WORK/probes"
check_eq "exit status 0 when all is well" "0" "$(HS_SMOKE_TOOLS="" $S >/dev/null 2>&1; echo $?)"

echo "-- coverage: every read-only command has a probe (or a reason)"
REAL=$SCRIPTS/lib/registry.tsv
COV="bash $SCRIPTS/smoke.sh --coverage"
check_out "every reads row of the real registry is probed or skipped" "every reads row has a probe" env HS_REGISTRY=$REAL $COV
check_eq "and the exit status is 0" "0" "$(HS_REGISTRY=$REAL $COV >/dev/null 2>&1; echo $?)"
{ cat "$REAL"; printf 'user\tbrandnew thing\tx.sh\t-\th\th\ttopic:system,reads\nuser\tbrandnew other\tx.sh\t-\th\th\ttopic:system,changes\n'; } > "$WORK/reg-new.tsv"
check_out "a new reads row without probe is reported" "no probe and no skip entry: brandnew thing" env HS_REGISTRY=$WORK/reg-new.tsv $COV
check_eq "with exit status 1" "1" "$(HS_REGISTRY=$WORK/reg-new.tsv $COV >/dev/null 2>&1; echo $?)"
if HS_REGISTRY=$WORK/reg-new.tsv $COV 2>&1 | grep -q 'brandnew other'; then fail "a changes row needs no probe"; else pass "a changes row needs no probe"; fi
grep -av '^user	smoke	' "$REAL" > "$WORK/reg-nosmoke.tsv"
check_out "a skip entry for a row that is gone is reported" "stale skip entry .*: smoke" env HS_REGISTRY=$WORK/reg-nosmoke.tsv $COV
echo "-- programs"
tl=$(HS_SMOKE_TOOLS="smartctl restic" $S --no-run --list 2>&1 || true)
check_out "a missing program is named with the scripts that use it" "tool	smartctl	fail	not installed; used by: .*disk-health" echo "$tl"
ln -sf /bin/true "$BIN/smartctl"; ln -sf /bin/true "$BIN/restic"
tl=$(HS_SMOKE_TOOLS="smartctl restic" $S --no-run --list 2>&1 || true)
check_out "an installed program passes" "tool	all other programs	ok" echo "$tl"
check_out "no gum is only a hint" "tool	gum	skip" echo "$tl"
check_out "a wrong option is refused" "usage: hs smoke" $S --nope

finish
