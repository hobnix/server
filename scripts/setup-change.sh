#!/usr/bin/env bash
# help: close the first-run wizard of the web interface without asking anything: what would happen (plan), then do it (start)
# help.de: den Einrichtungsassistenten der Weboberfläche schließen, ohne Rückfragen: was passieren würde (plan), dann ausführen (start)
# args: plan|start wizard-done
# System command (hs sys setup plan|start): for the interface and tests. It never asks and prints plain key<TAB>value lines like dc-change.sh.
#   wizard-done   mark the first-run wizard as finished (scripts/first_run.py wizard-done); refused unless the wizard is open
# plan: exit 0 = allowed, 1 = refused. Output: status ok|refused, reason<TAB><text>, heading|step<TAB><line>, long<TAB>no.
# start: the same check, then the wizard is closed; answers status done.
# Test knobs: HS_FIRST_RUN_FILE, HS_STATE_DIR, HS_PYTHON.
set -euo pipefail
here=$(dirname "$0")
py=${HS_PYTHON:-python3}

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

verb=${1:-}; action=${2:-}
case "$verb" in plan|start) ;; *) echo "usage: setup-change.sh plan|start wizard-done" >&2; exit 1 ;; esac
[ "$action" = wizard-done ] || refuse "unknown action (wizard-done)"

state=$("$py" "$here/first_run.py" wizard 2>/dev/null || true)
[ "$state" = open ] || refuse "The first-run wizard is not open."

if [ "$verb" = start ]; then
  "$py" "$here/first_run.py" wizard-done >/dev/null 2>&1 || refuse "the wizard could not be closed"
  printf 'status\tdone\n'
  exit 0
fi
printf 'status\tok\nheading\tclose the first-run wizard\n'
printf 'step\tthe wizard is not shown again; the Setup page keeps the checklist of what is open\n'
printf 'long\tno\n'
