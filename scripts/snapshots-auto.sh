#!/usr/bin/env bash
# help: automatic ZFS snapshots of the shares (24 hourly, 7 daily, 4 weekly); ZFS layout, needs shareSnapshots = true;
# help.de: automatische ZFS-Schnappschüsse der Freigaben (24 stündliche, 7 tägliche, 4 wöchentliche); Bauart zfs, braucht shareSnapshots = true;
# args: [run | <share> on|off | list] [--dry-run]
# `run` (the timer, hourly) takes auto-h-<date+hour>, the first of a day also auto-d-<date>, the first of a week
# auto-w-<year>W<week>, then deletes the oldest ones beyond 24 / 7 / 4 per share. Shares listed in
# /var/lib/hs/snapshots-off are skipped (created with pelican-backups in it: big and replaceable).
# `hs share <share> snapshots` shows them next to the manual ones. HS_ZFS, HS_NOW (epoch), HS_STATE_DIR,
# HS_BULK_TYPE, HS_BULK_POOL, HS_LOCKED_MARKER, HS_SNAPSHOTS_SWITCH point tests at stand-ins.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
zfs=${HS_ZFS:-zfs}
pool=${HS_BULK_POOL:-bulk}
state=${HS_STATE_DIR:-/var/lib/hs}
off_file=$state/snapshots-off
switch=${HS_SNAPSHOTS_SWITCH:-/etc/hs/share-snapshots}
locked=${HS_LOCKED_MARKER:-/run/hs/storage-locked}
keep_h=24; keep_d=7; keep_w=4

usage() {
  say "usage: hs snapshots [run] [--dry-run]       take and prune the automatic snapshots now"
  say "       hs share <share> auto on|off          include a share or leave it out"
  say "       hs snapshots list                     shares and whether they are included"
  exit 1
}
dry=false; args=()
for a in "$@"; do
  case "$a" in --dry-run) dry=true ;; *) args+=("$a") ;; esac
done
set -- ${args[@]+"${args[@]}"}

bulk_type=${HS_BULK_TYPE:-$(cat /etc/hs/bulk-type 2>/dev/null || echo zfs)}
[ "$bulk_type" = zfs ] || { note "This server keeps /bulk on SnapRAID: there are no snapshots. The backup is the history."; exit 0; }

shares() {   # name<TAB>dataset of every share
  local kind ds
  for kind in shares sensitive; do
    "$zfs" list -H -o name -d 1 -r "$pool/$kind" 2>/dev/null | while read -r ds; do
      [ "$ds" != "$pool/$kind" ] || continue
      printf '%s\t%s\n' "${ds##*/}" "$ds"
    done
  done
}
is_off() { grep -qxF -- "$1" "$off_file" 2>/dev/null; }
init_off() { [ -f "$off_file" ] || { mkdir -p "$state" 2>/dev/null && echo pelican-backups > "$off_file"; } 2>/dev/null || true; }

mode=${1:-run}
case "$mode" in
  list)
    init_off
    if [ -t 1 ] && [ -z "${HS_CALLER:-}" ]; then
      # a person at a terminal: summary line and table; a pipe gets the tab separated lines below
      if [ "$(cat "$switch" 2>/dev/null || echo off)" = on ]; then status_line "Automatic snapshots" "on" ok
      else status_line "Automatic snapshots" "off" warn; fi
      { thead 'Share' 'Included'
        shares | while IFS=$'\t' read -r name ds; do
          printf '%s\t%s\n' "$name" "$(is_off "$name" && echo off || echo on)"
        done; } | table
      exit 0
    fi
    printf 'switch\t%s\n' "$(cat "$switch" 2>/dev/null || echo off)"
    shares | while IFS=$'\t' read -r name ds; do
      printf '%s\t%s\n' "$name" "$(is_off "$name" && echo off || echo on)"
    done
    exit 0 ;;
  run) ;;
  *)
    # hs share <share> auto on|off
    [ $# -eq 2 ] || usage
    name=$1
    shares | cut -f1 | grep -qxF -- "$name" || fail "$(t "No share called '%s'." "$name")"
    init_off
    case "$2" in
      on)  grep -vxF -- "$name" "$off_file" > "$off_file.new" || true; mv "$off_file.new" "$off_file"
           ok "$(t 'The share %s is included in the automatic snapshots.' "$name")" ;;
      off) is_off "$name" || echo "$name" >> "$off_file"
           ok "$(t 'The share %s is left out of the automatic snapshots.' "$name")" ;;
      *) usage ;;
    esac
    exit 0 ;;
esac

if [ "$(cat "$switch" 2>/dev/null || echo off)" != on ] && [ -z "${HS_FORCE:-}" ]; then
  note "Automatic snapshots are off. Switch them on: hs config set shareSnapshots true"
  exit 0
fi
[ ! -e "$locked" ] || { note "The encrypted storage is locked: no snapshots taken."; exit 0; }
init_off

now=${HS_NOW:-$(date +%s)}
stamp_h=$(date -d "@$now" +%Y%m%d%H)
stamp_d=$(date -d "@$now" +%Y%m%d)
stamp_w=$(date -d "@$now" +%GW%V)
taken=0; pruned=0
step "Automatic snapshots"

for_each_share() { shares | while IFS=$'\t' read -r name ds; do is_off "$name" || printf '%s\t%s\n' "$name" "$ds"; done; }

while IFS=$'\t' read -r name ds; do
  existing=$("$zfs" list -H -t snapshot -o name -d 1 "$ds" 2>/dev/null | sed 's/^[^@]*@//' || true)
  for want in "auto-h-$stamp_h" "auto-d-$stamp_d" "auto-w-$stamp_w"; do
    grep -qxF -- "$want" <<<"$existing" && continue
    if $dry; then echo "would take $ds@$want"; else "$zfs" snapshot "$ds@$want"; fi
    taken=$((taken + 1))
    existing=$existing$'\n'$want
  done
  for kind in h:$keep_h d:$keep_d w:$keep_w; do
    p=auto-${kind%%:*}-; keep=${kind##*:}
    # names sort by time; everything but the newest $keep goes
    old=$(grep "^$p" <<<"$existing" | sort | head -n -"$keep" || true)
    for s in $old; do
      if $dry; then echo "would delete $ds@$s"; elif "$zfs" destroy "$ds@$s" 2>/dev/null; then :; else warn "$(t 'Could not delete %s (a clone or hold?)' "$ds@$s")"; continue; fi
      pruned=$((pruned + 1))
    done
  done
done < <(for_each_share)

ok "$(t 'Snapshots: %s taken, %s old ones deleted.' "$taken" "$pruned")"
