# shellcheck shell=bash
# Background jobs: a long command runs as a transient systemd unit (hs-job-<slug>-<HHMM>).
# Sourced by hs.sh and by wizards that ask first and run the last step as a job.
#   hs_job <slug> <description> -- <command...>     starts it, prints the unit name
# HS_CALLER=job tells the script it was started this way (no questions). The unit notifies on
# failure (hs-notify-failure@) and on success (notify.sh). Look: hs job running, hs job log <unit>.
# hs_job_record ARGS...: the job record writer (docs/adr/0004-job-record.md). The Rust binary (hobnix job-record, HOBNIX_BIN or on PATH) does it
# unless HS_JOB_RECORD=python, there is no binary or it does not know `job-record --probe`; then scripts/job-record.py does, exactly as before. Same words, same output, same exit codes.
_hs_job_record_write() {
  # Decided once per shell: the binary must answer `job-record --probe`, an older build (after a git pull before the rebuild, or a rollback)
  # does not, and then the Python program writes the record as before.
  if [ -z "${_HS_JOB_RECORD_USE:-}" ]; then
    _HS_JOB_RECORD_USE=python
    if [ "${HS_JOB_RECORD:-}" != python ] && command -v "${HOBNIX_BIN:-hobnix}" >/dev/null 2>&1        && "${HOBNIX_BIN:-hobnix}" job-record --probe >/dev/null 2>&1; then _HS_JOB_RECORD_USE=rust; fi
  fi
  if [ "$_HS_JOB_RECORD_USE" = rust ]; then
    "${HOBNIX_BIN:-hobnix}" job-record "$@"
  else
    python3 "${BASH_SOURCE[0]%/*}/../job-record.py" "$@"
  fi
}

# hs_job_record: the writer above plus the event log (docs/adr/0005-events.md rule 9): a transition writes job.<state> with the job id as
# subject, once it is in the record. One place for both writers. Best effort: a failed emit never changes the exit code or the output.
# finish on a record that ended already (cancelled stays cancelled) emits nothing; cancel emits nothing here (jobs-change.sh emits job.cancelled after the stop worked).
hs_job_record() {
  local cmd=${1:-} out rc=0 id=${2:-} line text
  case "$cmd" in
    new|run|wait|resume|finish|reconcile|uncancel) ;;
    error)   # ADR 0018: only the Python writer knows it; an older or newer Rust binary that does not falls back
      _hs_job_record_write "$@" && return
      python3 "${BASH_SOURCE[0]%/*}/../job-record.py" "$@"; return ;;
    *) _hs_job_record_write "$@"; return ;;
  esac
  if [ "$cmd" = finish ] && ! _hs_job_record_write get "$id" 2>/dev/null | grep -Eq '"state": *"(queued|running|waiting)"'; then
    _hs_job_record_write "$@"; return   # already ended (a cancel stays cancelled): no second event
  fi
  out=$(_hs_job_record_write "$@") || rc=$?
  if [ "$rc" -ne 0 ] && [ "$cmd" = uncancel ] && [ "$_HS_JOB_RECORD_USE" = rust ]; then   # an older binary does not know it: the Python writer does
    out=$(python3 "${BASH_SOURCE[0]%/*}/../job-record.py" "$@") && rc=0
  fi
  [ -z "$out" ] || printf '%s
' "$out"
  [ "$rc" -eq 0 ] || return "$rc"
  # shellcheck source=scripts/lib/event.sh
  . "${BASH_SOURCE[0]%/*}/event.sh" 2>/dev/null || return 0
  case "$cmd" in
    new)  event_emit job.queued "$out" "job queued" || true ;;
    run)  event_emit job.running "$id" "job started" || true ;;
    wait)   # ADR 0018: the payload names the question key and its kind, never a label, a default or an answer
      local key="" qkind="" prev=""
      for line in "${@:3}"; do
        case "$prev" in --key) key=$line ;; --kind) qkind=$line ;; esac
        prev=$line
      done
      event_emit job.waiting "$id" "job waits for input" --payload "$(printf '{"key":"%s","kind":"%s"}' "${key//[^A-Za-z0-9._-]/}" "${qkind//[^a-z]/}")" || true ;;
    resume) event_emit job.resumed "$id" "job got its answer" || true ;;
    finish)
      if [ "${3:-1}" = 0 ]; then event_emit job.ok "$id" "job finished" || true
      else event_emit job.failed "$id" "job failed (exit ${3:-1})" --payload "{\"exit\":${3:-1}}" || true; fi ;;
    reconcile)
      while IFS=$'	' read -r line _ text; do
        [ -z "$line" ] || event_emit job.interrupted "$line" "${text:-job} did not finish" || true
      done <<<"$out" ;;
    uncancel) ;;
  esac
  return 0
}

hs_job() {
  local slug=$1 desc=$2 unit here
  shift 3   # slug, description, --
  slug=$(printf '%s' "$slug" | tr -c 'A-Za-z0-9' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//')   # a row path such as pool-<pool>-sync is no unit name
  here=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
  unit=hs-job-$slug-$(date +%H%M%S)
  local extra=() kv
  local rec_extra=()   # HS_JOB_PARENT / HS_JOB_KIND (ADR 0018): a sub-job names its orchestration; only the caller that sets them gets them
  [ -z "${HS_JOB_PARENT:-}" ] || rec_extra+=(--parent "$HS_JOB_PARENT")
  [ -z "${HS_JOB_KIND:-}" ] || rec_extra+=(--kind "$HS_JOB_KIND")
  # HS_JOB_ENV: more environment for the job, one KEY=VALUE per line (recipe answers; a secret is never put here, it travels as a file)
  while IFS= read -r kv; do [[ "$kv" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && extra+=(-E "$kv"); done <<<"${HS_JOB_ENV:-}"
  [ -z "${HS_DISK_PASSPHRASE_FILE:-}" ] || extra=(-E "HS_DISK_PASSPHRASE_FILE=$HS_DISK_PASSPHRASE_FILE")   # a path, not the secret
  # job record (docs/adr/0004-job-record.md): best effort, the job runs without one
  local src=cli jid=
  case "${HS_CALLER:-}" in web|ui) src=web ;; ext) src=extension ;; timer) src=timer ;; esac
  jid=$(hs_job_record new --slug "$slug" --desc "$desc" --unit "$unit" --source "$src" \
          --initiator "${HS_JOB_INITIATOR:-${SUDO_USER:-${USER:-}}}" ${rec_extra[@]+"${rec_extra[@]}"} 2>/dev/null) || jid=
  [ -z "$jid" ] || extra+=(-E "HS_JOB_ID=$jid")
  HS_JOB_LAST_ID=$jid   # for a caller that runs hs_job in its own shell (the orchestrator follows its sub-job by it)
  [ -z "${HS_JOBS_DIR:-}" ] || extra+=(-E "HS_JOBS_DIR=$HS_JOBS_DIR")   # the unit writes to the same directory as hs_job
  [ -z "${HS_ASK_DIR:-}" ] || extra+=(-E "HS_ASK_DIR=$HS_ASK_DIR")   # the question folder of an orchestration (a path; ADR 0018)
  [ -z "${HS_RUN_DIR:-}" ] || extra+=(-E "HS_RUN_DIR=$HS_RUN_DIR")
  [ -z "${HS_ASK_TIMEOUT:-}" ] || extra+=(-E "HS_ASK_TIMEOUT=$HS_ASK_TIMEOUT")
  [ -z "${HOBNIX_BIN:-}" ] || extra+=(-E "HOBNIX_BIN=$HOBNIX_BIN")   # and with the same job record writer
  [ -z "${HS_JOB_RECORD:-}" ] || extra+=(-E "HS_JOB_RECORD=$HS_JOB_RECORD")
  systemd-run --quiet --unit="$unit" --description="$desc" \
    --property="OnFailure=hs-notify-failure@$unit.service" \
    -E HS_CALLER=job -E "HS_JOB_UNIT=$unit" -E "HS_LANG=${hs_lang:-en}" -E "PATH=$PATH" ${extra[@]+"${extra[@]}"} \
    bash -c 'd=$1; shift   # $0 = scripts dir, $1 = description, the rest = the command
             . "$0/lib/job.sh"   # hs_job_record
             [ -z "${HS_JOB_ID:-}" ] || hs_job_record run "$HS_JOB_ID" 2>/dev/null || true
             "$@"; rc=$?
             [ -z "${HS_JOB_ID:-}" ] || hs_job_record finish "$HS_JOB_ID" "$rc" 2>/dev/null || true
             if [ "$rc" -ne 0 ] && [ -z "${HS_JOB_ID:-}" ]; then   # event log (docs/adr/0005-events.md): without a record nobody else writes job.failed; best effort
               . "$0/lib/event.sh"; event_emit job.failed "${HS_JOB_UNIT:-job}" "$d failed (exit $rc)" --payload "{\"exit\":$rc}" || true
             fi
             bash "$0/live.sh" refresh --all >/dev/null 2>&1 || true   # live state: read again (no-op without the capability)
             [ "$rc" -ne 0 ] || bash "$0/notify.sh" --category ok hs "$d finished" >/dev/null 2>&1
             exit "$rc"' "$here" "$desc" "$@" || {
    [ -z "$jid" ] || hs_job_record finish "$jid" 1 2>/dev/null || true
    return 1
  }
  bash "$here/live.sh" refresh @jobs >/dev/null 2>&1 || true   # live state: the job list shows the new job (no-op without the capability)
  printf '%s\n' "$unit"
}

# Helpers a job calls to report to its record; no-ops outside a job (HS_JOB_ID unset). Best effort.
#   hs_job_step N OF TEXT        hs_job_progress DONE TOTAL UNIT        hs_job_cancelled (0 = stop cleanly now)
hs_job_step() {
  [ -n "${HS_JOB_ID:-}" ] || return 0
  hs_job_record step "$HS_JOB_ID" "$1" "$2" "$3" 2>/dev/null || true
}
hs_job_progress() {
  [ -n "${HS_JOB_ID:-}" ] || return 0
  hs_job_record progress "$HS_JOB_ID" "$1" "$2" "$3" 2>/dev/null || true
}
# hs_job_cancelled: returns 0 when the job's record says cancelled (a long job polls it at a safe point and stops cleanly),
# 1 otherwise and always 1 outside a job.
hs_job_cancelled() {
  [ -n "${HS_JOB_ID:-}" ] || return 1
  hs_job_record cancelled "$HS_JOB_ID" 2>/dev/null
}
