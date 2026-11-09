#!/usr/bin/env bash
# help: stop a running job or start a scheduled one now, without asking anything: what would happen (plan), then do it (start)
# help.de: einen laufenden Auftrag stoppen oder einen geplanten sofort starten, ohne etwas zu fragen: was passieren würde (plan), dann ausführen (start)
# args: plan|start <stop|run> <unit> [--confirm stop]
# System command (hs sys jobs plan|start): for the interface, timers and tests. It never asks and prints plain key<TAB>value lines like
# backup-change.sh and system-change.sh. Only hs-* units.
#   stop <unit>   stop a job that runs now (systemctl stop). RED with the word `stop` typed when the job changes disks (a pool change, a parity sync or
#                 scrub, setting up the backup disk, removing a kept folder): stopping those half way can leave a half-done change behind.
#   run <unit>    start the service of a scheduled job now (the timer keeps its schedule); the unit it prints is followed in the progress view
#
# plan: exit 0 = allowed, 1 = refused. Output: status ok|refused, reason<TAB><text> | heading|step|note|warn|danger|command<TAB><line>,
#   confirm_name<TAB>stop (only with a danger line), long<TAB>yes|no.
# start: the same checks; stop = done at once (status done), run = the service is started (status started, unit). A danger line needs --confirm stop.
# Test knobs: HS_JOBS (stand-in for jobs.sh), HS_SYSTEMCTL.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/job.sh"   # hs_job_record
jobs=${HS_JOBS:-$here/jobs.sh}
systemctl=${HS_SYSTEMCTL:-systemctl}

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

verb=${1:-}; action=${2:-}; unit=${3:-}
case "$verb" in plan|start) ;; *) echo "usage: jobs-change.sh plan|start <stop|run> <unit>" >&2; exit 1 ;; esac
if [ "$action" = answer ]; then   # ADR 0018: the web interface answers a waiting recipe run (the answer is one line on stdin)
  shift 3 || true
  [ "$verb" = start ] || { printf 'status\tok\nheading\tanswer the question\nlong\tno\n'; exit 0; }
  exec bash "${HS_JOBS_ANSWER:-$here/jobs-answer.sh}" "$unit" "$@"
fi
case "$action" in stop|run) ;; *) refuse "unknown action (stop or run)" ;; esac
case "$unit" in *.service) ;; *) unit=$unit.service ;; esac
[[ "$unit" =~ ^hs-[A-Za-z0-9@._-]+\.service$ ]] || refuse "that is not a job of this server (hs-*)"
shift 3 || true
confirm=""
while [ $# -gt 0 ]; do
  case "$1" in
    --confirm) confirm=${2:-}; shift 2 ;;
    *) refuse "unknown option $1" ;;
  esac
done

facts=$(bash "$jobs" --show "$unit" 2>/dev/null || true)
fact() { awk -F'\t' -v k="$1" '$1 == k { print $2; exit }' <<<"$facts"; }
state=$(fact state)
desc=$(fact description); [ -n "$desc" ] || desc=$unit

danger=""; safe=yes; rec_id=""
who=${SUDO_USER:-${USER:-}}
case "$action" in
  stop)
    [ "$state" = running ] || refuse "$desc is not running."
    cmd=("$systemctl" stop "$unit")
    case "$unit" in
      hs-job-pool-*|hs-job-system-sync-*|hs-job-system-scrub-*|hs-bulk-sync.service|hs-bulk-scrub.service|hs-job-backup-init*|hs-job-share-purge-*)
        danger="Stopping '$desc' half way can leave a half-done change behind (a pool or disk in between, a parity out of date). Look at it afterwards."
        safe=no ;;
    esac
    # job record (docs/adr/0004-job-record.md): a unit without one (a timer service) stops exactly as before
    rec_id=$(hs_job_record find-unit "$unit" 2>/dev/null) || rec_id="" ;;
  run)
    [ "$state" != running ] || refuse "$desc is running already."
    [ "$state" != unknown ] || refuse "There is no job called '$unit'."
    # only the jobs of a timer: the list the Jobs tab shows
    bash "$jobs" --list 2>/dev/null | awk -F'\t' -v u="$unit" '$1 == u { f = 1 } END { exit !f }' || refuse "'$unit' is not a scheduled job (only the hs-* timers can be run now)."
    cmd=("$systemctl" start --no-block "$unit") ;;
esac

if [ "$verb" = start ]; then
  if [ -n "$danger" ] && [ "$confirm" != stop ]; then refuse "type the word to confirm: stop"; fi
  # the record says cancelled before the unit (and the wrapper that would write the end) is killed; best effort.
  # If the stop fails the job still runs: the record goes back (uncancel) and no event is written (#135).
  marked=""
  if [ "$action" = stop ] && [ -n "$rec_id" ]; then
    hs_job_record cancel "$rec_id" --by "$who" --safe "$safe" 2>/dev/null && marked=yes
  fi
  if ! "${cmd[@]}"; then
    [ -z "$marked" ] || hs_job_record uncancel "$rec_id" 2>/dev/null || true
    refuse "systemctl failed"
  fi
  if [ -n "$marked" ]; then   # event log (docs/adr/0005-events.md rule 9): best effort
    . "$here/lib/event.sh"; event_emit job.cancelled "$rec_id" "job stopped by ${who:-unknown}" || true
  fi
  if [ "$action" = stop ]; then printf 'status\tdone\n'; else printf 'status\tstarted\nunit\t%s\n' "$unit"; fi
  exit 0
fi

echo "status	ok"
case "$action" in
  stop)
    printf 'heading\tstop %s\n' "$desc"
    printf 'step\tstop the unit %s\n' "$unit"
    printf 'note\tWhat the job did already stays done.\n'
    [ -z "$rec_id" ] || printf 'note\tThe job record will say cancelled by %s\n' "${who:-unknown}"
    case "$unit" in
      hs-job-system-sync-*|hs-job-system-scrub-*|hs-bulk-sync.service|hs-bulk-scrub.service) printf 'note\tThe next scheduled run does the work again from where the data is now.\n' ;;
    esac ;;
  run)
    printf 'heading\trun %s now\n' "$desc"
    printf 'step\tstart %s at once; the timer keeps its schedule\n' "$unit"
    printf 'note\tThe unit follows its own conditions: it does nothing while the storage is locked.\n' ;;
esac
printf 'command\t%s\n' "${cmd[*]}"
if [ -n "$danger" ]; then printf 'danger\t%s\nconfirm_name\tstop\n' "$danger"; fi
case "$action" in run) printf 'long\tyes\n' ;; *) printf 'long\tno\n' ;; esac
exit 0
