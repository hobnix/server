#!/usr/bin/env bash
# help: the orchestrator of an interactive recipe run (a job; started by hs sys recipes start <recipe> run --interactive)
# help.de: der Orchestrator eines interaktiven Rezeptlaufs (ein Auftrag; gestartet mit hs sys recipes start <Rezept> run --interactive)
# args: <recipe> [--name <container>]
# Runs as the unit of an orchestration job (docs/adr/0018-interactive-recipe-runs.md, docs/PLAN-recipe-orchestrator.md). It makes the folder
# $HS_RUN_DIR/ask/<job id> (0700), runs the recipe as sub-jobs (one per phase of a `# phases: a b c` header, else ONE named `run`; a phase reaches the
# recipe as RECIPE_PHASE), and while a step waits in ask_q it copies the oldest question into its own record (state waiting, event job.waiting, one
# push message), and back to running when the step got its answer. A question not answered for $HS_ASK_TIMEOUT seconds (setting
# recipeQuestionHours, default 24 h) cancels the run cleanly: the sub-job is stopped, the record ends cancelled with error input_timeout.
# Stopping the orchestrator (hs job stop) stops the sub-job too. The folder is removed on every way out.
# Test knobs: HS_ASK_NOUNITCHECK (do not ask systemd whether the sub-job unit lives), HS_RECIPE (stand-in for recipe.sh), HS_RUN_DIR, HS_ASK_POLL, HS_ASK_TIMEOUT, HS_SYSTEMCTL, HS_NOTIFY (stand-in for notify.sh).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/ui.sh"
. "$here/lib/job.sh"
. "$here/lib/recipe-path.sh"
. "$here/lib/setting.sh"
recipe=${HS_RECIPE:-$here/recipe.sh}
systemctl=${HS_SYSTEMCTL:-systemctl}
py="$here/lib/ask-q.py"

name=${1:-}; shift || true
ct=""
[ "${1:-}" != --name ] || { ct=${2:-}; shift 2 || true; }
[[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || { fail "$(t "Usage: recipe-orchestrate.sh <recipe> [--name <container>]")"; exit 2; }
orch=${HS_JOB_ID:-}
[ -n "$orch" ] || { fail "$(t 'The orchestrator needs a job record (HS_JOB_ID).')"; exit 2; }
file=$(recipe_script "$name" 2>/dev/null) || { fail "$(t "There is no recipe called '%s'." "$name")"; exit 1; }

run=${HS_RUN_DIR:-/run/hs}
dir=$run/ask/$orch
poll=${HS_ASK_POLL:-0.5}
hours=$(setting_get recipeQuestionHours 2>/dev/null || true); [[ "$hours" =~ ^[0-9]+$ ]] && [ "$hours" -ge 1 ] || hours=24
limit=${HS_ASK_TIMEOUT:-$((hours * 3600))}
mkdir -p "$dir/q" "$dir/a" && chmod 700 "$run/ask" "$dir" "$dir/q" "$dir/a" 2>/dev/null || { fail "$(t 'Could not make the question folder.')"; exit 1; }

sub_unit=""
cleanup() { rm -rf "$dir"; }
stop_sub() { [ -z "$sub_unit" ] || "$systemctl" stop "$sub_unit.service" >/dev/null 2>&1 || true; }
on_term() { stop_sub; cleanup; trap - EXIT; exit 143; }
trap on_term TERM INT
trap cleanup EXIT
nap() { sleep "$poll" & wait $! 2>/dev/null; }   # a signal ends the wait at once, the trap runs

phases=$(sed -n 's/^# phases: //p' "$file" | head -n1 || true)
# shellcheck disable=SC2206
phase_list=(${phases:-run})
total=${#phase_list[@]}

# what the sub-jobs inherit: the answers up front (RECIPE_*), never a secret (those come through the protocol)
job_env=""
while IFS= read -r l; do job_env+="$l"$'\n'; done < <(env | grep -E '^(RECIPE_[A-Z0-9_]+|HS_SECRETS_DIR)=' || true)   # HS_SECRETS_DIR is a path: a secret given up front is a root-only file there

state_of() { hs_job_record get "$1" 2>/dev/null | python3 -c 'import json,sys
try: r=json.load(sys.stdin)
except Exception: sys.exit(1)
print(r.get("state") or "", r.get("exit") if r.get("exit") is not None else "")'; }

notify() {   # one message when a question starts to wait: names the recipe and the label, never a value
  local label=$1
  if [ -n "${HS_NOTIFY:-}" ]; then "$HS_NOTIFY" --category info "Waiting for your answer" "$name: $label" >/dev/null 2>&1 || true
  else bash "$here/notify.sh" --category info "Waiting for your answer" "$name: $label" >/dev/null 2>&1 || true; fi
}

cur_seq=""; asked_at=0
# watch_once: look at the question folder once; keeps the orchestration record in step. Returns 124 when the question timed out.
watch_once() {
  local f=() seq
  mapfile -d '' f < <(python3 "$py" pending "$dir")
  if [ ${#f[@]} -ge 10 ]; then
    seq=${f[0]}
    if [ "$seq" != "$cur_seq" ]; then
      [ -z "$cur_seq" ] || hs_job_record resume "$orch" >/dev/null 2>&1 || true
      args=(--seq "$seq" --key "${f[1]}" --label "${f[3]}" --kind "${f[2]}")
      [ -z "${f[4]}" ] || args+=(--default "${f[4]}")
      [ -z "${f[5]}" ] || args+=(--pattern "${f[5]}")
      [ -z "${f[6]}" ] || args+=(--choices "${f[6]}")
      [ -z "${f[7]}" ] || args+=(--error "${f[7]}")
      args+=(--attempt "${f[8]:-1}")
      hs_job_record wait "$orch" "${args[@]}" >/dev/null 2>&1 || true
      cur_seq=$seq; asked_at=$SECONDS
      [ "${f[8]:-1}" != 1 ] || notify "${f[3]}"
    elif [ $((SECONDS - asked_at)) -ge "$limit" ]; then
      return 124
    fi
  elif [ -n "$cur_seq" ]; then
    hs_job_record resume "$orch" >/dev/null 2>&1 || true
    cur_seq=""
  fi
  return 0
}

rc=0; n=0
for phase in "${phase_list[@]}"; do
  n=$((n + 1))
  [[ "$phase" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { fail "$(t "'%s' is not a phase name." "$phase")"; rc=1; break; }
  hs_job_step "$n" "$total" "$phase"
  cmd=(bash "$recipe" "$name"); [ -z "$ct" ] || cmd+=(--name "$ct")
  penv=$job_env; [ "$phase" = run ] && [ "$total" -eq 1 ] || penv+="RECIPE_PHASE=$phase"$'\n'
  # a sub-job is an ordinary job (own unit, record, log) that names its parent; it asks through HS_ASK_DIR
  utmp=$(mktemp "$dir/.unit.XXXXXX")
  HS_ASK_DIR=$dir HS_JOB_PARENT=$orch HS_JOB_KIND=step HS_JOB_ENV=$penv HS_ASK_TIMEOUT=$((limit + 300)) \
    hs_job "recipe-$name${ct:+-$ct}-$phase" "hs recipe $name${ct:+ --name $ct} ($phase)" -- "${cmd[@]}" >"$utmp" || { fail "$(t 'The step could not be started.')"; rc=1; break; }
  sub_unit=$(cat "$utmp"); rm -f "$utmp"
  sub=${HS_JOB_LAST_ID:-}
  [ -n "$sub" ] || { fail "$(t 'The step has no job record.')"; rc=1; break; }
  gone=0
  while :; do
    st=$(state_of "$sub") || st=""
    read -r s e <<<"$st"
    case "${s:-}" in ok|failed|cancelled|interrupted) break ;; esac
    if [ -z "${s:-}" ]; then break; fi
    if hs_job_cancelled; then stop_sub; rc=130; break 2; fi   # the person stopped the orchestration
    if [ -z "${HS_ASK_NOUNITCHECK:-}" ] && ! "$systemctl" is-active --quiet "$sub_unit.service" 2>/dev/null; then
      gone=$((gone + 1)); [ "$gone" -lt 6 ] || { hs_job_record finish "$sub" 1 >/dev/null 2>&1 || true; s=failed; e=1; break; }
    else gone=0; fi
    watch_once; w=$?
    if [ "$w" -eq 124 ]; then
      stop_sub
      hs_job_record finish "$sub" 1 >/dev/null 2>&1 || true
      hs_job_record cancel "$orch" --by timer --safe yes >/dev/null 2>&1 || true
      hs_job_record error "$orch" --category input_timeout --message "no answer to $name within $((limit / 3600)) h: run it again" >/dev/null 2>&1 || true
      event_emit job.cancelled "$orch" "no answer in time" 2>/dev/null || true
      warn "$(t 'Nobody answered the question in time. The run was cancelled; run it again.')"
      exit 0
    fi
    nap
  done
  if [ -n "$cur_seq" ]; then hs_job_record resume "$orch" >/dev/null 2>&1 || true; cur_seq=""; fi
  sub_unit=""
  [ "${s:-}" = ok ] || { rc=${e:-1}; [ "$rc" != 0 ] && [ -n "$rc" ] || rc=1; fail "$(t 'The step %s did not finish (%s).' "$phase" "${s:-unknown}")"; break; }
done
exit "$rc"
