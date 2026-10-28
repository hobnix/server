#!/usr/bin/env bash
# help: change the list of expiry dates without asking anything: what would happen (plan), then do it (start)
# help.de: die Liste der Ablaufdaten ändern, ohne etwas zu fragen: was passieren würde (plan), dann ausführen (start)
# args: plan|start add <name> --date <YYYY-MM-DD> [--renew <how to renew>] | plan|start remove <name>
# System command (hs sys expiry plan|start): for the interface and tests. It never asks and prints plain key<TAB>value lines like
# jobs-change.sh. The work is expiry.sh's (add / remove); this script only checks the input and says what would happen.
#   add <name> --date D [--renew T]   write the entry down (an existing name gets the new date and text); T is the "how to renew" hint
#   remove <name>                     take the entry off the list
# plan: exit 0 = allowed, 1 = refused, 2 = something is missing (status needs, needs<TAB>date). Output: status ok|refused|needs,
#   reason<TAB><text>, heading|step|note|warn|command<TAB><line>, long<TAB>no. Nothing here is red: the entry is one line of a text file.
# start: the same checks, then status<TAB>done.
# Test knobs: HS_EXPIRY (stand-in for expiry.sh).
set -euo pipefail
here=$(dirname "$0")
expiry=${HS_EXPIRY:-$here/expiry.sh}

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

verb=${1:-}; action=${2:-}; name=${3:-}
case "$verb" in plan|start) ;; *) echo "usage: expiry-change.sh plan|start add <name> --date <YYYY-MM-DD> [--renew <text>] | remove <name>" >&2; exit 1 ;; esac
case "$action" in add|remove) ;; *) refuse "unknown action (add or remove)" ;; esac
[ -n "$name" ] || refuse "a name is needed"
[[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9\ ._()-]{0,60}$ ]] || refuse "invalid name (letters, digits, spaces and . _ ( ) -)"
shift 3
date="" renew=""
if [ "$action" = add ]; then
  while [ $# -gt 0 ]; do
    case "$1" in
      --date)  date=${2:-}; shift 2 || refuse "--date needs a value" ;;
      --renew) renew=${2:-}; shift 2 || refuse "--renew needs a value" ;;
      *) refuse "unknown option $1" ;;
    esac
  done
  if [ -z "$date" ]; then printf 'status\tneeds\nneeds\tdate\n'; exit 2; fi
  [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && date -u -d "$date" +%s >/dev/null 2>&1 || refuse "'$date' is not a date. Use YYYY-MM-DD."
  [[ "$renew" != *$'\t'* && "$renew" != *$'\n'* && ${#renew} -le 120 ]] || refuse "the renewal hint is one line of at most 120 characters"
else
  [ $# -eq 0 ] || refuse "unexpected extra arguments"
fi

exists=false
if bash "$expiry" --list 2>/dev/null | awk -F'\t' -v n="$name" '$1 == n { f = 1 } END { exit !f }'; then exists=true; fi
if [ "$action" = add ]; then cmd=(bash "$expiry" add "$name" "$date"); [ -z "$renew" ] || cmd+=("$renew")
else
  $exists || refuse "There is no entry called '$name'."
  cmd=(bash "$expiry" remove "$name")
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
if [ "$action" = add ]; then
  printf 'heading\tadd %s to the expiry dates\n' "$name"
  printf 'step\twrite down that %s runs out on %s\n' "$name" "$date"
  [ -z "$renew" ] || printf 'step\tkeep the hint: %s\n' "$renew"
  $exists && printf 'warn\t%s is on the list already: its date and hint are replaced.\n' "$name"
  printf 'note\tThe health check warns 30 days and 7 days before the date, and once it has passed.\n'
else
  printf 'heading\tremove %s from the expiry dates\n' "$name"
  printf 'step\ttake %s off the list\n' "$name"
  printf 'note\tThe health check stops watching it. Add it again any time.\n'
fi
printf 'command\t%s\n' "${cmd[*]}"
printf 'long\tno\n'
