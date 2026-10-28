#!/usr/bin/env bash
# hs sys disk plan|start <serial> forget (scripts/disk-change.sh): a MISSING disk leaves the inventory after a typed serial;
# a disk that is present or unknown is refused. A fake state.sh stands in: no database.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en
unset HS_CALLER HS_GUIDED_TTY
T=$'\t'
CALLS=$WORK/calls; : > "$CALLS"
cat > "$WORK/state.sh" <<FAKE
#!/usr/bin/env bash
case "\$1" in
  disks) printf 'SER-GONE${T}WD Red${T}4000${T}sdq${T}missing${T}data${T}-${T}1${T}2${T}-${T}-\nSER-HERE${T}WD Red${T}4000${T}sdb${T}ok${T}data${T}-${T}1${T}2${T}-${T}-\n' ;;
  forget) echo "\$*" >> "$CALLS" ;;
esac
FAKE
export HS_STATE_SH=$WORK/state.sh
run() { rc=0; out=$(timeout 20 bash "$SCRIPTS/disk-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }

run plan forget SER-GONE
check_eq "plan: exit 0" 0 "$rc"
has "^confirm_name${T}SER-GONE" && pass "plan names the serial to type" || fail "plan: $out"
has "^danger" && pass "plan is red" || fail "plan: $out"
run plan forget SER-HERE; check_eq "a present disk is refused" 1 "$rc"; has "only a missing disk" && pass "reason" || fail "$out"
run plan forget NOPE;     check_eq "an unknown serial is refused" 1 "$rc"
run plan forget SER-GONE --bogus; check_eq "an unknown option is refused" 1 "$rc"
run start forget SER-GONE; check_eq "no confirmation: refused" 1 "$rc"
run start forget SER-GONE --confirm SER-X; check_eq "wrong serial: refused" 1 "$rc"
[ ! -s "$CALLS" ] && pass "nothing was forgotten yet" || fail "calls: $(cat "$CALLS")"
run start forget SER-GONE --confirm SER-GONE; check_eq "right serial: exit 0" 0 "$rc"
has "^status${T}done" && pass "start says done" || fail "$out"
grep -qx "forget SER-GONE --yes" "$CALLS" && pass "state.sh forget was called" || fail "calls: $(cat "$CALLS")"
run start forget SER-HERE --confirm SER-HERE; check_eq "start repeats the checks (present)" 1 "$rc"
finish
