#!/usr/bin/env bash
# help: silence a health problem until it clears (acknowledge), and lift a pause the health check set
# help.de: ein Gesundheitsproblem stummschalten, bis es verschwindet (quittieren), und eine Pause aufheben, die der Health-Check gesetzt hat
# args: ack [<id>] | unack <id> | resume
# ack            list the active problems with their ids (the id is the key the health check works with)
# ack <id>       acknowledge: the problem is no longer sent or counted. It stays silent until the problem has cleared (the
#                health check drops the entry then, and a later return is reported again). Only active ids are accepted.
# unack <id>     take the acknowledgement back
# resume         lift the pause of the parity sync, scrub and cache mover (setting autoMitigate) and
#                acknowledge the problems that caused it, so the next health run does not pause again. Fix the cause first.
# The list is /var/lib/hs/health-ack (id TAB time); the health check reads it. Test knobs: HS_ACK_FILE, HS_HEALTH_CHECK, HS_BULK_PAUSE.
set -uo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/bulklock.sh"
ack_file=${HS_ACK_FILE:-/var/lib/hs/health-ack}
hc=${HS_HEALTH_CHECK:-$here/health-check.sh}

usage() { say "usage: hs health ack [<id>] | hs health unack <id> | hs health resume"; exit 1; }
can_write() { mkdir -p "$(dirname "$ack_file")" 2>/dev/null && { [ -w "$ack_file" ] || { [ ! -e "$ack_file" ] && [ -w "$(dirname "$ack_file")" ]; }; }; }
is_acked() { [ -r "$ack_file" ] && grep -q -F -x -e "$1" <(cut -f1 "$ack_file"); }
active() { bash "$hc" --list 2>/dev/null || true; }   # id TAB text TAB acked|- (then since, channels: ignored here)

add_ack() {   # <id>
  can_write || fail "Cannot write $ack_file: run it with sudo."
  is_acked "$1" || printf '%s\t%s\n' "$1" "$(date +%s)" >> "$ack_file"
}

cmd=${1:-ack}; [ $# -eq 0 ] || shift
case "$cmd" in
  ack)
    id=${1:-}
    if [ -z "$id" ]; then
      out=$(active)
      if [ -z "$out" ]; then ok "No problems found."; exit 0; fi
      if [ -t 1 ] && [ -z "${HS_CALLER:-}" ] && [ -z "${HS_PLAIN:-}" ]; then
        { thead 'Id' 'Problem' 'State'
          awk -F'\t' -v OFS='\t' '{ print $1, $2, ($3 == "acked" ? "acknowledged" : "open") }' <<<"$out"
        } | table
        note "Silence one until it clears: hs health ack <id>"
      else
        printf '%s\n' "$out"
      fi
      exit 0
    fi
    if ! awk -F'\t' -v k="$id" '$1 == k { f = 1 } END { exit !f }' <<<"$(active)"; then
      is_acked "$id" || fail "$id is not an active problem. List the ids: hs health ack"
    fi
    add_ack "$id"
    ok "Acknowledged $id: silent until it clears."
    ;;
  unack)
    id=${1:-}; [ -n "$id" ] || usage
    can_write || fail "Cannot write $ack_file: run it with sudo."
    is_acked "$id" || fail "$id is not acknowledged."
    awk -F'\t' -v k="$id" '$1 != k' "$ack_file" > "$ack_file.tmp" && mv "$ack_file.tmp" "$ack_file"
    ok "Back in the reports: $id"
    ;;
  resume)
    if [ ! -e "$bulk_pause" ]; then note "Nothing is paused."; exit 0; fi
    keys=$(sed -n 's/^keys=//p' "$bulk_pause" | head -n1)
    can_write || fail "Cannot write $ack_file: run it with sudo."
    IFS=, read -r -a ks <<<"$keys"
    for k in "${ks[@]}"; do [ -z "$k" ] || add_ack "$k"; done
    rm -f "$bulk_pause"
    ok "Lifted: the parity sync, the scrub and the cache mover run again."
    [ -z "$keys" ] || note "Acknowledged: ${keys//,/, }. Unsilence with: hs health unack <id>"
    ;;
  *) usage ;;
esac
