#!/usr/bin/env bash
# help: move from an old server (Unraid) step by step: look at the disks, unlock, adopt, publish shares, parity, first sync
# help.de: Umzug von einem alten Server (Unraid) Schritt für Schritt: Platten ansehen, entsperren, übernehmen, Freigaben, Parität, erster Sync
# args: [--status] [--step <name>] [--disks <id,...>] [--parity <id>] [--yes] [--reset]
# The runbook of docs/storage-and-disks.md as one resumable command. It only calls the commands that
# exist (hs migrate check, hs unlock, hs pool bulk add, hs share repair, hs pool bulk sync); each of them shows
# its own plan and asks its own confirmation. Done steps are remembered in /var/lib/hs/migrate.state.
# HS_BIN points tests at a stand-in for the hs dispatcher; HS_STATE_DIR at another state directory.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
state=${HS_STATE_DIR:-/var/lib/hs}/migrate.state
hsbin=${HS_BIN:-$here/lib/hs.sh}

steps="check unlock adopt shares parity sync"
title() {
  case "$1" in
    check)  t 'Look at the old disks (changes nothing)' ;;
    unlock) t 'Unlock encrypted disks' ;;
    adopt)  t 'Adopt the disks that hold the files' ;;
    shares) t 'Publish the folders as shares' ;;
    parity) t 'Add the parity disk' ;;
    sync)   t 'First parity sync' ;;
  esac
}

usage() {
  say "usage: hs migrate                        walk through the steps (asks before each one)"
  say "       hs migrate --status               which steps are done"
  say "       hs migrate --step <name>          one step: $steps"
  say "       --disks <id,...>  the disks to adopt   --parity <id>  the parity disk   --yes  do not ask before a step"
  say "       --reset           forget what is done"
  exit 1
}

only=""; disks=""; parity=""; yes=false; status=false; reset=false
while [ $# -gt 0 ]; do
  case "$1" in
    --step)   [ $# -ge 2 ] || usage; only=$2; shift 2 ;;
    --disks)  [ $# -ge 2 ] || usage; disks=$2; shift 2 ;;
    --parity) [ $# -ge 2 ] || usage; parity=$2; shift 2 ;;
    --yes)    yes=true; shift ;;
    --status) status=true; shift ;;
    --reset)  reset=true; shift ;;
    *) usage ;;
  esac
done
if [ -n "$only" ]; then case " $steps " in *" $only "*) ;; *) usage ;; esac; fi

done_step() { [ -f "$state" ] && grep -qx "$1" "$state"; }
mark() { mkdir -p "$(dirname "$state")"; done_step "$1" || echo "$1" >> "$state"; }
run() { note "$ hs $*"; HS_CALLER="" bash "$hsbin" "$@"; }

show_status() {
  local s mark_ n=0 total=0
  for s in $steps; do total=$((total + 1)); ! done_step "$s" || n=$((n + 1)); done
  if [ "$n" -eq "$total" ]; then status_line "Migration" "Finished" ok; else status_line "Migration" "$(t '%s of %s steps done' "$n" "$total")" warn; fi
  {
    thead 'Step' 'State' 'What'
    for s in $steps; do
      if done_step "$s"; then mark_=$(_tr 'done'); else mark_=$(_tr 'open'); fi
      printf '%s\t%s\t%s\n' "$s" "$mark_" "$(title "$s")"
    done
  } | table
}

if $reset; then rm -f "$state"; ok "Forgotten."; exit 0; fi
if $status; then show_status; exit 0; fi

do_step() {
  case "$1" in
    check)  run migrate check ;;
    unlock)
      if ! blkid -t TYPE=crypto_LUKS >/dev/null 2>&1; then note "No encrypted disk found: nothing to unlock."; return 0; fi
      run unlock ;;
    adopt)
      if [ -z "$disks" ]; then
        [ -t 0 ] || { warn "Say which disks: --disks <id,...> (see: hs migrate check)"; return 1; }
        disks=$(ask "Disks to adopt (by-id names, comma separated):")
      fi
      [ -n "$disks" ] || return 1
      run pool bulk add --role adopt --disks "$disks" ;;
    shares)
      run share repair
      note "New shares are open to Domain Admins only. Give people access with: hs share <share> perm" ;;
    parity)
      if [ -z "$parity" ]; then
        [ -t 0 ] || { warn "Say which disk: --parity <id>"; return 1; }
        parity=$(ask "Parity disk (by-id name, it will be erased):")
      fi
      [ -n "$parity" ] || return 1
      run pool bulk add --role parity --disks "$parity" ;;
    sync)   run pool bulk sync ;;
  esac
}

for s in $steps; do
  [ -z "$only" ] || [ "$only" = "$s" ] || continue
  if [ -z "$only" ] && done_step "$s"; then continue; fi
  step "$(title "$s")"
  if [ -z "$only" ] && ! $yes; then
    [ -t 0 ] || { note "Not a terminal: stopping before this step. Continue with: hs migrate --step $s"; exit 0; }
    confirm "Do this step now?" || { note "Stopped. Continue later with: hs migrate"; exit 0; }
  fi
  if do_step "$s"; then mark "$s"; ok "$(t 'Step done: %s' "$s")"; else warn "$(t 'Step not finished: %s. Run it again with: hs migrate --step %s' "$s" "$s")"; exit 1; fi
done
echo
show_status
