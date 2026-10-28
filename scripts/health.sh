#!/usr/bin/env bash
# help: the problems of the health check, each with the command that helps; "test" sends a test message
# help.de: die Probleme der Gesundheitsprüfung, jedes mit dem passenden Befehl; "test" schickt eine Testnachricht
# args: [test|next]
#
# Machine-readable mode (registry row `hs sys health next`):
#   health.sh next    one line per current problem: PROBLEM<TAB>NEXT, no header, nothing when there
#                     are no problems; NEXT is the fix command `hs health` shows for it (the
#                     first `hs <words>` of it is what the interface runs). Exit status 0.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
hc=${HS_HEALTH_CHECK:-$here/health-check.sh}

if [ "${1:-}" = test ]; then bash "$hc" --test; exit 0; fi
next_only=false; [ "${1:-}" = next ] && next_only=true

out=$(bash "$hc" --dry-run 2>&1 | sed -n '1,/^$/p' | sed '/^$/d' || true)
if grep -q '^No problems found' <<<"$out"; then $next_only || status_line "Problems" "None" ok; exit 0; fi

# what to run for which kind of problem (first match wins)
hint() {
  case "$1" in
    *"hs share "*" perm"*)         echo "$1" | sed -E 's/.*(hs share [^ ]+ perm).*/\1/' ;;
    *"hs pool bulk replace"*)      echo "hs pool bulk replace" ;;
    *[Ll]ocked*|*unlock*)          echo "hs unlock" ;;
    *[Bb]ackup*)                   echo "hs backup status" ;;
    *"temp disk"*|*temp-disk*)     echo "hs disk temp eject" ;;
    *SMART*|*[Dd]isk*|*BAD*|*WATCH*) echo "hs disk list" ;;
    *[Pp]arity*|*sync*|*SnapRAID*) echo "hs job list" ;;
    *[Pp]ool*|*DEGRADED*|*FAULTED*|*ONLINE*) echo "hs pool bulk" ;;
    *full*|*"free space"*|*space*) echo "hs share list" ;;
    *[Jj]ob*|*failed*|*unit*)      echo "hs job list" ;;
    *)                             echo "hs doctor" ;;
  esac
}
rows=""
while IFS= read -r l; do
  [ -n "$l" ] || continue
  rows+="$l"$'\t'"$(hint "$l")"$'\n'
done <<<"$out"
if $next_only; then printf '%s' "$rows"; exit 0; fi
status_line "Problems" "$(printf '%s' "$rows" | grep -c .)" bad
echo
{ thead 'Problem' 'Next'; printf '%s' "$rows"; } | table
exit 1
