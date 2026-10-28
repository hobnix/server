#!/usr/bin/env bash
# hs sys system plan|start reboot|shutdown (scripts/system-change.sh), the part the web interface's Reboot / Shutdown buttons use.
# Stand-ins for power.sh and systemd-run: nothing is rebooted. No root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en
unset HS_CALLER HS_GUIDED_TTY
BIN=$WORK/bin; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/timercalls"\n' "$WORK" > "$BIN/systemd-run"; chmod +x "$BIN/systemd-run"
export PATH="$BIN:$PATH"
# power.sh stand-in: --dry-run says what is running when $WORK/busy exists (like the real one: exit 0, a warning and the reasons)
cat > "$WORK/power" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$(dirname "$0")/powercalls"
case " $* " in
  *" --dry-run "*)
    if [ -e "$(dirname "$0")/busy" ]; then
      echo "! This is still running:"
      echo "  background job hs-job-backup-now-0300 (hs job running)"
      echo "  hs-backup.service is running"
    fi
    echo "Dry run"
    echo "  Command  systemctl reboot" ;;
esac
FAKE
chmod +x "$WORK/power"
export HS_POWER=$WORK/power
run() { rc=0; out=$(timeout 20 bash "$SCRIPTS/system-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }

echo "-- plan"
for a in reboot shutdown; do
  run plan $a
  check_eq "$a plan: exit 0" 0 "$rc"
  has '^status	ok$' && has "^danger	" && has "^confirm_name	$a$" && has '^long	no$' && pass "$a: ok, red, confirm word '$a'" || fail "$a plan: $out"
  has 'LOCKED' && has 'web interface' && pass "$a: warns about the web UI and the locked storage" || fail "$a warn: $out"
  has "^command	bash .*power $a --yes$" && pass "$a: the command is power.sh $a --yes" || fail "$a command: $out"
done

echo "-- busy server"
: > "$WORK/busy"
run plan reboot
check_eq "busy: refused" 1 "$rc"
has '^status	refused$' && has '^reason	background job hs-job-backup-now' && has '^reason	hs-backup.service is running' && pass "busy: the reasons are listed" || fail "busy: $out"
rm -f "$WORK/busy"

echo "-- start"
: > "$WORK/timercalls"; : > "$WORK/powercalls"
run start reboot
check_eq "start without the word: refused" 1 "$rc"
has 'type the word to confirm: reboot' && pass "asks for the word" || fail "start no word: $out"
run start reboot --confirm shutdown
check_eq "the wrong word: refused" 1 "$rc"
check_eq "nothing scheduled yet" "" "$(cat "$WORK/timercalls")"
run start reboot --confirm reboot
check_eq "start: exit 0" 0 "$rc"
has '^status	started$' && has '^unit	hs-job-system-reboot-' && pass "started, with a unit" || fail "start: $out"
grep -q -- '--on-active=5' "$WORK/timercalls" && grep -q 'power reboot --yes' "$WORK/timercalls" && pass "a timer runs power.sh reboot --yes in 5 s" || fail "timer: $(cat "$WORK/timercalls")"
grep -q -- 'reboot --yes' "$WORK/powercalls" && fail "power.sh must not run before the timer" || pass "power.sh itself is not run in the foreground"
run start shutdown --confirm shutdown
has '^unit	hs-job-system-shutdown-' && grep -q 'power shutdown --yes' "$WORK/timercalls" && pass "shutdown is scheduled the same way" || fail "shutdown: $out"
: > "$WORK/busy"
run start reboot --confirm reboot
check_eq "start while busy: refused" 1 "$rc"
rm -f "$WORK/busy"

echo "-- the other actions are untouched"
run plan frobnicate
check_eq "unknown action" 1 "$rc"
run plan rollback
has '^confirm_name	rollback$' && pass "rollback still asks for its own word" || fail "rollback: $out"

finish
