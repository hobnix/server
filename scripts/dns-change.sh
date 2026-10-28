#!/usr/bin/env bash
# help: bring the DNS names of the instances up to date without asking anything: what would change (plan), then do it as a background job (start)
# help.de: die DNS-Namen der Instanzen auf den neuesten Stand bringen, ohne etwas zu fragen: was sich ändern würde (plan), dann als Hintergrundjob ausführen (start)
# args: plan|start sync
# System command (hs sys dns plan|start): for the interface and tests. It never asks and prints plain key<TAB>value lines like
# backup-change.sh. The work is dns.sh's (`sync --plain` lists the changes, `sync --yes` makes them); nothing outside <siteName>.<domain> is touched.
#   sync   create, correct and remove the names of the instances; the plan lists each record
# plan: exit 0 = allowed, 1 = refused (no domain, no controller, nothing to do). Output: status ok|refused, reason<TAB><text>,
#   heading|step|note|warn|command<TAB><line>, long<TAB>yes.
# start: the same checks, then the work runs as a background job (status started, unit).
# Test knobs: HS_DNS (stand-in for dns.sh).
set -euo pipefail
here=$(dirname "$0")
dns=${HS_DNS:-$here/dns.sh}

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

verb=${1:-}; action=${2:-}
case "$verb" in plan|start) ;; *) echo "usage: dns-change.sh plan|start sync" >&2; exit 1 ;; esac
[ "$action" = sync ] || refuse "unknown action (sync)"
[ $# -eq 2 ] || refuse "unexpected extra arguments"

export HS_PLAIN=1 HS_LANG=en HS_CALLER=${HS_CALLER:-ui}
unset HS_GUIDED_TTY

rc=0
out=$(bash "$dns" sync --plain </dev/null 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then
  refuse "$(printf '%s' "$out" | sed -e 's/^[[:space:]]*//' -e 's/^[✗!] *//' | awk 'NF' | tail -n 1)"
fi
[ -n "$out" ] || refuse "The names are up to date: nothing to change."

cmd=(bash "$dns" sync --yes)
if [ "$verb" = start ]; then
  . "$here/lib/job.sh"
  unit=$(hs_job dns-sync "hs dns sync" -- "${cmd[@]}") || refuse "the job could not be started"
  printf 'status\tstarted\nunit\t%s\n' "$unit"
  exit 0
fi

n=$(printf '%s\n' "$out" | awk 'NF { c++ } END { print c + 0 }')
printf 'status\tok\nheading\tsync the DNS names of the instances\n'
while IFS=$'\t' read -r act name type value old; do
  [ -n "$act" ] || continue
  case "$act" in
    add)    printf 'step\tadd %s (%s) = %s\n' "$name" "$type" "$value" ;;
    change) printf 'step\tchange %s (%s) from %s to %s\n' "$name" "$type" "$old" "$value" ;;
    remove) printf 'step\tremove %s (%s = %s)\n' "$name" "$type" "$value" ;;
  esac
done <<<"$out"
if printf '%s\n' "$out" | grep -q '^remove'; then
  printf 'warn\tNames that no running instance needs any more are removed.\n'
fi
printf 'note\t%s record(s) change, only below the server'"'"'s own name in the domain; nothing else in the DNS is touched.\n' "$n"
printf 'command\t%s\n' "${cmd[*]}"
printf 'long\tyes\n'
exit 0
