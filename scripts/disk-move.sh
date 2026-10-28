#!/usr/bin/env bash
# help: move a folder (or file) from one data disk of the array to another, disk to disk; the path in /bulk stays the same
# help.de: einen Ordner (oder eine Datei) von einer Datenplatte des Arrays auf eine andere verschieben, von Platte zu Platte; der Pfad in /bulk bleibt gleich
# args: run <member> <path> [--to <member>] | plan|start <member> --path <path> [--to <member>] [--now] | ls <member> [--path <path>]
# Why not mv or Midnight Commander: while a disk is a branch of /bulk, /mnt/bulk/data-NN/shares/x/f and /bulk/shares/x/f are the SAME file. A copy from the
# disk into the pool opens the existing file for writing (it is truncated), and a move then deletes it. Here both sides are real disks (data-04 -> data-05),
# so the copy is a plain copy, and /bulk shows the same files at the same paths the whole time (a file that is on both disks is shown once).
#
#   run <member> <path>   for a person at a terminal: shows the plan, asks, starts the job; hs pool bulk move
#   plan                  what would happen, as data (hs sys disk plan move <member> --path <path> [--to <member>]): status ok|refused, reason | heading|step|note|warn, long, target
#   start                 starts the copy as a background job (the job is `start ... --now`); the files are removed from the source disk only after they are on the target
#   ls <member> [--path]  one folder level of a disk for the interface: type<TAB>bytes<TAB>name (d or f); no path = shares and sensitive
# <path> is relative to the disk and starts with shares/ or sensitive/ (e.g. shares/media/movies/Avatar). The target is an open data disk with room; without --to
# the one with the most free space. A file that exists on the target already is never overwritten (it stays on the source disk and is counted).
# Test knobs: HS_BULK_BASE, HS_STATE_DIR, HS_BULK_CLOSED, HS_MOVE_TEST=1 (every folder under the base counts as a mounted disk), HS_LOCK, HS_LOCK_ADMIN.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)   # absolute: the background job runs from another folder
. "$here/lib/bulkpath.sh"
base=${HS_BULK_BASE:-$(disks_root)}
state=${HS_STATE_DIR:-/var/lib/hs}
closed_file=${HS_BULK_CLOSED:-$state/bulk-closed}
recdir=$state/recovering
testmode=${HS_MOVE_TEST:-0}

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }
human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 B"; }
ismnt() { if [ "$testmode" = 1 ]; then [ -d "$1" ]; else mountpoint -q "$1" 2>/dev/null; fi; }
avail_of() { df -B1 --output=avail "$1" 2>/dev/null | tail -n1 | tr -d ' '; }
is_closed() { grep -qx "$1" "$closed_file" 2>/dev/null; }

verb=${1:-}; member=${2:-}
case "$verb" in plan|start|ls|run) ;; *) echo "usage: disk-move.sh run|plan|start|ls <member> ..." >&2; exit 1 ;; esac
[ $# -ge 2 ] && shift 2 || shift $#
[[ "$member" =~ ^data-[0-9]+$ ]] || refuse "that is not a data disk of the array (data-NN)"
path="" to="" now=no
if [ "$verb" = run ] && [ $# -ge 1 ] && [[ "$1" != --* ]]; then path=$1; shift; fi
while [ $# -gt 0 ]; do
  case "$1" in
    --path) [ $# -ge 2 ] || refuse "--path needs a value"; path=$2; shift 2 ;;
    --to)   [ $# -ge 2 ] || refuse "--to needs a value"; to=$2; shift 2 ;;
    --now)  now=yes; shift ;;
    *) refuse "unknown option $1" ;;
  esac
done
[ -z "$to" ] || [[ "$to" =~ ^data-[0-9]+$ ]] || refuse "--to is a data disk (data-NN)"
path=${path%/}
if [ -n "$path" ]; then
  [[ "$path" != *[[:cntrl:]]* ]] || refuse "the path has a control character"
  case "/$path/" in */../*|*//*|*/./*) refuse "the path must not contain .. or empty parts" ;; esac
  [ "${path:0:1}" != / ] || refuse "the path is relative to the disk (shares/...)"
fi

mdir=$base/$member
ismnt "$mdir" || refuse "$member is not mounted (is it out for a recovery, or missing?)."
[ ! -e "$recdir/$member" ] || refuse "$member is out of the pool for a recovery."

# ---- ls: one level of a disk for the interface ----
if [ "$verb" = ls ]; then
  if [ -z "$path" ]; then
    for t in shares sensitive; do [ -d "$mdir/$t" ] && printf 'd\t\t%s\n' "$t"; done
    exit 0
  fi
  case "$path" in shares|shares/*|sensitive|sensitive/*) ;; *) refuse "only shares/ and sensitive/ can be listed" ;; esac
  dir=$mdir/$path
  [ -d "$dir" ] && [ ! -L "$dir" ] || refuse "no such folder on $member"
  find "$dir" -mindepth 1 -maxdepth 1 ! -type l -printf '%y\t%s\t%f\n' 2>/dev/null | LC_ALL=C sort -t$'\t' -k1,1 -k3,3 \
    | awk -F'\t' 'BEGIN { OFS = "\t" } $3 !~ /[[:cntrl:]]/ && NR <= 500 { print ($1 == "d" ? "d" : "f"), ($1 == "d" ? "" : $2), $3 }'
  exit 0
fi

# ---- the checks of plan / start / run ----
[ -n "$path" ] || refuse "say what to move: --path shares/<folder>"
case "$path" in shares/*|sensitive/*) ;; *) refuse "only folders and files below shares/ or sensitive/ can be moved" ;; esac
src=$mdir/$path
[ -e "$src" ] || refuse "there is no $path on $member"
[ ! -L "$src" ] || refuse "$path is a link"
real=$(readlink -f "$src"); rootreal=$(readlink -f "$mdir")
case "$real/" in "$rootreal"/*) ;; *) refuse "$path is not on $member" ;; esac

size=$(timeout 60 du -sb "$src" 2>/dev/null | cut -f1 || true); size=${size:-0}
need=$((size + 10 * 1024 * 1024 * 1024))

pick=""; best=0
for d in "$base"/data-*; do
  [ -d "$d" ] || continue
  n=${d##*/}
  [ "$n" != "$member" ] || continue
  [ -z "$to" ] || [ "$n" = "$to" ] || continue
  ismnt "$d" || continue
  [ ! -e "$recdir/$n" ] || continue
  if [ -z "$to" ] && is_closed "$n"; then continue; fi
  a=$(avail_of "$d"); [ "${a:-0}" -gt "$best" ] && { best=$a; pick=$n; }
done
if [ -n "$to" ]; then
  [ "$to" != "$member" ] || refuse "the target is the disk the files are on."
  is_closed "$to" && refuse "$to is closed: it takes no new files. Open it first (hs pool bulk open $to)."
  [ -n "$pick" ] || refuse "$to is not mounted, or it is out for a recovery."
else
  [ -n "$pick" ] || refuse "no other open data disk is mounted to take the files."
fi
to=$pick; tdir=$base/$to
[ "$best" -ge "$need" ] || refuse "$to has $(human "$best") free; moving $(human "$size") needs that plus 10 GiB of room."
dst=$tdir/$path

plan_lines() {
  echo "status	ok"
  printf 'heading\tmove %s (%s) from %s to %s\n' "$path" "$(human "$size")" "$member" "$to"
  printf 'step\tcopy the files from %s to %s with the same path (disk to disk, the pool is not involved)\n' "$member" "$to"
  printf 'step\tremove each file from %s once it is on %s; a file that %s already has is left where it is, never overwritten\n' "$member" "$to" "$to"
  printf 'note\t/bulk shows the same files at the same paths the whole time. To change the folder or share they belong to, rename them inside /bulk afterwards (hs share ... or the file manager, always /bulk to /bulk).\n'
  printf 'note\tThe parity sync and the cache mover wait until this is done.\n'
  [ "$size" -gt 0 ] || printf 'note\tThe size could not be measured quickly; the room on %s is checked while copying.\n' "$to"
  printf 'command\trsync -aHAXR --ignore-existing --remove-source-files ./%s %s/\n' "$path" "$tdir"
  if [ "$size" -gt $((20 * 1024 * 1024 * 1024)) ]; then echo "long	yes"; else echo "long	no"; fi
  printf 'target\t%s\n' "$to"
}
if [ "$verb" = plan ]; then plan_lines; exit 0; fi

if [ "$verb" = run ]; then
  . "$here/lib/ui.sh"
  while IFS=$'\t' read -r k v; do
    case "$k" in heading) step "$v" ;; step) line "$v" ;; note) note "$v" ;; command) note "$v" ;; esac
  done < <(plan_lines)
  [ -t 0 ] || fail "a person has to confirm this: run it at a terminal"
  confirm "Start moving it?" || { echo "cancelled"; exit 1; }
fi

# ---- start ----
if [ "$now" != yes ]; then
  . "$here/lib/job.sh"
  unit=$(hs_job "disk-move-$member" "move $path from $member to $to" -- bash "$here/disk-move.sh" start "$member" --path "$path" --to "$to" --now) || refuse "the job could not be started"
  printf 'status\tstarted\nunit\t%s\n' "$unit"
  exit 0
fi

. "$here/lib/bulklock.sh"
bulk_lock_admin 60
echo "Moving $path ($(human "$size")) from $member to $to."
mkdir -p "$(dirname "$dst")"
cd "$mdir"
rc=0
rsync -aHAXR --ignore-existing --remove-source-files --no-inc-recursive --info=progress2,name1 "./$path" "$tdir/" || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "The copy stopped (rsync exit $rc). Nothing was removed from $member that is not on $to. Start it again to go on."
  exit 1
fi
[ ! -d "$src" ] || find "$src" -depth -type d -empty -delete 2>/dev/null || true
left=0
[ ! -e "$src" ] || left=$(find "$src" -type f 2>/dev/null | wc -l)
if [ "$left" -gt 0 ]; then
  echo "$left file(s) stayed on $member because $to already has a file of that name. Look at them: $src"
fi
echo "Done: $path is on $to now."
printf 'status\tdone\nleft\t%s\n' "$left"
