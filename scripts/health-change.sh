#!/usr/bin/env bash
# help: acknowledge a health problem, take it back, or lift the pause of the bulk jobs without asking anything: what would happen (plan), then do it (start)
# help.de: ein Gesundheitsproblem quittieren, zurücknehmen oder die Pause der Bulk-Jobs aufheben, ohne etwas zu fragen: was passieren würde (plan), dann ausführen (start)
# args: plan|start ack <id> | unack <id> | resume
# System command (hs sys health plan|start): for the interface and tests. Never asks, prints plain key<TAB>value lines like expiry-change.sh.
# The work is health-ack.sh's; this script only checks the id against the problems health-check.sh --list knows (key TAB text TAB acked|-).
#   ack <id>     silence an active problem until it clears        unack <id>  take the acknowledgement back
#   resume       lift the pause of the sync, scrub and cache mover (needs the pause file) and acknowledge what caused it
# plan: exit 0 = allowed, 1 = refused. Output: status ok|refused, reason<TAB><text>, heading|step|note|command<TAB><line>, long<TAB>no.
# start: the same checks, then status<TAB>done.
# Test knobs: HS_HEALTH_CHECK, HS_HEALTH_ACK (stand-in for health-ack.sh), HS_BULK_PAUSE.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/bulklock.sh"
hc=${HS_HEALTH_CHECK:-$here/health-check.sh}
ackcmd=${HS_HEALTH_ACK:-$here/health-ack.sh}

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

verb=${1:-}; action=${2:-}
case "$verb" in plan|start) ;; *) echo "usage: health-change.sh plan|start ack <id> | unack <id> | resume" >&2; exit 1 ;; esac
case "$action" in ack|unack|resume) ;; *) refuse "unknown action (ack, unack or resume)" ;; esac
shift 2
list=$(bash "$hc" --list 2>/dev/null </dev/null || true)
id="" text="" state="-"
if [ "$action" = resume ]; then
  [ $# -eq 0 ] || refuse "unexpected extra arguments"
  [ -e "$bulk_pause" ] || refuse "Nothing is paused."
  cmd=(bash "$ackcmd" resume)
else
  id=${1:-}
  [ -n "$id" ] || refuse "a problem id is needed"
  [ $# -eq 1 ] || refuse "unexpected extra arguments"
  [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9:._\ ()-]{0,100}$ ]] || refuse "invalid problem id"
  row=$(awk -F'\t' -v k="$id" '$1 == k { print; exit }' <<<"$list")
  [ -n "$row" ] || refuse "$id is not an active problem."
  text=$(cut -f2 <<<"$row"); state=$(cut -f3 <<<"$row")
  if [ "$action" = ack ]; then
    [ "$state" != acked ] || refuse "$id is acknowledged already."
  else
    [ "$state" = acked ] || refuse "$id is not acknowledged."
  fi
  cmd=(bash "$ackcmd" "$action" "$id")
fi

if [ "$verb" = start ]; then
  rc=0; out=$("${cmd[@]}" </dev/null 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'status\trefused\nreason\t%s\n' "$(printf '%s' "$out" | sed -e 's/^[[:space:]]*//' -e 's/^[✗!] *//' | awk 'NF' | tail -n 1)"
    exit 1
  fi
  printf 'status\tdone\n'
  exit 0
fi

printf 'status\tok\n'
case "$action" in
  ack)
    printf 'heading\tacknowledge %s\n' "$id"
    printf 'step\tsilence the problem until it clears: %s\n' "$text"
    printf 'note\tIt is no longer sent or counted. When it has cleared and comes back, it is reported again.\n' ;;
  unack)
    printf 'heading\ttake back the acknowledgement of %s\n' "$id"
    printf 'step\tthe problem is reported and counted again\n' ;;
  resume)
    printf 'heading\tlift the pause of the bulk jobs\n'
    printf 'step\tthe parity sync, the scrub and the cache mover run again\n'
    printf 'step\tacknowledge the problems that caused the pause, so the next health check does not pause again\n'
    printf 'note\tFix the cause first. Take an acknowledgement back on the Health page.\n' ;;
esac
printf 'command\t%s\n' "${cmd[*]}"
printf 'long\tno\n'
