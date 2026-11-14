# shellcheck shell=bash
# ask_q: one question function for the terminal and for the web (docs/adr/0018-interactive-recipe-runs.md rules 6 to 10,
# docs/PLAN-recipe-orchestrator.md). Sourced after ui.sh (recipes/_lib.sh does it).
#
#   value=$(ask_q <key> <kind> <label> [default] [pattern] [choices])
#     key      the question's name, <UPPER_CASE>; the web translates by it
#     kind     text | secret | choice          choices: a,b,c (kind choice)
#     label    plain English text, no HTML, never a value
#   Env in (optional): ASK_ERROR (one plain line: why the last answer was refused, never the value), ASK_ATTEMPT (1 = first time).
#   Prints the answer on stdout (nothing else on stdout). Order: (a) an answer given up front (`answer KEY`: RECIPE_<KEY> or the secret
#   file) wins; (b) HS_ASK_DIR set: ask through the file protocol and wait; (c) a terminal: ui.sh ask / ask_secret / choose, same words as
#   before; (d) neither: the default (a secret: nothing).
#   ask_remote   0 when a question can reach a person without this terminal (HS_ASK_DIR is set)
#   ask_q_exec <ct> <key> <kind> <label> [default] [pattern] [choices] -- <command in the container...>
#     the host asks, the answer goes to the command's STANDARD INPUT inside the container (rule 15); the container never sees HS_ASK_DIR.
# Test knobs: HS_ASK_SCRIPT=<file> (KEY=value lines, the first unused line of that key answers; used before the protocol), HS_ASK_POLL
# (seconds between looks, default 0.5), HS_ASK_TIMEOUT (seconds a step waits at most, default 24 h + 5 min: the orchestrator cancels at 24 h).
# A secret never goes through argv, the environment, the journal or the job record: the web server hands it to `hs sys jobs answer` on stdin, it
# lands in a 0600 file on tmpfs, this function reads it once, deletes the file and prints it for the caller to pass on the way the recipe does.

. "${BASH_SOURCE[0]%/*}/job.sh"   # hs_job_record, hs_job_cancelled
_ASK_PY="${BASH_SOURCE[0]%/*}/ask-q.py"
ASK_MAX_ATTEMPTS=10

ask_remote() { [ -n "${HS_ASK_DIR:-}" ]; }

_ask_script_line() {   # the next unused KEY=value line of the fake answerer
  local f=$HS_ASK_SCRIPT used n=0 line
  used="$f.used"; touch "$used" 2>/dev/null || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [ "${line%%=*}" = "$1" ] || continue
    grep -qx "$n" "$used" && continue
    echo "$n" >> "$used"
    printf '%s' "${line#*=}"
    return 0
  done < "$f"
  return 1
}

ask_q() {
  local key=$1 kind=$2 label=$3 default=${4:-} pattern=${5:-} choices=${6:-} v err=${ASK_ERROR:-} attempt=${ASK_ATTEMPT:-1}
  local seq poll=${HS_ASK_POLL:-0.5} t0=$SECONDS limit=${HS_ASK_TIMEOUT:-86700} sub=${HS_JOB_ID:-} polls=0
  [[ "$key" =~ ^[A-Za-z][A-Za-z0-9_]{0,40}$ ]] || return 2
  case "$kind" in text|secret|choice) ;; *) return 2 ;; esac
  if [ "$kind" = secret ]; then default=""; fi
  # (a) given up front, and only on the first try: after a refusal the caller must hear a new answer
  if [ "$attempt" -le 1 ] && [ -z "$err" ]; then
    v=$(answer "$key" 2>/dev/null || true)
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  fi
  if [ -n "${HS_ASK_SCRIPT:-}" ] && v=$(_ask_script_line "$key"); then printf '%s' "$v"; return 0; fi
  if ask_remote; then
    if [ "$attempt" -gt "$ASK_MAX_ATTEMPTS" ]; then
      warn "$(t 'Too many answers were refused for: %s' "$label")" >&2
      [ -z "${HS_JOB_ID:-}" ] || hs_job_record error "$HS_JOB_ID" --category input_rejected --message "the answers to $key were refused $ASK_MAX_ATTEMPTS times" 2>/dev/null || true
      return 75
    fi
    seq=$(python3 "$_ASK_PY" write "$HS_ASK_DIR" "$key" "$kind" "$label" "$default" "$pattern" "$choices" "$err" "$attempt" "$sub") || return 1
    note "$(t 'Waiting for: %s' "$label")" >&2   # one human line in the journal; the question itself travels in the file
    while :; do
      if v=$(python3 "$_ASK_PY" take "$HS_ASK_DIR" "$seq"); then
        if [ -z "$v" ] && [ "$kind" = text ]; then v=$default; fi
        printf '%s' "$v"
        return 0
      fi
      sleep "$poll"
      polls=$((polls + 1))
      if [ $((polls % 20)) -eq 0 ] && hs_job_cancelled 2>/dev/null; then python3 "$_ASK_PY" drop "$HS_ASK_DIR" "$seq"; return 130; fi
      if [ $((SECONDS - t0)) -ge "$limit" ]; then python3 "$_ASK_PY" drop "$HS_ASK_DIR" "$seq"; return 124; fi   # the clock, not a poll count
    done
  fi
  if interactive; then
    case "$kind" in
      secret) ask_secret "$label" ;;
      choice) local IFS=,; # shellcheck disable=SC2086
              choose "$label" $choices ;;
      *) ask "$label" "$default" ;;
    esac
    return
  fi
  printf '%s' "$default"
}

ask_q_exec() {
  local ct=$1; shift
  local args=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do args+=("$1"); shift; done
  shift   # the --
  [ $# -gt 0 ] && [ ${#args[@]} -ge 3 ] || return 2
  local value rc=0
  value=$(ask_q "${args[@]}") || return $?
  printf '%s\n' "$value" | incus exec "$ct" -- "$@" || rc=$?   # stdin of the command; printf is a builtin: not in a process list
  value=""
  return "$rc"
}
