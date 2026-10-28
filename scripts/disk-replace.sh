#!/usr/bin/env bash
# help: swap a failed or old disk: finds the member that is not ONLINE, you pick the new disk, the pool command does the rest
# help.de: Platte tauschen (defekt oder alt): findet das Mitglied, das nicht ONLINE ist, du wählst die neue Platte, den Rest macht der Pool-Befehl
# args: [--pool <pool>] [--member <name>] [--disk <by-id name>] [--dry-run]
# A guided front for `hs pool <pool> replace`: it only asks what is missing (which member, which new disk),
# then runs manage-pool.sh --replace, which shows the plan, asks the questions of the pool (filesystem,
# encryption) and the typed confirmation. HS_MANAGE_POOL points tests at a stand-in.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
mp=${HS_MANAGE_POOL:-$here/manage-pool.sh}

usage() {
  say "usage: hs disk replace [--pool <pool>] [--member <name>] [--disk <by-id name>] [--dry-run]"
  exit 1
}

pool=""; member=""; disk=""; dry=false
while [ $# -gt 0 ]; do
  case "$1" in
    --pool)   [ $# -ge 2 ] || usage; pool=$2; shift 2 ;;
    --member) [ $# -ge 2 ] || usage; member=$2; shift 2 ;;
    --disk)   [ $# -ge 2 ] || usage; disk=$2; shift 2 ;;
    --dry-run) dry=true; shift ;;
    *) usage ;;
  esac
done

# the pool: the one that has a member that is not ONLINE, else bulk
if [ -z "$pool" ]; then
  for p in bulk fast; do
    if bash "$mp" "$p" --members 2>/dev/null | awk -F'\t' '$3 != "ONLINE" { f = 1 } END { exit !f }'; then pool=$p; break; fi
  done
  pool=${pool:-bulk}
fi
members=$(bash "$mp" "$pool" --members 2>/dev/null || true)
[ -n "$members" ] || fail "$(t "No members found in '%s'. Is the pool set up? (hs pool %s)" "$pool" "$pool")"

if [ -z "$member" ]; then
  bad=$(awk -F'\t' '$3 != "ONLINE" { print $1 }' <<<"$members")
  if [ "$(grep -c . <<<"$bad")" = 1 ]; then
    member=$bad
    note "$(t '%s is not ONLINE: that one is replaced.' "$member")"
  else
    mapfile -t opts < <(awk -F'\t' '{ printf "%s  (%s, %s)\n", $1, $3, $4 }' <<<"$members")
    [ -t 0 ] || fail "Say which member to replace: --member <name>"
    member=$(choose "Which disk is replaced?" "${opts[@]}") || exit 1
    member=${member%% *}
  fi
fi
msize=$(awk -F'\t' -v m="$member" '$1 == m { print $2; exit }' <<<"$members")
[ -n "$msize" ] || fail "$(t "'%s' is not a member of %s." "$member" "$pool")"

if [ -z "$disk" ]; then
  free=$(bash "$mp" --list-disks 2>/dev/null || true)
  # only disks at least as big as the one they replace (the pool command checks again)
  mapfile -t opts < <(awk -F'\t' -v min="${msize:-0}" '$2 >= min { printf "%s  (%s)\n", $1, $3 }' <<<"$free")
  [ ${#opts[@]} -gt 0 ] || fail "No free disk that is large enough was found. Plug the new disk in first."
  [ -t 0 ] || fail "Say which disk: --disk <by-id name>"
  disk=$(choose "Which disk is the new one? (it will be erased)" "${opts[@]}") || exit 1
  disk=${disk%% *}
fi

note "$(t 'The same without questions: hs pool %s replace %s --disks %s' "$pool" "$member" "$disk")"
args=("$pool" --replace "$member" --disks "$disk")
$dry && args+=(--dry-run)
exec bash "$mp" "${args[@]}"
