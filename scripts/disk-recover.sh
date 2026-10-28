#!/usr/bin/env bash
# help: get deleted files back from a data disk of the array (reads the whole disk, never writes to it); what is found goes onto another data disk
# help.de: gelöschte Dateien von einer Datenplatte des Arrays zurückholen (liest die ganze Platte, schreibt nie darauf); was gefunden wird, kommt auf eine andere Datenplatte
# args: run <member> [--to <member>] [--types media|all] | plan|start <member> [--to <member>] [--types media|all] [--confirm <member>] [--now] | finish <member>
# Carving (photorec): the file system of a deleted file is gone, so files are found by their content, not by name. XFS also clears the block list of a
# freed inode, so `xfs_undelete` finds nothing on a current kernel (tested). What comes back: whole files when they were written in one piece, cut-off
# files when they were fragmented, no names and no folders (videos and music are named by their tags afterwards), nothing for data without a signature.
#
#   run <member>      the same for a person at a terminal (shows the plan, asks for the name of the disk, starts the job); hs disk <member> recover
#   plan <member>     what would happen, as data (hs sys disk plan <member> recover): status ok|refused, reason | heading|step|note|warn|danger|command, confirm_name, long
#   start <member>    take the disk out of /bulk, make it read-only, search it as a background job (needs --confirm <member>); the job is `start ... --now`
#   finish <member>   give the disk back to the pool (hs sys disk start <member> recover-finish): the read-only mark and the "out for recovery" mark go
# Safety: photorec only reads; the device is set read-only (blockdev --setro) for the whole time; the disk stays out of the pool (scripts/bulk-mount.sh
# leaves a member alone while /var/lib/hs/recovering/<member> exists) until `finish`; the output goes to ANOTHER data disk, never the same device.
# Test knobs: HS_BULK_BASE, HS_STATE_DIR, HS_PHOTOREC (stand-in), HS_FFPROBE (stand-in), HS_BULK_MOUNT, HS_RECOVER_DEV (a file or device instead of the
# disk found by its label), HS_RECOVER_TEST=1 (no mount, no blockdev), HS_RECOVER_TICK (seconds between progress lines), HS_LOCK, HS_LOCK_ADMIN.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)   # absolute: the background job runs from another folder
. "$here/lib/bulkpath.sh"
base=${HS_BULK_BASE:-$(disks_root)}
rawpool=${HS_RAW_POOL:-/mnt/bulk/pool}   # the cache-free merge of the pool (not a disk)
state=${HS_STATE_DIR:-/var/lib/hs}
photorec=${HS_PHOTOREC:-photorec}
ffprobe=${HS_FFPROBE:-ffprobe}
bulkmount=${HS_BULK_MOUNT:-$here/bulk-mount.sh}
recdir=$state/recovering
testmode=${HS_RECOVER_TEST:-0}

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }
human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 B"; }

verb=${1:-}; member=${2:-}
case "$verb" in plan|start|finish|run) ;; *) echo "usage: disk-recover.sh run|plan|start|finish <member> [--to <member>] [--types media|all]" >&2; exit 1 ;; esac
[ $# -ge 2 ] && shift 2 || shift $#
[[ "$member" =~ ^data-[0-9]+$ ]] || refuse "that is not a data disk of the array (data-NN)"
to="" types=media confirm="" now=no
while [ $# -gt 0 ]; do
  case "$1" in
    --to)      [ $# -ge 2 ] || refuse "--to needs a value"; to=$2; shift 2 ;;
    --types)   [ $# -ge 2 ] || refuse "--types needs a value"; types=$2; shift 2 ;;
    --confirm) [ $# -ge 2 ] || refuse "--confirm needs a value"; confirm=$2; shift 2 ;;
    --now)     now=yes; shift ;;
    *) refuse "unknown option $1" ;;
  esac
done
[ -z "$to" ] || [[ "$to" =~ ^data-[0-9]+$ ]] || refuse "--to is a data disk (data-NN)"
case "$types" in media|all) ;; *) refuse "--types is media or all" ;; esac

dir=$base/$member
find_dev() {   # the file system device of the member, mounted or not (the label is bulk-<member>)
  if [ -n "${HS_RECOVER_DEV:-}" ]; then echo "$HS_RECOVER_DEV"; else blkid -L "bulk-$member" 2>/dev/null || true; fi
}
size_of() { if [ -b "$1" ]; then blockdev --getsize64 "$1"; else stat -c %s "$1"; fi; }
avail_of() { df -B1 --output=avail "$1" 2>/dev/null | tail -n1 | tr -d ' '; }
is_out() { [ -e "$recdir/$member" ]; }
ismnt() { if [ "$testmode" = 1 ]; then [ -d "$1" ]; else mountpoint -q "$1" 2>/dev/null; fi; }   # test mode: every folder counts as a mounted disk

# photorec file types of `--types media` (names as photorec spells them, checked against photorec 7.2: mov = mp4/mov/m4v/m4a, riff = avi/wav, asf = wmv;
# mp4, avi, wav, wmv, docx, xls, m4a, webp, heic are NOT names it knows and make it stop with a syntax error)
media_types="jpg png gif tif bmp mkv mov riff mpg asf flac ogg mp3 pdf zip rar 7z doc"

# ---- finish: give the disk back to the pool ----
if [ "$verb" = finish ]; then
  is_out || refuse "$member is not out of the pool for a recovery."
  . "$here/lib/bulklock.sh"
  exec 9>"$bulk_lock"
  flock -n 9 || refuse "the recovery of $member is still running."
  dev=$(find_dev)
  rm -f "$recdir/$member"
  [ "$testmode" = 1 ] || { [ -z "$dev" ] || blockdev --setrw "$dev" 2>/dev/null || true; }
  [ "$testmode" = 1 ] || bash "$bulkmount" >/dev/null 2>&1 || refuse "the disk is free again but could not be mounted (hs sys disk start $member recover-finish again, or look at hs pool bulk)"
  echo "$member is back in the pool."
  printf 'status\tdone\n'
  exit 0
fi

# ---- the checks every verb makes ----
dev=$(find_dev)
[ -n "$dev" ] && [ -e "$dev" ] || refuse "The disk $member was not found. An encrypted disk has to be unlocked first (hs unlock)."
command -v "$photorec" >/dev/null 2>&1 || refuse "photorec is not installed (package testdisk)."
fstype=$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)
devsize=$(size_of "$dev")
mounted=no; ismnt "$dir" && mounted=yes
used=""; free=""
if [ "$mounted" = yes ]; then
  used=$(df -B1 --output=used "$dir" | tail -n1 | tr -d ' '); free=$(avail_of "$dir")
fi

# target disk: another data disk that is mounted and not out for a recovery itself; the one with the most room when none is named
pick=""; best=0
for d in "$base"/data-*; do
  [ -d "$d" ] || continue
  n=${d##*/}
  [ "$n" != "$member" ] || continue
  [ -e "$recdir/$n" ] && continue
  ismnt "$d" || continue
  [ -z "$to" ] || [ "$n" = "$to" ] || continue
  a=$(avail_of "$d"); [ "${a:-0}" -gt "$best" ] && { best=$a; pick=$n; }
done
if [ -n "$to" ]; then
  [ "$to" != "$member" ] || refuse "the files cannot go onto the disk they are searched on."
  [ -n "$pick" ] || refuse "$to is not mounted, or it is out for a recovery itself."
else
  [ -n "$pick" ] || refuse "no other data disk is mounted to take the files."
fi
to=$pick; tdir=$base/$to
[ "$best" -ge $((10 * 1024 * 1024 * 1024)) ] || refuse "$to has only $(human "$best") free (at least 10 GiB are needed)."
if [ "$(findmnt -no SOURCE "$tdir" 2>/dev/null || true)" = "$dev" ]; then refuse "$to is the same disk."; fi
out=$tdir/shares/recovered

hours=$(( devsize / 150000000 / 3600 + 1 ))   # reading at about 150 MB/s, a rough guide

if [ "$verb" = plan ] || [ "$verb" = run ]; then
  plan_lines() {
    echo "status	ok"
    printf 'heading\trecover deleted files from %s (%s, %s)\n' "$member" "$(human "$devsize")" "${fstype:-unknown file system}"
    if [ "$mounted" = yes ]; then
      printf 'step\ttake %s out of /bulk (its files are not visible there until it is given back) and unmount it\n' "$member"
    fi
    printf 'step\tset the device read-only: nothing can write to %s any more, not even by mistake\n' "$member"
    printf 'step\tread the whole disk and look for deleted files by their content (%s)\n' "$( [ "$types" = media ] && echo "photos, videos, music, documents, archives" || echo "every kind photorec knows: slow, and thousands of junk files" )"
    printf 'step\tput what is found into %s/%s-<date> on %s, sorted by kind; videos and music are named by their tags\n' "$out" "$member" "$to"
    printf 'note\tThe names and folders of deleted files are gone for good: files come back as numbered files. A file that was written in pieces (fragmented) can come back cut off. Data without a recognisable beginning (a plain .bin) cannot be found.\n'
    printf 'note\t%s keeps all its data and stays out of the pool, read-only, until you give it back (hs sys disk start %s recover-finish). While it is out, the parity sync is skipped and the files on it are missing in /bulk.\n' "$member" "$member"
    [ -z "$free" ] || printf 'note\t%s still has %s unused space: about as much deleted data can be found. %s has %s free.\n' "$member" "$(human "$free")" "$to" "$(human "$best")"
    printf 'note\tThe whole disk is searched, so files that are still on it are found again as copies.\n'
    printf 'warn\tServices that read /bulk (Jellyfin, the arr apps) do not see the files of %s while it is out.\n' "$member"
    printf 'command\tphotorec /d %s/%s-<date>/raw/ /cmd %s ...\n' "$out" "$member" "$dev"
    printf 'confirm_name\t%s\nlong\tyes\nhours\t%s\ntarget\t%s\n' "$member" "$hours" "$to"
  }
  if [ "$verb" = plan ]; then plan_lines; exit 0; fi
  # run: the plan for a person, the name typed, then the job
  . "$here/lib/ui.sh"
  while IFS=$'\t' read -r k v; do
    case "$k" in
      heading) step "$v" ;;
      step) line "$v" ;;
      note) note "$v" ;;
      warn) warn "$v" ;;
      command) note "$v" ;;
      hours) kv "$(t 'Time')" "$(t 'about %s h per pass, hours or days' "$v")" ;;
    esac
  done < <(plan_lines)
  [ -t 0 ] || fail "a person has to confirm this: run it at a terminal"
  confirm_name "$member" "the name of the disk" || { echo "cancelled"; exit 1; }
  confirm=$member
  verb=start
fi

# ---- start ----
[ "$confirm" = "$member" ] || refuse "type the name to confirm: $member"
if [ "$now" != yes ]; then
  . "$here/lib/job.sh"
  unit=$(hs_job "disk-recover-$member" "recover deleted files from $member" -- bash "$here/disk-recover.sh" start "$member" --to "$to" --types "$types" --confirm "$confirm" --now) || refuse "the job could not be started"
  printf 'status\tstarted\nunit\t%s\n' "$unit"
  exit 0
fi

# the job: owns the bulk lock for the whole run, so no parity sync or cache mover starts meanwhile
. "$here/lib/bulklock.sh"
bulk_lock_admin 60
echo "Recovering deleted files from $member (the disk is only read)."
mkdir -p "$recdir"; printf '%s\n' "$to" > "$recdir/$member"
if [ "$testmode" != 1 ] && [ "$mounted" = yes ]; then
  for m in /bulk "$rawpool"; do
    mountpoint -q "$m" 2>/dev/null && setfattr -n user.mergerfs.branches -v "-$dir" "$m/.mergerfs" 2>/dev/null || true
  done
  umount "$dir" || { rm -f "$recdir/$member"; bash "$bulkmount" >/dev/null 2>&1 || true; echo "$member is busy and could not be unmounted (something still uses it); nothing was changed."; exit 1; }
fi
[ "$testmode" = 1 ] || blockdev --setro "$dev" || { rm -f "$recdir/$member"; echo "the device could not be made read-only; stopping."; exit 1; }
echo "$member is out of the pool and read-only."

stamp=$(date +%Y%m%d-%H%M)
run=$out/$member-$stamp
raw=$run/raw
mkdir -p "$raw"
if [ "$types" = media ]; then
  enable=""; for t in $media_types; do enable+="${enable:+,}$t,enable"; done
  fileopt="everything,disable,$enable"
else
  fileopt="everything,enable"
fi
cd "$run"
echo "Searching $(human "$devsize") for deleted files ($types). This takes hours; the lines below show how far it is."
"$photorec" /log /d "$raw/" /cmd "$dev" "partition_none,options,keep_corrupted_file,fileopt,$fileopt,wholespace,search" >"$run/photorec.out" 2>&1 &
pid=$!
tick=${HS_RECOVER_TICK:-60}
while kill -0 "$pid" 2>/dev/null; do
  sleep "$tick" &
  wait $! || true
  n=$(find "$raw" -type f ! -name '*.se2' ! -name '*.log' 2>/dev/null | wc -l)
  echo "found so far: $n files, $(du -sh "$raw" 2>/dev/null | cut -f1)"
done
rc=0; wait "$pid" || rc=$?
if [ "$rc" -ne 0 ] || grep -q "Syntax error" "$run/photorec.out" "$run/photorec.log" 2>/dev/null; then
  err=$(grep -ahi -m1 'syntax error' "$run/photorec.out" "$run/photorec.log" 2>/dev/null | sed 's/\x1b[^a-zA-Z]*[a-zA-Z]//g' | tr -d '\000-\010\016-\037' | cut -c1-200 || true)
  echo "photorec stopped with an error (${err:-exit $rc}). What it found is in $raw. $member stays out of the pool and read-only; start the recovery again, or give the disk back: hs sys disk start $member recover-finish"
  exit 1
fi

# ---- sort: by kind, videos and music named by their tags ----
echo "Sorting what was found."
safe() { printf '%s' "$1" | tr -c 'A-Za-z0-9 ._-' '_' | sed 's/^[ ._-]*//; s/  */ /g' | cut -c1-80; }
have_probe=no; command -v "$ffprobe" >/dev/null 2>&1 && have_probe=yes
declare -A count
while IFS= read -r -d '' f; do
  b=${f##*/}; ext=${b##*.}; ext=${ext,,}; seq=${b%.*}; seq=${seq//[!0-9]/}
  case "$ext" in
    mkv|mov|mp4|m4v|avi|mpg|mpeg|wmv|asf|webm|ts) kind=videos ;;
    jpg|jpeg|png|gif|tif|tiff|bmp|webp|heic) kind=photos ;;
    mp3|flac|ogg|wav|m4a|wma|aac|opus) kind=music ;;
    pdf|doc|docx|xls|xlsx|odt|ods|txt|zip|rar|7z) kind=documents ;;
    *) kind=other ;;
  esac
  name=$b
  if [ "$have_probe" = yes ] && { [ "$kind" = videos ] || [ "$kind" = music ]; }; then
    info=$("$ffprobe" -v error -show_entries format=duration:format_tags=title,artist -of default=nw=1 "$f" 2>/dev/null || true)
    if [ -z "$info" ]; then
      kind=$kind/unreadable
    else
      title=$(sed -n 's/^TAG:title=//p' <<<"$info" | head -n1); artist=$(sed -n 's/^TAG:artist=//p' <<<"$info" | head -n1)
      dur=$(sed -n 's/^duration=//p' <<<"$info" | head -n1); dur=${dur%%.*}; [[ "$dur" =~ ^[0-9]+$ ]] || dur=""
      stem=$(safe "${artist:+$artist - }${title:-$kind}"); stem=${stem:-$kind}
      name="$stem-${seq:-$RANDOM}${dur:+-$((dur / 60))m$(printf '%02d' $((dur % 60)))s}.$ext"
    fi
  fi
  mkdir -p "$run/$kind"
  mv -n "$f" "$run/$kind/$name"
  count[${kind%%/*}]=$(( ${count[${kind%%/*}]:-0} + 1 ))
done < <(find "$raw" -type f ! -name '*.se2' ! -name '*.log' -print0)
find "$raw" -depth -type d -empty -delete 2>/dev/null || true
chown -R adminuser:users "$out" 2>/dev/null || true
chmod -R g+rwX "$out" 2>/dev/null || true

total=0; summary=""
for k in videos photos music documents other; do
  c=${count[$k]:-0}; total=$((total + c)); [ "$c" -eq 0 ] || summary+="$k: $c  "
done
echo "Done: $total files found${summary:+ ($summary)}"
echo "They are in $run (share: recovered, on $to). Look through them, copy what you want to keep."
echo "$member is still out of the pool, read-only. When you are done: hs sys disk start $member recover-finish"
printf 'status\tdone\nrecovered\t%s\nfiles\t%s\n' "$run" "$total"
