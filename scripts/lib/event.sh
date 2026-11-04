# shellcheck shell=bash
# The one way a script writes to the event log (docs/adr/0005-events.md, rule 4): event_emit <source.kind> <subject> [text] [--level L] [--payload JSON]
# Runs `state-db.py emit` (the one writer, needs root). Best effort: not root, no python, a failing write: it returns 0 and says nothing
# (one line through ui.sh `warn` when HS_EVENT_VERBOSE=1). A kind has to be listed in scripts/lib/event-kinds.tsv (tests/event-log.sh checks it).
# Test knobs: HS_EVENT_NOROOT=1 (do not require root), HS_PYTHON, HS_STATE_DB.

event_emit() {
  local here py rc=0
  here=$(dirname "${BASH_SOURCE[0]}")
  py=${HS_PYTHON:-python3}
  if [ "$(id -u)" != 0 ] && [ -z "${HS_EVENT_NOROOT:-}" ]; then return 0; fi
  "$py" "$here/../state-db.py" emit "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ] && [ "${HS_EVENT_VERBOSE:-}" = 1 ]; then
    # shellcheck source=scripts/lib/ui.sh
    . "$here/ui.sh"
    warn "$(t 'Could not write the event %s (exit %s)' "${1:-?}" "$rc")" >&2
  fi
  return 0
}
