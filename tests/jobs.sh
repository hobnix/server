#!/usr/bin/env bash
# hs job list|running|log|follow|stop and hs sys jobs list|running (scripts/jobs.sh), against fake
# systemctl and journalctl on PATH. No root needed.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 TZ=UTC
BIN=$WORK/bin; mkdir -p "$BIN"
export CALLS=$WORK/calls; : > "$CALLS"

cat > "$BIN/systemctl" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  list-timers)
    echo "Mon 2026-10-05 04:00:00 UTC 3h left Sun 2026-10-04 04:00:00 UTC 21h ago hs-backup.timer hs-backup.service"
    echo "Sat 2026-10-10 01:30:00 UTC 5 days left n/a n/a hs-selftest-short.timer hs-selftest-short.service"
    echo "Mon 2026-10-05 05:00:00 UTC 4h left Sun 2026-10-04 05:00:00 UTC 20h ago hs-health-check.timer hs-health-check.service"
    echo "Mon 2026-10-05 05:00:00 UTC 4h left n/a n/a fstrim.timer fstrim.service" ;;
  show)   # show <unit> -p <property> --value
    case "$2:$4" in
      hs-backup.timer:NextElapseUSecRealtime) echo "Mon 2026-10-05 04:00:00 UTC" ;;
      hs-backup.service:ExecMainExitTimestamp) echo "Sun 2026-10-04 04:00:00 UTC" ;;
      hs-backup.service:Result) echo success ;;
      hs-backup.service:ExecMainStatus) echo 0 ;;
      hs-backup.service:Description) echo "Nightly backup" ;;
      hs-backup.service:LoadState) echo loaded ;;
      hs-backup.service:ActiveState) echo inactive ;;
      hs-backup.service:ActiveEnterTimestamp) echo "Sun 2026-10-04 04:00:00 UTC" ;;
      hs-backup.service:ExecStart) echo "{ path=/run/current-system/sw/bin/hs ; argv[]=/run/current-system/sw/bin/hs backup now --scheduled ; ignore_errors=no ; start_time=[Sun 2026-10-04 04:00:00 UTC] }" ;;
      hs-selftest-short.timer:NextElapseUSecRealtime) echo "Sat 2026-10-10 01:30:00 UTC" ;;
      hs-selftest-short.service:ExecMainExitTimestamp) echo "n/a" ;;
      hs-selftest-short.service:Description) echo "Short self-tests" ;;
      hs-health-check.timer:NextElapseUSecRealtime) echo "Mon 2026-10-05 05:00:00 UTC" ;;
      hs-health-check.service:ExecMainExitTimestamp) echo "Sun 2026-10-04 05:00:00 UTC" ;;
      hs-health-check.service:Result) echo exit-code ;;
      hs-health-check.service:ExecMainStatus) echo 1 ;;
      hs-health-check.service:Description) echo "Health check" ;;
      hs-job-gc.service:Description) echo "Clean up old generations" ;;
      hs-job-live.service:ActiveState) echo active ;;
      hs-job-done.service:LoadState) echo loaded ;;
      hs-job-done.service:ActiveState) echo inactive ;;
      hs-job-done.service:Result) echo success ;;
      hs-job-done.service:ExecMainStatus) echo 0 ;;
      hs-job-bad.service:LoadState) echo loaded ;;
      hs-job-bad.service:ActiveState) echo failed ;;
      hs-job-bad.service:Result) echo exit-code ;;
      hs-job-bad.service:ExecMainStatus) echo 3 ;;
      hs-job-gc.service:ActiveEnterTimestamp) echo "Mon 2026-10-05 03:15:00 UTC" ;;
    esac ;;
  list-units) echo "hs-job-gc.service loaded active running Clean up old generations" ;;
  stop) echo "systemctl $*" >> "$CALLS" ;;
esac
FAKE
cat > "$BIN/journalctl" <<'FAKE'
#!/usr/bin/env bash
echo "journalctl $*" >> "$CALLS"
case "$*" in *"-o cat"*) printf 'one
two
three
'; exit 0 ;; esac
echo "journal line of $2"
FAKE
chmod +x "$BIN"/*
export PATH=$BIN:$PATH
J="bash $SCRIPTS/jobs.sh"

echo "-- list"
out=$($J --list)
check_eq "only the hs-* timers are listed" "3" "$(wc -l <<<"$out" | tr -d ' ')"
check_eq "a successful job" $'hs-backup.service\tNightly backup\t05.10. 04:00\t04.10. 04:00\tok' "$(grep '^hs-backup' <<<"$out")"
check_eq "a job that never ran" $'hs-selftest-short.service\tShort self-tests\t10.10. 01:30\t-\tnever' "$(grep '^hs-selftest' <<<"$out")"
check_out "a job that failed last time" "hs-health-check.service.*failed$" echo "$out"
check_eq "no argument on a pipe = the raw list" "$out" "$($J)"
check_out "--help prints the usage" "usage: hs job list" $J --help

echo "-- running"
check_eq "a running job: unit, description, since" $'hs-job-gc.service\tClean up old generations\t05.10. 03:15' "$($J --running)"

echo "-- log / follow / stop"
check_out "a unit name shows the last 40 lines" "journal line of hs-backup" $J hs-backup.service
check_eq "the journal call" "journalctl -u hs-backup.service -n 40 --no-pager" "$(tail -n1 "$CALLS")"
$J hs-job-gc.service --follow >/dev/null
check_eq "--follow follows" "journalctl -fu hs-job-gc.service -n 40 --no-pager -o short-iso" "$(tail -n1 "$CALLS")"
$J stop hs-job-gc.service
check_eq "stop stops the unit" "systemctl stop hs-job-gc.service" "$(tail -n1 "$CALLS")"
check_out "stop without a unit explains" "usage: hs job stop" $J stop
check_eq "stop without a unit fails" "1" "$($J stop >/dev/null 2>&1; echo $?)"

echo "-- through the registry (hs job ..., hs sys jobs ...)"
fake=$WORK/reg; mkdir -p "$fake/lib"
cp "$SCRIPTS"/lib/hs.sh "$SCRIPTS"/lib/capability.sh "$SCRIPTS"/lib/registry-load.sh "$SCRIPTS"/lib/ui.sh "$SCRIPTS"/lib/i18n.sh "$SCRIPTS"/lib/setting.sh "$SCRIPTS"/lib/job.sh "$fake/lib/"; cp -r "$SCRIPTS"/lib/i18n "$fake/lib/"
cp "$SCRIPTS/lib/registry.tsv" "$fake/lib/"; cp "$SCRIPTS/jobs.sh" "$fake/"
F="env HS_CALLER=t HS_COMPLETE_DIR=$WORK/complete bash $fake/lib/hs.sh"
check_eq "hs job list = the raw list on a pipe" "$out" "$($F job list)"
check_eq "hs job running" $'hs-job-gc.service\tClean up old generations\t05.10. 03:15' "$($F job running)"
check_out "hs job log <unit>" "journal line" $F job log hs-backup.service
$F job follow hs-job-gc.service >/dev/null
check_eq "hs job follow <unit>" "journalctl -fu hs-job-gc.service -n 40 --no-pager -o short-iso" "$(tail -n1 "$CALLS")"
$F job stop hs-job-gc.service
check_eq "hs job stop <unit>" "systemctl stop hs-job-gc.service" "$(tail -n1 "$CALLS")"
check_eq "hs sys jobs list" "$out" "$($F sys jobs list)"
check_eq "hs sys jobs running" $'hs-job-gc.service\tClean up old generations\t05.10. 03:15' "$($F sys jobs running)"
echo "-- show and log (the interface's job page)"
out=$($J --show hs-backup.service)
check_eq "a finished timer job: facts, the timer's next run, the command" "unit	hs-backup.service
description	Nightly backup
state	ok
exit	0
started	04.10. 04:00
last	04.10. 04:00
next	05.10. 04:00
command	/run/current-system/sw/bin/hs backup now --scheduled" "$out"
check_out "a job that never ran" "^state.never$" $J --show hs-selftest-short
check_out "a job that failed" "^state.failed$" $J --show hs-health-check.service
check_out "a failed job has its exit status" "^exit.1$" $J --show hs-health-check.service
check_out "a running job" "^state.running$" $J --show hs-job-live
check_eq "only hs-* units" "1" "$($J --show sshd.service >/dev/null 2>&1; echo $?)"
check_eq "no path tricks in a unit" "1" "$($J --show 'hs-x/../../y.service' >/dev/null 2>&1; echo $?)"
check_eq "--log: plain journal lines, the count is passed on" "journal line of hs-backup.service" "$($J --log hs-backup.service 50)"
check_eq "--log asks for N lines" "journalctl -u hs-backup.service -n 50 --no-pager -o short-iso" "$(tail -n1 "$CALLS")"
$J --log hs-backup >/dev/null
check_eq "--log defaults to 200 lines and adds .service" "journalctl -u hs-backup.service -n 200 --no-pager -o short-iso" "$(tail -n1 "$CALLS")"
check_eq "--log only for hs-* units" "1" "$($J --log sshd.service >/dev/null 2>&1; echo $?)"
check_eq "hs sys jobs show <unit>" "$($J --show hs-backup.service)" "$($F sys jobs show hs-backup.service)"
check_eq "hs sys jobs log <unit> [N]" "journal line of hs-backup.service" "$($F sys jobs log hs-backup.service 30)"

echo "-- tail (the interface's job view)"
out=$($J tail hs-job-live 0)
check_eq "a running job: state, all lines, the count to ask again with" "state	running
line	one
line	two
line	three
next	3" "$out"
out=$($J tail hs-job-live 2)
check_eq "only the lines after N" "state	running
line	three
next	3" "$out"
out=$($J tail hs-job-done 3)
check_eq "a finished job: state ok, exit status, nothing new" "state	ok
exit	0
next	3" "$out"
out=$($J tail hs-job-bad.service 0 | head -n 2)
check_eq "a failed job says so with its exit status" "state	failed
exit	3" "$out"

finish
