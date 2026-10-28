#!/usr/bin/env bash
# help: the state database: which disks the server has had (also the ones that are gone), what happened to them, how their SMART values moved
# help.de: die Zustandsdatenbank: welche Platten der Server hatte (auch die fehlenden), was mit ihnen geschah, wie sich ihre SMART-Werte entwickelten
# args: inventory | events [N] | forget <disk> [--yes] | collect | disks | smart <serial> | problems | deck-disks | inventory-json | history <now> | history-record <readings> | usage-record <key> <used> <size> | usage <key> [days] | read-put <key> | read-get <key> | reads
# Front end of scripts/state-db.py. `collect` is the ONE writer (root; hs-deck-status / hs-state-collect / disk-event.sh start it);
# everything else reads /var/lib/hs/state.db read-only. A person at a terminal gets tables (inventory, events); `hs sys state ...` and
# pipes get the tab separated lines. `forget` removes a MISSING disk from the list for good and asks first (--yes skips it).
# Test knobs: HS_STATE_DIR, HS_STATE_DB, HS_MONITOR, HS_LSBLK, HS_LOCKED_MARKER, HS_NOW, HS_PYTHON.
set -uo pipefail
here=$(dirname "$0")
py=${HS_PYTHON:-python3}
db() { "$py" "$here/state-db.py" "$@"; }

people() { [ -t 1 ] && [ -z "${HS_CALLER:-}" ] && [ -z "${HS_PLAIN:-}" ]; }
if people; then . "$here/lib/ui.sh"; fi

cmd=${1:-inventory}; [ $# -eq 0 ] || shift
case "$cmd" in
  inventory)
    if people; then
      out=$(db disks)
      [ -n "$out" ] || { note "Nothing is recorded yet. The collector runs every minute."; exit 0; }
      miss=$(awk -F'\t' '$5 == "missing"' <<<"$out" | grep -c . || true)
      if [ "$miss" -gt 0 ]; then status_line "Disks" "$(t '%s missing' "$miss")" bad; else status_line "Disks" "all present"; fi
      { thead 'Disk' 'Serial' 'Model' 'State' 'Role' 'Last seen' 'Note'
        awk -F'\t' -v OFS='\t' '{ cmd = "date -d @" $9 " +\"%Y-%m-%d %H:%M\""; cmd | getline w; close(cmd); print $4, $1, $2, ($5 == "missing" ? "MISSING" : $5), $6, w, ($11 == "-" ? "" : $11) }' <<<"$out"
      } | table
    else db disks; fi ;;
  events)
    if people; then
      out=$(db events "${1:-30}")
      [ -n "$out" ] || { note "No disk events yet."; exit 0; }
      { thead 'When' 'Event' 'Text'
        awk -F'\t' -v OFS='\t' '{ cmd = "date -d @" $1 " +\"%Y-%m-%d %H:%M\""; cmd | getline w; close(cmd); print w, $2, $4 }' <<<"$out"
      } | table
    else db events "$@"; fi ;;
  forget)
    who=${1:-}; shift || true
    [ -n "$who" ] || { echo "usage: hs disk <serial> forget [--yes]" >&2; exit 1; }
    yes=false; [ "${1:-}" = --yes ] && yes=true
    . "$here/lib/ui.sh"
    if ! $yes; then
      if [ -t 0 ] && [ -t 1 ]; then confirm "Forget this disk for good? Its SMART history goes with it." || fail "cancelled"
      else fail "forget removes a disk from the list: run it on a terminal or add --yes"; fi
    fi
    rc=0; serial=$(db forget "$who") || rc=$?
    case "$rc" in
      0) ok "$(t 'Forgot %s' "$serial")" ;;
      2) fail "$(t '%s is in the machine: only a missing disk can be forgotten' "$who")" ;;
      *) fail "$(t '%s is not in the inventory. See: hs disk inventory' "$who")" ;;
    esac ;;
  collect|disks|smart|problems|deck-disks|inventory-json|disks-json|events-json|history|history-record|usage-record|usage|read-put|read-get|reads) db "$cmd" "$@" ;;
  *) echo "usage: hs disk inventory | hs disk events | hs disk <serial> forget" >&2; exit 1 ;;
esac
