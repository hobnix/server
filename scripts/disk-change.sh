#!/usr/bin/env bash
# help: start a self-test inside a disk without asking anything: what would happen (plan), then do it (start)
# help.de: einen Selbsttest in einer Platte starten, ohne etwas zu fragen: was passieren würde (plan), dann ausführen (start)
# args: plan|start test <disk> short|long | wipe <disk> [--confirm <disk>] | forget <serial> [--confirm <serial>] | recover <member> [--to <member>] [--types media|all] [--confirm <member>] | recover-finish <member> | move <member> --path <path> [--to <member>] | detach <member> [--confirm <member>] | attach <member> | temp-mount <partition> [--name <n>] | temp-copy <name> --to <share> | temp-eject <name>
# System command (hs sys disk plan|start): for the interface, timers and tests. It never asks and prints plain key<TAB>value lines like
# jobs-change.sh and backup-change.sh. The work is disk-health.sh --test (this script adds no logic of its own, only the checks around it).
#   wipe <disk>              erase a free disk (every filesystem, ZFS and partition signature) so it can be added to a pool or used again; red:
#                            plan has a danger line and confirm_name = the disk, start needs --confirm <disk>. Refused for a disk that is mounted, open
#                            (LUKS), in a ZFS pool, a member of the array or the backup disk, or one of this server's own encrypted disks. Start runs as a job (status started + unit: it shows under Tasks and says when it is done; the job repeats the checks with --now).
#   forget <serial>          remove a MISSING disk from the inventory for good (its SMART history goes with it); red: confirm_name = the serial.
#                            Refused for a disk that is present or not in the inventory. start is quick (status done), no job.
#   recover <member>         get deleted files back from a data disk of the array (disk-recover.sh: the disk leaves /bulk, is set read-only and read as
#                            a background job; what is found goes onto another data disk). plan has confirm_name = the member, start needs --confirm <member>.
#   recover-finish <member>  give that disk back to the pool afterwards
#   detach <member> / attach <member>   take a data disk out of /bulk for work by hand and put it back (disk-detach.sh); detach needs --confirm <member>
#   move <member> --path <path> [--to <member>]   move a folder from a data disk to another one, disk to disk (disk-move.sh; start is a job)
#   test <disk> short|long   start a SMART self-test inside the disk (the disk does it by itself, it stays usable; a long test takes hours)
#
# plan: exit 0 = allowed, 1 = refused. Output: status ok|refused, reason<TAB><text> | heading|step|note|command<TAB><line>, long<TAB>yes|no.
#   Refused: an unknown disk, a name that is not a disk, a test that is running in the disk already.
# start: the same checks, then the test is started inside the disk (status done; the outcome is in `hs sys disk results <disk>`).
# Test knobs: HS_DISK_HEALTH (stand-in for disk-health.sh), HS_TEMP_DISK (stand-in for temp-disk.sh), HS_BULK.
set -euo pipefail
here=$(dirname "$0")
health=${HS_DISK_HEALTH:-$here/disk-health.sh}

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

verb=${1:-}; action=${2:-}; disk=${3:-}; kind=${4:-}
case "$verb" in plan|start) ;; *) echo "usage: disk-change.sh plan|start test <disk> short|long" >&2; exit 1 ;; esac
case "$action" in test|wipe|forget|recover|recover-finish|move|detach|attach|temp-mount|temp-eject|temp-copy) ;; *) refuse "unknown action (test, wipe, forget, recover, recover-finish, move, detach, attach, temp-mount, temp-eject or temp-copy)" ;; esac
# a plain device or by-id name: no path, no dots-dots, no options
{ [[ "$disk" =~ ^[A-Za-z0-9][A-Za-z0-9._:+-]{0,100}$ ]] && [[ "$disk" != *..* ]]; } || refuse "that is not a disk name"

export HS_PLAIN=1 HS_LANG=en HS_CALLER=${HS_CALLER:-ui}
unset HS_GUIDED_TTY

# ---- detach / attach: a data disk out of /bulk for work by hand, and back (disk-detach.sh does the work; this script only routes) ----
if [ "$action" = detach ] || [ "$action" = attach ]; then
  shift 3
  exec bash "$here/disk-detach.sh" "$verb" "$action" "$disk" "$@"
fi

# ---- move: a folder from one data disk to another (disk-move.sh does the work; this script only routes) ----
if [ "$action" = move ]; then
  shift 3
  exec bash "$here/disk-move.sh" "$verb" "$disk" "$@"
fi

# ---- recover: deleted files of a data disk of the array (disk-recover.sh does the work; this script only routes) ----
if [ "$action" = recover ]; then
  shift 3
  exec bash "$here/disk-recover.sh" "$verb" "$disk" "$@"
fi
if [ "$action" = recover-finish ]; then
  [[ "$disk" =~ ^data-[0-9]+$ ]] || refuse "that is not a data disk of the array (data-NN)"
  if [ "$verb" = plan ]; then
    [ -e "${HS_STATE_DIR:-/var/lib/hs}/recovering/$disk" ] || refuse "$disk is not out of the pool for a recovery."
    printf 'status	ok
heading	give %s back to the pool
step	allow writing to %s again and mount it into /bulk
note	The files that were recovered stay where they are.
long	no
' "$disk" "$disk"
    exit 0
  fi
  exec bash "$here/disk-recover.sh" finish "$disk"
fi

# ---- forget: a missing disk leaves the inventory for good (the state database: hs sys state forget <serial>) ----
if [ "$action" = forget ]; then
  shift 3
  confirm=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --confirm) [ $# -ge 2 ] || refuse "--confirm needs a value"; confirm=$2; shift 2 ;;
      *) refuse "unknown option $1" ;;
    esac
  done
  state=${HS_STATE_SH:-$here/state.sh}
  row=$(bash "$state" disks 2>/dev/null | awk -F'	' -v s="$disk" '$1 == s { print; exit }' || true)
  [ -n "$row" ] || refuse "There is no disk with the serial '$disk' in the inventory."
  [ "$(cut -f5 <<<"$row")" = missing ] || refuse "$disk is in the machine: only a missing disk can be forgotten."
  if [ "$verb" = start ]; then
    [ "$confirm" = "$disk" ] || refuse "type the serial to confirm: $disk"
    bash "$state" forget "$disk" --yes >/dev/null 2>&1 || refuse "the disk could not be forgotten"
    printf 'status	done
'
    exit 0
  fi
  printf 'status	ok
heading	forget the missing disk %s
' "$disk"
  printf 'step	remove %s (%s) from the list of disks this server has had
' "$disk" "$(cut -f2 <<<"$row")"
  printf 'warn	Its SMART history and its events go with it.
'
  printf 'danger	This cannot be undone; if the disk comes back it is recorded as a new one.
'
  printf 'command	state.sh forget %s
confirm_name	%s
long	no
' "$disk" "$disk"
  exit 0
fi

# ---- wipe: erase a disk that belongs to nothing so it can be used again (hs sys disk plan|start <disk> wipe) ----
if [ "$action" = wipe ]; then
  shift 3
  confirm="" now=no
  while [ $# -gt 0 ]; do
    case "$1" in
      --confirm) [ $# -ge 2 ] || refuse "--confirm needs a value"; confirm=$2; shift 2 ;;
      --now)     now=yes; shift ;;   # the job started by `start` runs it this way
      *) refuse "unknown option $1" ;;
    esac
  done
  devdir=${HS_DEV_DIR:-/dev}
  dev=$(readlink -f "$devdir/disk/by-id/$disk" 2>/dev/null || true)
  [ -n "$dev" ] && [ -e "$dev" ] || dev=$devdir/$disk
  [ -e "$dev" ] || refuse "There is no disk '$disk'."
  tree=$(lsblk -nP -o NAME,PATH,TYPE,FSTYPE,LABEL,MOUNTPOINTS,SIZE "$dev" 2>/dev/null || true)
  [ -n "$tree" ] || refuse "There is no disk '$disk'."
  field() { sed -n "s/.*[ ]$1=\"\([^\"]*\)\".*/\1/p" <<<" $2"; }   # field <KEY> <lsblk -P line>
  first=$(sed -n 1p <<<"$tree")
  [ "$(field TYPE "$first")" = disk ] || refuse "$disk is not a whole disk."
  cryptmaps=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    mp=$(field MOUNTPOINTS "$line"); fs=$(field FSTYPE "$line"); lb=$(field LABEL "$line"); ty=$(field TYPE "$line")
    [ -z "$mp" ] || refuse "$disk is in use (mounted at ${mp%% *}). Unmount or eject it first; a system or pool disk is never erased here."
    [ "$fs" != swap ] || refuse "$disk holds swap."
    case "$lb" in bulk-*) refuse "$disk is a member of the bulk array (take it out with hs pool bulk remove first)." ;; backup) refuse "$disk is the backup disk." ;; esac
    # an encrypted volume that is open but mounted nowhere and holds no array label (a disk taken out of the array leaves it open): closed first
    [ "$ty" != crypt ] || cryptmaps+=("$(field NAME "$line")")
  done <<<"$tree"
  base=$(basename "$dev")
  if zpool status -L 2>/dev/null | awk '{ print $1 }' | grep -Eq "^${base}([0-9]+|p[0-9]+)?$"; then refuse "$disk is a member of a ZFS pool."; fi
  # (it probes the disk itself: lsblk's file system column can lag behind a fresh header)
  case "$( ( . "$here/lib/crypt.sh"; crypt_disk_class "$dev" ) 2>/dev/null || true)" in
    # closed: nobody can tell whether it is a member of the array (its label is inside), so it is never erased; open and unused it is fine
    own|ambiguous) [ ${#cryptmaps[@]} -gt 0 ] || refuse "$disk is one of this server's encrypted disks and it is closed. Open it first (hs unlock) so that the array label can be checked." ;;
  esac
  if [ "$verb" = start ]; then
    [ "$confirm" = "$disk" ] || refuse "type the name to confirm: $disk"
    if [ "$now" != yes ]; then
      # the erase is a job: it shows under Tasks and says when it is done (it repeats every check above, with --now, and does the work)
      . "$here/lib/job.sh"
      unit=$(hs_job "disk-wipe-$disk" "format (erase) $disk" -- bash "$here/disk-change.sh" start wipe "$disk" --confirm "$confirm" --now) || refuse "the job could not be started"
      printf 'status\tstarted\nunit\t%s\n' "$unit"
      exit 0
    fi
    echo "Erasing $disk ($(field SIZE "$first"))"
    # the LUKS uuids on the disk (forgotten afterwards), then close what is open on it
    uuids=()
    for part in $(lsblk -nr -o PATH "$dev"); do
      [ "$(blkid -p -o value -s TYPE "$part" 2>/dev/null || true)" = crypto_LUKS ] || continue
      uuids+=("$(cryptsetup luksUUID "$part" 2>/dev/null || true)")
    done
    for m in "${cryptmaps[@]}"; do
      echo "Closing the encrypted volume $m"
      cryptsetup close "$m" 2>/dev/null || refuse "the encrypted volume $m could not be closed (is something using it?)"
    done
    echo "Erasing every signature and the partition table"
    for part in $(lsblk -nr -o PATH "$dev" | tail -n +2); do
      zpool labelclear -f "$part" 2>/dev/null || true
      wipefs -a -q "$part" 2>/dev/null || true
    done
    zpool labelclear -f "$dev" 2>/dev/null || true
    wipefs -a -q "$dev" >/dev/null 2>&1 || refuse "the disk could not be erased (wipefs failed)"
    ! command -v sgdisk >/dev/null 2>&1 || sgdisk --zap-all "$dev" >/dev/null 2>&1 || true
    blockdev --rereadpt "$dev" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    luks_list=${HS_STATE_DIR:-/var/lib/hs}/luks-uuids
    for u in "${uuids[@]}"; do
      [ -z "$u" ] || [ ! -f "$luks_list" ] || sed -i "/^$u\$/d" "$luks_list" 2>/dev/null || true
    done
    echo "Done: $disk is empty and can be added to a pool."
    printf 'status\tdone\n'
    exit 0
  fi
  echo "status	ok"
  printf 'heading\tformat (erase) %s, %s\n' "$disk" "$(field SIZE "$first")"
  printf 'step\terase every filesystem, ZFS and RAID signature and the partition table of %s\n' "$disk"
  for m in "${cryptmaps[@]}"; do printf 'step\tclose the open encrypted volume %s\n' "$m"; done
  printf 'step\tthe disk is left empty: adding it to a pool formats it\n'
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    fs=$(field FSTYPE "$line"); [ -n "$fs" ] || continue
    printf 'warn\t%s holds %s%s\n' "$(field PATH "$line" | sed 's|.*/||')" "$fs" "$( [ -z "$(field LABEL "$line")" ] || printf ' "%s"' "$(field LABEL "$line")")"
  done <<<"$tree"
  printf 'danger\tALL DATA on %s will be erased.\n' "$disk"
  printf 'command\twipefs -a %s (and its partitions)\n' "$dev"
  printf 'confirm_name\t%s\nlong\tno\n' "$disk"
  exit 0
fi

# ---- another disk (USB, hot-plug): temp-disk.sh mounts it read-only and shares it; the disk itself is never formatted or written ----
#   temp-mount <partition> [--name <n>]   <partition> is the kernel name of a partition `hs sys temp-disk raw` offers (sdg1); plan names the mount and the share
#   temp-copy <name> --to <share>         copy everything on a mounted temp disk into /bulk/shares/<share> (a background job)
#   temp-eject <name>                     remove the share and unmount; afterwards it is safe to unplug
if [ "$action" != test ]; then
  tdisk=${HS_TEMP_DISK:-$here/temp-disk.sh}
  bulk=${HS_BULK:-/bulk}
  shift 3
  name="" to=""
  while [ $# -gt 0 ]; do
    case "$1:$action" in
      --name:temp-mount) [ $# -ge 2 ] || refuse "--name needs a value"; name=$2; shift 2 ;;
      --to:temp-copy)    [ $# -ge 2 ] || refuse "--to needs a value"; to=$2; shift 2 ;;
      *) refuse "unknown option $1" ;;
    esac
  done
  [[ "$disk" =~ ^[a-z0-9][a-z0-9-]*$ ]] || refuse "that is not a partition or temp disk name"
  [ -z "$name" ] || [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || refuse "the name is letters, digits and hyphens"
  raw=$(bash "$tdisk" raw </dev/null 2>/dev/null || true)       # device|fstype|label|bytes|mountpoints, one per partition
  row=""
  case "$action" in
    temp-mount) row=$(awk -F'|' -v d="/dev/$disk" '$1 == d' <<<"$raw") ;;
    *)          row=$(awk -F'|' -v m="/mnt/temp/$disk" '{ n = split($5, a, ","); for (i = 1; i <= n; i++) if (a[i] == m) { print; exit } }' <<<"$raw") ;;
  esac
  case "$action" in
    temp-mount)
      [ -n "$row" ] || refuse "/dev/$disk is not offered: system, pool and swap disks are never mounted here (see hs sys temp-disk raw)."
      IFS='|' read -r dev fs label bytes mps <<<"$row"
      [ -z "$mps" ] || refuse "/dev/$disk is mounted at $mps already."
      cmd=(bash "$tdisk" mount "$dev"); [ -z "$name" ] || cmd+=(--name "$name")
      rc=0; dry=$("${cmd[@]}" --dry-run </dev/null 2>&1) || rc=$?
      if [ "$rc" -ne 0 ]; then
        refuse "$(printf '%s' "$dry" | sed -e 's/^[[:space:]]*//' -e 's/^[✗!] *//' | awk 'NF' | tail -n 1)"
      fi ;;
    temp-eject)
      [ -n "$row" ] || refuse "There is no temp disk called '$disk' mounted."
      cmd=(bash "$tdisk" eject "$disk") ;;
    temp-copy)
      [ -n "$row" ] || refuse "There is no temp disk called '$disk' mounted."
      [ -n "$to" ] || { printf 'status\tneeds\nneeds\tto\n'; exit 2; }
      [[ "$to" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || refuse "that is not a share name"
      [ -d "$bulk/shares/$to" ] || refuse "There is no share '$to' (hs share add $to)."
      cmd=(bash "$tdisk" copy "$disk" "$to") ;;
  esac
  if [ "$verb" = start ]; then
    if [ "$action" = temp-copy ]; then
      . "$here/lib/job.sh"
      unit=$(hs_job "temp-copy-$disk" "hs disk temp copy $disk" -- "${cmd[@]}") || refuse "the job could not be started"
      printf 'status\tstarted\nunit\t%s\n' "$unit"
      exit 0
    fi
    rc=0; out=$("${cmd[@]}" </dev/null 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
      refuse "$(printf '%s' "$out" | sed -e 's/^[[:space:]]*//' -e 's/^[✗!] *//' | awk 'NF' | tail -n 1)"
    fi
    printf 'status\tdone\n'
    exit 0
  fi
  echo "status	ok"
  case "$action" in
    temp-mount)
      printf 'heading\tlook at %s\n' "/dev/$disk"
      printf 'step\tmount /dev/%s read-only (%s%s, %s)\n' "$disk" "$fs" "${label:+, \"$label\"}" "$(numfmt --to=iec "$bytes" 2>/dev/null || echo "$bytes")"
      printf '%s\n' "$dry" | sed -n 's/^[ \t]*\(Mount\|Share\): */step\t\1 /p'
      printf 'note\tThe data on the disk is never formatted or changed by mounting. Only Domain Admins can open the share at first.\n'
      printf 'note\tWhen you are done, eject it here: the health check reminds you after a few days.\n' ;;
    temp-copy)
      printf 'heading\tcopy %s into the share %s\n' "$disk" "$to"
      printf 'step\tcopy everything on /mnt/temp/%s into %s/shares/%s (rsync, skips the Windows trash)\n' "$disk" "$bulk" "$to"
      printf 'note\tThe copy checks that there is room first and can run for a long time.\n' ;;
    temp-eject)
      printf 'heading\teject %s\n' "$disk"
      printf 'step\tremove the share temp-%s and unmount /mnt/temp/%s\n' "$disk" "$disk"
      printf 'warn\tOpen files on the share are closed. If something on the server still uses the folder, the unmount waits: close it and eject again.\n'
      printf 'note\tAfterwards it is safe to unplug the disk.\n' ;;
  esac
  printf 'command\t%s\n' "${cmd[*]}"
  if [ "$action" = temp-copy ]; then printf 'long\tyes\n'; else printf 'long\tno\n'; fi
  exit 0
fi

case "$kind" in short|long) ;; *) refuse "the test is short or long" ;; esac
[ $# -le 4 ] || refuse "unknown option $5"

# the dry run knows whether the disk exists and which command would run; the results say whether a test is running now
rc=0
dry=$(bash "$health" --test "$kind" "$disk" --dry-run </dev/null 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then
  reason=$(printf '%s\n' "$dry" | awk 'NF { sub(/^[ \t]+/, ""); print; exit }')
  refuse "${reason:-the disk is not available}"
fi
cmd=$(printf '%s\n' "$dry" | sed -n 's/^[ \t]*Would run: //p' | sed -n 1p)
res=$(bash "$health" --results "$disk" </dev/null 2>&1 || true)
if grep -q 'A test is running' <<<"$res"; then
  refuse "A self-test is running in $disk already. Wait until it is done."
fi
inuse=$(printf '%s\n' "$dry" | sed -n 's/^[ \t]*\(.* is in use: .*\)$/\1/p' | sed -n 1p)

if [ "$verb" = start ]; then
  rc=0
  out=$(bash "$health" --test "$kind" "$disk" </dev/null 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    reason=$(printf '%s\n' "$out" | awk 'NF { sub(/^[ \t]+/, ""); l = $0 } END { print l }')
    refuse "${reason:-the self-test did not start}"
  fi
  printf 'status\tdone\n'
  exit 0
fi

echo "status	ok"
printf 'heading\t%s self-test of %s\n' "$kind" "$disk"
printf 'step\tstart a %s self-test inside %s; the disk does it by itself\n' "$kind" "$disk"
if [ "$kind" = long ]; then
  printf 'note\tA long test reads the whole surface: it takes hours. The disk stays usable but is slower meanwhile.\n'
else
  printf 'note\tA short test takes about two minutes.\n'
fi
[ -z "$inuse" ] || printf 'note\t%s\n' "$inuse"
printf 'note\tThe outcome shows under Self-tests of the disk.\n'
[ -z "$cmd" ] || printf 'command\t%s\n' "$cmd"
if [ "$kind" = long ]; then printf 'long\tyes\n'; else printf 'long\tno\n'; fi
exit 0
