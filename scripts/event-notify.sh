#!/usr/bin/env bash
# help: send the push messages that the event log asks for (rules: scripts/lib/notify-rules.tsv); runs by itself every 30 seconds
# help.de: schickt die Nachrichten, die das Ereignisprotokoll verlangt (Regeln: scripts/lib/notify-rules.tsv); läuft alle 30 Sekunden von selbst
# args: none
# Run by hs-event-notify.service (root). The work is in scripts/event-notify.py: it takes the events that the media helpers left in the spool
# folder of the share `media` into the event log, then calls `hs notify` for every row after its cursor that a rule matches. Always exits 0
# so the timer is never held up; problems are lines in the journal (journalctl -u hs-event-notify).
# Test knobs: HS_EVENT_SPOOL (a folder instead of the one of the share), HS_MEDIA_SHARE, and those of event-notify.py.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/sharepath.sh"

spools=()
if [ -n "${HS_EVENT_SPOOL+x}" ]; then
  spools=("$HS_EVENT_SPOOL")
elif d=$(share_dir "${HS_MEDIA_SHARE:-media}" 2>/dev/null); then
  spools=("$d/.hs-events")
fi
args=()
for d in "${spools[@]}"; do [ -z "$d" ] || args+=(--spool "$d"); done

python3 "$here/event-notify.py" run ${args[@]+"${args[@]}"} || true
exit 0
