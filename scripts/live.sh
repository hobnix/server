#!/usr/bin/env bash
# help: the live state the web interface shows: ask the collector to read again, see its topics, check them
# help.de: der Live-Zustand der Weboberfläche: den Sammler neu lesen lassen, seine Themen sehen, sie prüfen
# args: refresh <topic>...|--all | status | check
# Front end of scripts/live_state.py (sys-only: plain tab separated lines, no ui.sh). Test knob: HS_LIVE_SOCKET.
set -uo pipefail
here=$(dirname "$0")
exec python3 "$here/live_state.py" "$@"
