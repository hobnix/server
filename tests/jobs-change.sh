#!/usr/bin/env bash
# hs sys jobs plan|start (scripts/jobs-change.sh): stopping a running job and running a scheduled one now. Fake jobs.sh and systemctl: no root, no systemd.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en
unset HS_CALLER HS_GUIDED_TTY
cat > "$WORK/jobs" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
  "--show hs-job-system-sync-bulk-0300.service") printf 'unit\t%s\ndescription\tUpdate the parity\nstate\trunning\n' "$2" ;;
  "--show hs-job-pool-bulk-replace-0310.service") printf 'unit\t%s\ndescription\tReplace a disk\nstate\trunning\n' "$2" ;;
  "--show hs-job-gc-0320.service") printf 'unit\t%s\ndescription\tClean up old generations\nstate\trunning\n' "$2" ;;
  "--show hs-backup.service") printf 'unit\t%s\ndescription\tNightly backup\nstate\tok\nexit\t0\n' "$2" ;;
  "--show hs-selftest-short.service") printf 'unit\t%s\ndescription\tShort self-tests\nstate\tnever\n' "$2" ;;
  "--show hs-health-check.service") printf 'unit\t%s\ndescription\tHealth check\nstate\trunning\n' "$2" ;;
  "--show hs-gone.service") printf 'unit\t%s\nstate\tunknown\n' "$2" ;;
  "--show hs-job-old.service") printf 'unit\t%s\ndescription\tAn old job\nstate\tok\n' "$2" ;;
  "--list "*|"--list ") printf 'hs-backup.service\tNightly backup\t05.10. 04:00\t04.10. 04:00\tok\nhs-selftest-short.service\tShort self-tests\t10.10. 01:30\t-\tnever\nhs-health-check.service\tHealth check\t05.10. 05:00\t-\tok\n' ;;
esac
FAKE
cat > "$WORK/systemctl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/sysctl-calls"
FAKE
chmod +x "$WORK/jobs" "$WORK/systemctl"
export HS_JOBS=$WORK/jobs HS_SYSTEMCTL=$WORK/systemctl
run() { rc=0; out=$(timeout 20 bash "$SCRIPTS/jobs-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }
T=$'\t'

echo "-- stopping"
run plan stop hs-job-gc-0320
check_eq "stop a plain job: exit 0" 0 "$rc"
has "^heading${T}stop Clean up old generations$" && has "^command${T}.*systemctl stop hs-job-gc-0320.service$" && has "^note${T}What the job did already stays done" && has "^long${T}no$" && pass "stop: heading, command, note, short" || fail "stop: $out"
has "^danger\|^confirm_name" && fail "a plain job is not red" || pass "a plain job is not red"
run plan stop hs-job-system-sync-bulk-0300.service
has "^danger${T}Stopping 'Update the parity' half way" && has "^confirm_name${T}stop$" && has "next scheduled run does the work again" && pass "a parity sync is red, the word is stop" || fail "sync: $out"
run plan stop hs-job-pool-bulk-replace-0310
has "^danger${T}" && has "^confirm_name${T}stop$" && pass "a pool change is red" || fail "pool: $out"
run plan stop hs-backup
check_eq "a job that does not run cannot be stopped" 1 "$rc"
has "is not running" && pass "says why" || fail "not running: $out"
run plan stop hs-gone
check_eq "an unknown job" 1 "$rc"
run plan stop sshd
check_eq "only hs-* units" 1 "$rc"
run plan stop 'hs-x/../y'
check_eq "no path tricks" 1 "$rc"
rm -f "$WORK/sysctl-calls"
run start stop hs-job-gc-0320
check_eq "start stop: exit 0" 0 "$rc"
check_eq "stop is done at once" "status${T}done" "$out"
check_eq "systemctl stop was called" "stop hs-job-gc-0320.service" "$(cat "$WORK/sysctl-calls")"
rm -f "$WORK/sysctl-calls"
run start stop hs-job-system-sync-bulk-0300
check_eq "a red stop without the word is refused" 1 "$rc"
[ ! -e "$WORK/sysctl-calls" ] && pass "nothing was stopped" || fail "systemctl was called"
run start stop hs-job-system-sync-bulk-0300 --confirm nope
check_eq "the wrong word is refused" 1 "$rc"
run start stop hs-job-system-sync-bulk-0300 --confirm stop
check_eq "the word stops it" 0 "$rc"
check_eq "systemctl stop of the sync" "stop hs-job-system-sync-bulk-0300.service" "$(cat "$WORK/sysctl-calls")"

echo "-- running a scheduled job now"
run plan run hs-selftest-short
check_eq "run: exit 0" 0 "$rc"
has "^heading${T}run Short self-tests now$" && has "^command${T}.*systemctl start --no-block hs-selftest-short.service$" && has "^long${T}yes$" && has "timer keeps its schedule" && pass "run: heading, command, long, the timer stays" || fail "run: $out"
has "^danger" && fail "run is not red" || pass "run is not red"
run plan run hs-health-check
check_eq "a job that runs already" 1 "$rc"
has "running already" && pass "says so" || fail "running already: $out"
run plan run hs-job-old
check_eq "a job without a timer is not run again" 1 "$rc"
has "not a scheduled job" && pass "says so" || fail "no timer: $out"
run plan run hs-gone
check_eq "an unknown job" 1 "$rc"
rm -f "$WORK/sysctl-calls"
run start run hs-backup.service
check_eq "start run: exit 0" 0 "$rc"
check_eq "start run prints the unit to follow" "status${T}started
unit${T}hs-backup.service" "$out"
check_eq "systemctl start --no-block" "start --no-block hs-backup.service" "$(cat "$WORK/sysctl-calls")"

echo "-- the usual refusals"
run plan fly hs-backup
check_eq "an unknown action" 1 "$rc"
run plan stop hs-job-gc-0320 --bogus
check_eq "an unknown option" 1 "$rc"

finish
