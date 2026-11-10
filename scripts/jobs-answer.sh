#!/usr/bin/env bash
# help: answer the question an interactive recipe run waits for (the web interface; the answer is ONE line on standard input)
# help.de: die Frage beantworten, auf die ein interaktiver Rezeptlauf wartet (Weboberfläche; die Antwort ist EINE Zeile auf der Standardeingabe)
# args: <job id> --seq N --key K [--by <user>] [--role <role>]
# System command (hs sys jobs answer <id>; also reached as hs sys jobs start answer <id> ... by the web interface). docs/adr/0018-interactive-recipe-runs.md
# rules 7, 10 and 11, docs/PLAN-recipe-orchestrator.md. Output: status<TAB>done|stale|refused and reason<TAB><text>; exit 0 = stored, 1 = refused or stale.
#   --seq/--key   must be the question that waits now (else status stale: a double submit or an old page is harmless, nothing is written)
#   --by/--role   who answers (the web server sets both from the session; a call without --by is the root user on the server).
#                 Only the initiator of the job or the role admin may answer; anyone else is refused and nothing is written.
# The answer value is read from stdin only: never an argument, never printed, never in the record, an event or the journal. The audit line
# names the key and the role, never the value.
# Test knobs: HS_RUN_DIR, HS_JOBS_DIR.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/job.sh"
. "$here/lib/event.sh"
py="$here/lib/ask-q.py"
refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }
stale() { printf 'status\tstale\nreason\tThat question is not waiting any more.\n'; exit 1; }

id=${1:-}; shift || true
[[ "$id" =~ ^[0-9]{8}-[0-9]{6}-[A-Za-z0-9-]{1,60}-[a-z]{4}$ ]] || refuse "that is not a job id"
seq=""; key=""; by=""; role=""
while [ $# -gt 0 ]; do
  case "$1" in
    --seq) seq=${2:-}; shift 2 || refuse "--seq needs a number" ;;
    --key) key=${2:-}; shift 2 || refuse "--key needs a name" ;;
    --by)  by=${2:-}; shift 2 || refuse "--by needs a name" ;;
    --role) role=${2:-}; shift 2 || refuse "--role needs a role" ;;
    *) refuse "unknown option $1" ;;
  esac
done
[[ "$seq" =~ ^[0-9]{1,9}$ ]] || refuse "--seq needs a number"
[[ "$key" =~ ^[A-Za-z][A-Za-z0-9_]{0,40}$ ]] || refuse "--key needs a question name"
[[ -z "$by" || "$by" =~ ^[A-Za-z0-9._@\\-]{1,64}$ ]] || refuse "--by is not a user name"
[[ -z "$role" || "$role" =~ ^(viewer|app-manager|admin)$ ]] || refuse "--role is not a role"

rec=$(hs_job_record get "$id" 2>/dev/null) || refuse "There is no job with that id."
read -r state kind initiator wseq wkey < <(python3 -c '
import json, sys
r = json.load(sys.stdin); w = r.get("waiting") or {}
print(r.get("state") or "-", r.get("kind") or "-", (r.get("initiator") or "-").replace(" ", "_"), w.get("seq", "-"), w.get("key") or "-")' <<<"$rec") || refuse "The job record cannot be read."
[ "$kind" = orchestration ] || refuse "That job does not ask questions."
# who may answer: the initiator, or an admin. The root user of the server (no --by) is trusted like on every hs command.
if [ -n "$by" ] && [ "$role" != admin ] && [ "$by" != "${initiator//_/ }" ] && [ "$by" != "$initiator" ]; then
  refuse "Only the person who started this run, or an administrator, may answer."
fi
[ "$state" = waiting ] && [ "$wseq" = "$seq" ] && [ "$wkey" = "$key" ] || stale

dir=${HS_RUN_DIR:-/run/hs}/ask/$id
python3 "$py" accept "$dir" "$seq" "$key"   # the value comes through this script's own stdin
rc=$?
case "$rc" in
  0) ;;
  3) stale ;;
  *) refuse "That answer does not fit the question." ;;
esac
event_emit audit.ok "jobs answer" "" --payload "{\"actor\":\"$(printf '%s' "${by:-root}" | tr -c 'A-Za-z0-9._@-' '_')\",\"role\":\"${role:-root}\",\"key\":\"$key\",\"exit\":0}" || true
printf 'status\tdone\n'
