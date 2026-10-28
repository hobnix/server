#!/usr/bin/env bash
# help: take a data disk out of /bulk to work on it by hand (a file manager, Windows), and put it back; hs disk <member> detach | attach
# help.de: eine Datenplatte aus /bulk herausnehmen, um von Hand daran zu arbeiten (Dateimanager, Windows), und wieder einsetzen; hs disk <Mitglied> detach | attach
# args: run detach|attach <member> | plan|start detach|attach <member> [--confirm <member>]
# Why: while a disk is part of /bulk its files and the pool's are the same files, so copying from the disk into /bulk (mv, cp, Midnight Commander) truncates them.
# A DETACHED disk is not in the pool: copying from it into /bulk is an ordinary copy and safe. For moving folders between disks use `hs disk <member> move`, to empty a disk
# `hs pool bulk close --drain`; detach is for work with a tool of your own.
#   plan detach|attach <member>   what would happen, as data (hs sys disk plan detach|attach <member>): status ok|refused, reason | heading|step|note|warn, confirm_name, long
#   start detach <member>         take the disk out of /bulk and /mnt/bulk/pool, mount it where detached disks live, remember the time (needs --confirm <member>)
#   start attach <member>         put it back: the mark goes, bulk-mount.sh mounts it into /bulk again (refused while something uses it)
# A detached disk stays in the array: its mark /var/lib/hs/detached/<member> holds the time; bulk-mount.sh keeps it out of the merge; the parity sync is skipped
# (bulk-sync.sh); the health check complains after 2 hours (HS_DETACH_MAX, seconds). Its files are missing in /bulk meanwhile (services see them gone).
# Test knobs: HS_STATE_DIR, HS_DISKS_ROOT, HS_DETACHED_ROOT, HS_RAW_POOL, HS_BULK_MOUNT (stand-in), HS_DETACH_TEST=1 (no mounts, a folder counts as a mounted disk), HS_LOCK, HS_LOCK_ADMIN.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)   # absolute
. "$here/lib/bulkpath.sh"
state=${HS_STATE_DIR:-/var/lib/hs}
detdir=$state/detached
recdir=$state/recovering
rawpool=${HS_RAW_POOL:-/mnt/bulk/pool}
bulkmount=${HS_BULK_MOUNT:-$here/bulk-mount.sh}
testmode=${HS_DETACH_TEST:-0}

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }
ismnt() { if [ "$testmode" = 1 ]; then [ -d "$1" ]; else mountpoint -q "$1" 2>/dev/null; fi; }

# marks: what is out of the pool by hand, for the interface: member, detached|recovering, since (epoch seconds)
if [ "${1:-}" = marks ]; then
  for f in "$detdir"/*; do [ -f "$f" ] && printf '%s\tdetached\t%s\n' "${f##*/}" "$(cat "$f")"; done
  for f in "$recdir"/*; do [ -f "$f" ] && printf '%s\trecovering\t%s\n' "${f##*/}" "$(stat -c %Y "$f")"; done
  exit 0
fi

verb=${1:-}; action=${2:-}; member=${3:-}
case "$verb" in plan|start|run) ;; *) echo "usage: disk-detach.sh run|plan|start detach|attach <member>" >&2; exit 1 ;; esac
case "$action" in detach|attach) ;; *) refuse "unknown action (detach or attach)" ;; esac
[ $# -ge 3 ] && shift 3 || shift $#
[[ "$member" =~ ^data-[0-9]+$ ]] || refuse "that is not a data disk of the array (data-NN)"
confirm=""
while [ $# -gt 0 ]; do
  case "$1" in
    --confirm) [ $# -ge 2 ] || refuse "--confirm needs a value"; confirm=$2; shift 2 ;;
    *) refuse "unknown option $1" ;;
  esac
done

dir=$(disk_dir "$member")          # where a disk of the pool is mounted
ddir=$(detached_dir "$member")     # where a detached disk is mounted
mark=$detdir/$member
[ ! -e "$recdir/$member" ] || refuse "$member is out of the pool for a recovery (hs sys disk start $member recover-finish gives it back)."

if [ "$action" = detach ]; then
  [ ! -e "$mark" ] || refuse "$member is detached already."
  ismnt "$dir" || refuse "$member is not mounted (is the disk there and unlocked?)."
  others=0
  for d in "$(disks_root)"/data-*; do
    n=${d##*/}; [ -d "$d" ] && [ "$n" != "$member" ] && [ ! -e "$detdir/$n" ] && [ ! -e "$recdir/$n" ] && ismnt "$d" && others=$((others + 1))
  done
  [ "$others" -gt 0 ] || refuse "no other data disk would keep /bulk running."
else
  [ -e "$mark" ] || refuse "$member is not detached."
fi

plan_lines() {
  echo "status	ok"
  if [ "$action" = detach ]; then
    printf 'heading\tdetach %s: take it out of /bulk to work on it by hand\n' "$member"
    printf 'step\ttake %s out of /bulk and /mnt/bulk/pool: its files are no longer shown there\n' "$member"
    [ "$ddir" = "$dir" ] || printf 'step\tmount it at %s (a plain disk from now on)\n' "$ddir"
    printf 'step\tremember the time: the health check says so when it is still detached after 2 hours\n'
    printf 'note\tA detached disk is not part of the pool: copying from %s into /bulk is an ordinary copy and safe. To move folders between disks use hs disk %s move, to empty a disk hs pool bulk close --drain.\n' "$ddir" "$member"
    printf 'note\tThe parity sync is skipped while a disk is detached. Give it back with hs sys disk start attach %s (web: Pool page).\n' "$member"
    printf 'warn\tThe files of %s are missing in /bulk meanwhile: Jellyfin, the arr apps and the shares do not see them.\n' "$member"
    printf 'confirm_name\t%s\nlong\tno\n' "$member"
  else
    printf 'heading\tattach %s: put it back into /bulk\n' "$member"
    [ "$ddir" = "$dir" ] || printf 'step\tunmount it from %s (refused while something uses it)\n' "$ddir"
    printf 'step\tmount it into /bulk again: its files are shown there again\n'
    printf 'long\tno\n'
  fi
}
if [ "$verb" = plan ]; then plan_lines; exit 0; fi

if [ "$verb" = run ]; then
  . "$here/lib/ui.sh"
  while IFS=$'\t' read -r k v; do
    case "$k" in heading) step "$v" ;; step) line "$v" ;; note) note "$v" ;; warn) warn "$v" ;; esac
  done < <(plan_lines)
  [ -t 0 ] || fail "a person has to confirm this: run it at a terminal"
  if [ "$action" = detach ]; then confirm_name "$member" "the name of the disk" || { echo "cancelled"; exit 1; }; fi
  confirm=$member
fi

# ---- start ----
if [ "$action" = detach ] && [ "$confirm" != "$member" ]; then refuse "type the name to confirm: $member"; fi
. "$here/lib/bulklock.sh"
bulk_lock_admin 60
mkdir -p "$detdir"

if [ "$action" = detach ]; then
  if [ "$testmode" != 1 ]; then
    for m in /bulk "$rawpool"; do
      mountpoint -q "$m" 2>/dev/null && setfattr -n user.mergerfs.branches -v "-$dir" "$m/.mergerfs" 2>/dev/null || true
    done
  fi
  date +%s > "$mark"
  if [ "$ddir" != "$dir" ]; then
    if [ "$testmode" != 1 ]; then
      if ! umount "$dir" 2>/dev/null; then
        rm -f "$mark"; bash "$bulkmount" >/dev/null 2>&1 || true
        refuse "$member is in use (something has files open on it); nothing was changed."
      fi
      mkdir -p "$ddir"
      mount -o noatime "LABEL=bulk-$member" "$ddir" || { rm -f "$mark"; bash "$bulkmount" >/dev/null 2>&1 || true; refuse "the disk could not be mounted at $ddir; it is back in the pool."; }
    else
      mkdir -p "$ddir"
    fi
  fi
  echo "$member is detached: it is out of /bulk. Its files are at $ddir; give it back with: hs sys disk start attach $member"
  printf 'status\tdone\npath\t%s\n' "$ddir"
  exit 0
fi

# attach
if [ "$ddir" != "$dir" ] && [ "$testmode" != 1 ]; then
  umount "$ddir" 2>/dev/null || refuse "$member is in use (something has files open on $ddir); close them first."
  rmdir "$ddir" 2>/dev/null || true
fi
rm -f "$mark"
[ "$testmode" = 1 ] || bash "$bulkmount" >/dev/null 2>&1 || refuse "the mark is gone, but the disk could not be mounted into /bulk (look at: hs pool bulk)"
echo "$member is back in /bulk."
printf 'status\tdone\n'
