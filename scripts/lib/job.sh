# shellcheck shell=bash
# Background jobs: a long command runs as a transient systemd unit (hs-job-<slug>-<HHMM>).
# Sourced by hs.sh and by wizards that ask first and run the last step as a job.
#   hs_job <slug> <description> -- <command...>     starts it, prints the unit name
# HS_CALLER=job tells the script it was started this way (no questions). The unit notifies on
# failure (hs-notify-failure@) and on success (notify.sh). Look: hs job running, hs job log <unit>.
hs_job() {
  local slug=$1 desc=$2 unit here
  shift 3   # slug, description, --
  slug=$(printf '%s' "$slug" | tr -c 'A-Za-z0-9' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//')   # a row path such as pool-<pool>-sync is no unit name
  here=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
  unit=hs-job-$slug-$(date +%H%M%S)
  local extra=() kv
  # HS_JOB_ENV: more environment for the job, one KEY=VALUE per line (recipe answers; a secret is never put here, it travels as a file)
  while IFS= read -r kv; do [[ "$kv" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && extra+=(-E "$kv"); done <<<"${HS_JOB_ENV:-}"
  [ -z "${HS_DISK_PASSPHRASE_FILE:-}" ] || extra=(-E "HS_DISK_PASSPHRASE_FILE=$HS_DISK_PASSPHRASE_FILE")   # a path, not the secret
  # job record (docs/adr/0004-job-record.md): best effort, the job runs without one
  local src=cli jid=
  case "${HS_CALLER:-}" in web|ui) src=web ;; ext) src=extension ;; timer) src=timer ;; esac
  jid=$(python3 "$here/job-record.py" new --slug "$slug" --desc "$desc" --unit "$unit" --source "$src" \
          --initiator "${SUDO_USER:-${USER:-}}" 2>/dev/null) || jid=
  [ -z "$jid" ] || extra+=(-E "HS_JOB_ID=$jid")
  [ -z "${HS_JOBS_DIR:-}" ] || extra+=(-E "HS_JOBS_DIR=$HS_JOBS_DIR")   # the unit writes to the same directory as hs_job
  systemd-run --quiet --unit="$unit" --description="$desc" \
    --property="OnFailure=hs-notify-failure@$unit.service" \
    -E HS_CALLER=job -E "HS_LANG=${hs_lang:-en}" -E "PATH=$PATH" ${extra[@]+"${extra[@]}"} \
    bash -c 'd=$1; shift   # $0 = scripts dir, $1 = description, the rest = the command
             [ -z "${HS_JOB_ID:-}" ] || python3 "$0/job-record.py" run "$HS_JOB_ID" 2>/dev/null || true
             "$@"; rc=$?
             [ -z "${HS_JOB_ID:-}" ] || python3 "$0/job-record.py" finish "$HS_JOB_ID" "$rc" 2>/dev/null || true
             bash "$0/live.sh" refresh --all >/dev/null 2>&1 || true   # live state: read again (no-op without the capability)
             [ "$rc" -ne 0 ] || bash "$0/notify.sh" --category ok hs "$d finished" >/dev/null 2>&1
             exit "$rc"' "$here" "$desc" "$@" || {
    [ -z "$jid" ] || python3 "$here/job-record.py" finish "$jid" 1 2>/dev/null || true
    return 1
  }
  bash "$here/live.sh" refresh @jobs >/dev/null 2>&1 || true   # live state: the job list shows the new job (no-op without the capability)
  printf '%s\n' "$unit"
}

# Helpers a job calls to report to its record; no-ops outside a job (HS_JOB_ID unset). Best effort.
#   hs_job_step N OF TEXT        hs_job_progress DONE TOTAL UNIT
hs_job_step() {
  [ -n "${HS_JOB_ID:-}" ] || return 0
  python3 "${BASH_SOURCE[0]%/*}/../job-record.py" step "$HS_JOB_ID" "$1" "$2" "$3" 2>/dev/null || true
}
hs_job_progress() {
  [ -n "${HS_JOB_ID:-}" ] || return 0
  python3 "${BASH_SOURCE[0]%/*}/../job-record.py" progress "$HS_JOB_ID" "$1" "$2" "$3" 2>/dev/null || true
}
