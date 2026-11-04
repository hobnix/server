#!/usr/bin/env bash
# help: who did what: the commands that changed the server, with the user, the time and whether they worked
# help.de: wer was getan hat: die Befehle, die den Server geändert haben, mit Benutzer, Zeit und Ergebnis
# args: [N]   (default 50, newest last)
# Reads the audit events (audit.ok, audit.failed) of the event log in /var/lib/hs/state.db; the dispatcher writes one after every command
# that changes something (scripts/lib/audit.sh). Only the words typed are kept, never the arguments after them. A person at a terminal
# gets a table, `hs sys audit` and pipes get tab separated lines: id time actor result exit command. Retention is the event log's.
# Test knobs: HS_STATE_DB, HS_STATE_DIR, HS_PYTHON.
set -uo pipefail
here=$(dirname "$0")
py=${HS_PYTHON:-python3}
n=${1:-50}
case "$n" in ''|*[!0-9]*) n=50 ;; esac

if [ -t 1 ] && [ -z "${HS_CALLER:-}" ] && [ -z "${HS_PLAIN:-}" ]; then
  . "$here/lib/ui.sh"
  out=$("$py" "$here/state-db.py" audit-list "$n")
  [ -n "$out" ] || { note "$(t 'Nothing recorded yet. Commands that change the server are listed here.')"; exit 0; }
  { thead 'When' 'Who' 'Result' 'Command'
    awk -F'\t' -v OFS='\t' '{ cmd = "date -d @" $2 " +\"%Y-%m-%d %H:%M\""; cmd | getline w; close(cmd); print w, $3, $4, $6 }' <<<"$out"
  } | table
else
  "$py" "$here/state-db.py" audit-list "$n"
fi
