#!/usr/bin/env bash
# help: the one-time code of the first web setup: issue a new one on this console, show the state, or start over
# help.de: der Einmalcode der ersten Einrichtung im Browser: hier an der Konsole einen neuen ausstellen, den Stand zeigen oder neu beginnen
# args: issue | status | reset
# The code is printed here and nowhere else (never logged, never mailed, never sent to the web). docs/adr/0022-first-run-console-token.md.
# The state is $HS_STATE_DIR/first-run.json (scripts/first_run.py). Test knobs: HS_FIRST_RUN_FILE, HS_STATE_DIR, HS_PYTHON.
set -uo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
py=${HS_PYTHON:-python3}
cmd=${1:-status}
case "$cmd" in
  issue|reset)
    [ "$(id -u)" = 0 ] || [ -n "${HS_FIRST_RUN_FILE:-}" ] || fail "$(t 'This needs root: sudo hs setup-code %s' "$cmd")"
    "$py" "$here/first_run.py" "$cmd" || fail "$(t 'The first setup is already done. To start over: sudo hs setup-code reset')" ;;
  status)
    IFS=$'\t' read -r state detail < <("$py" "$here/first_run.py" status)
    case "$state" in
      pending) ok "$(t 'A setup code is waiting (valid for another %s s).' "$detail")" ;;
      expired) note "$(t 'The setup code has expired: sudo hs setup-code issue')" ;;
      burned)  note "$(t 'The setup code was used up by wrong tries: sudo hs setup-code issue')" ;;
      done)    ok "$(t 'The first setup is done (admin: %s).' "$detail")" ;;
      *)       note "$(t 'No first setup is waiting on this server.')" ;;
    esac ;;
  *) fail "$(t 'Usage: hs setup-code issue | status | reset')" ;;
esac
