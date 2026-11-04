#!/usr/bin/env bash
# help: the event log: what happened on the server (disks, jobs, notifications), newest last
# help.de: das Ereignisprotokoll: was auf dem Server passiert ist (Platten, Aufträge, Benachrichtigungen), das Neueste zuletzt
# args: list [N] [--source S] [--after ID] | emit <source.kind> <subject> [text] [--level info|warn|error] [--payload JSON]
# Front end of the event log in /var/lib/hs/state.db (scripts/state-db.py: `emit` is the ONE writer, root). `list` reads it without root;
# a person at a terminal gets a table, `hs sys event list` and pipes get tab separated lines: id time source kind subject level text payload
# (`-` for an empty field). Kinds are <source>.<kind>, registered in scripts/lib/event-kinds.tsv. docs/adr/0005-events.md.
# Test knobs: HS_STATE_DB, HS_STATE_DIR, HS_PYTHON, HS_NOW.
set -uo pipefail
here=$(dirname "$0")
py=${HS_PYTHON:-python3}
db() { "$py" "$here/state-db.py" "$@"; }

people() { [ -t 1 ] && [ -z "${HS_CALLER:-}" ] && [ -z "${HS_PLAIN:-}" ]; }
if people; then . "$here/lib/ui.sh"; fi

cmd=${1:-list}; [ $# -eq 0 ] || shift
case "$cmd" in
  list)
    if people; then
      out=$(db event-list "$@")
      [ -n "$out" ] || { note "No events yet."; exit 0; }
      { thead 'When' 'Source' 'Kind' 'Subject' 'Level' 'Text'
        awk -F'\t' -v OFS='\t' '{ cmd = "date -d @" $2 " +\"%Y-%m-%d %H:%M\""; cmd | getline w; close(cmd); print w, $3, $4, $5, $6, ($7 == "-" ? "" : $7) }' <<<"$out"
      } | table
    else db event-list "$@"; fi ;;
  emit)
    . "$here/lib/ui.sh"
    if [ "$(id -u)" != 0 ] && [ -z "${HS_EVENT_NOROOT:-}" ]; then fail "$(t 'Writing to the event log needs root: sudo hs event emit ...')"; fi
    rc=0; db emit "$@" || rc=$?
    [ "$rc" -eq 0 ] || fail "$(t 'The event was not written (usage: hs event emit <source.kind> <subject> [text] [--level L] [--payload JSON])')"
    ;;
  *) . "$here/lib/ui.sh"; fail "$(t 'Unknown event command: %s. Use: hs event list | hs event emit ...' "$cmd")" ;;
esac
