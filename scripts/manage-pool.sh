#!/usr/bin/env bash
# help: menu to create the pools "fast" and "bulk" from mirror pairs, or add pairs to them
# help.de: Menü, um die Pools "fast" und "bulk" aus Spiegelpaaren anzulegen oder Paare hinzuzufügen
# args: [pool] [--dry-run] [--plain] [--disks <id,...>] [--role data|parity|adopt] [--encrypt] [--chown] [--merge] [--replace [member]] [--remove [member]] [--convert [member] [--discard]] [--close [member] [--drain]] [--open [member]]
# Bare use (a terminal): --replace/--remove/--convert without a member ask which one (the registry rows "hs pool <pool> replace|remove|convert" are guided).
# Stand-in for tests: HS_GUIDED_TTY=1 = "there is a terminal" (answers on stdin).
set -euo pipefail
. "$(dirname "$0")/lib/crypt.sh"
. "$(dirname "$0")/lib/diskpath.sh"
. "$(dirname "$0")/lib/diskused.sh"
. "$(dirname "$0")/lib/bulkpath.sh"

usage() {
  say "usage: hs pool <pool> [add|replace|remove|convert] [--dry-run] [--disks <id,id,...>]"
  say "  [pool]      fast or bulk (or another name); without it a menu asks"
  say "  --dry-run   only show the command, change nothing"
  say "  --plain     simple menus instead of the full-screen interface"
  say "  --disks     skip the disk menu; names from /dev/disk/by-id, comma separated"
  say "  --role      snapraid layout only: add the disks as data or as parity, or adopt"
  say "              disks that already hold files (e.g. from Unraid; nothing is erased)"
  say "  --encrypt   new disks and pools are encrypted (LUKS on snapraid disks, ZFS native encryption on pools)"
  say "              with one passphrase for all of them; unlock after a boot with: hs unlock"
  say "  --fs        filesystem of new snapraid disks: ext4 (default), xfs or btrfs; asked on a terminal"
  say "  --chown     with --role adopt: hand the files over to adminuser:users (slow on big disks)"
  say "  --merge     with --role adopt: put the folders of all disks into one shares/<name> (default: one"
  say "              share per disk and folder, shares/<disk>-<name>, e.g. data-02-media)"
  say "  --replace   swap a member (name as shown by --members) for the disk given with --disks"
  say "  --mode      ZFS remove of a disk in a 2-disk mirror: detach (the other disk stays alone) or vdev (whole mirror, data moves)"
  say "              snapraid remove of a data disk: move (default, files go to the other disks) or nomove (files stay on the disk)"
  say "  --convert   snapraid data disk: empty it onto the other disks and format it again (use --fs / --encrypt)"
  say "  --discard   with --convert: do NOT move the files, erase them with the disk (they are gone for good)"
  say "  --close     snapraid data disk: no NEW files go there any more (it stays in /bulk, readable); --drain also moves its files to the other disks"
  say "  --open      snapraid data disk: take the mark of --close away again"
  say "  --remove    take a member out: a whole mirror pair (ZFS) or a single disk (snapraid)"
  say "Before the full config is applied: sudo bash /etc/nixos/scripts/manage-pool.sh"
  exit 1
}

orig_args=("$@")   # a background job (offered after the questions) repeats them
pool=""
dry=false
picked=""
role=""
plain=false
chown_files=false
merge_folders=false
drain=false   # --close: also move the files off the disk onto the others
discard=false   # --convert: erase the disk without moving its files (the data is not needed any more)
encrypt=false
fs_type=""   # ext4 | xfs | btrfs for new snapraid disks; empty = ask (terminal) or ext4
assume_yes=false   # --yes: skip the typed confirmation (jobs started after the wizard asked)
zfs_how=""   # ZFS remove of a 2-disk mirror: detach | vdev (asked on a terminal)
action=""   # replace | remove
member=""
mode=""   # list | info: machine-readable output for the web interface (Disks)
# "zfs": /bulk is a ZFS pool like fast. "snapraid": single disks, merged, with parity.
bulk_type=$(cat "${HS_BULK_TYPE_FILE:-/etc/hs/bulk-type}" 2>/dev/null || echo zfs)
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=true; shift ;;
    --disks)   [ $# -ge 2 ] || usage; picked="$2"; shift 2 ;;
    --role)    [ $# -ge 2 ] || usage; role="$2"; shift 2 ;;
    --plain)   plain=true; shift ;;
    --chown)   chown_files=true; shift ;;
    --merge)   merge_folders=true; shift ;;
    --mode)    [ $# -ge 2 ] || usage; zfs_how="$2"; shift 2 ;;
    --encrypt) encrypt=true; shift ;;
    --fs)      [ $# -ge 2 ] || usage; fs_type="$2"; shift 2
               case "$fs_type" in ext4|xfs|btrfs) ;; *) echo "--fs: ext4, xfs or btrfs." >&2; exit 1 ;; esac ;;
    --list-disks) mode=list; shift ;;
    --info)    mode=info; shift ;;
    --members) mode=members; shift ;;
    --show)    mode=show; shift ;;   # bare `hs pool <pool>`: only look, change nothing
    # the member is optional: without it (or when an option follows) a person at a terminal is asked
    --drain)   drain=true; shift ;;
    --discard) discard=true; shift ;;
    --replace|--remove|--convert|--close|--open)
               action=${1#--}; member=""
               if [ $# -ge 2 ] && [[ "$2" != -* ]]; then member="$2"; shift 2; else shift; fi ;;
    --yes)     assume_yes=true; shift ;;
    -*)        usage ;;
    *)         [ -z "$pool" ] || usage; pool="$1"; shift ;;
  esac
done

# Is somebody at a terminal? (HS_GUIDED_TTY=1: the tests' stand-in, as in the guided scripts)
interactive() { { [ -t 0 ] && [ -t 1 ]; } || [ -n "${HS_GUIDED_TTY:-}" ]; }
# a person (not a job, a timer or the interface reading in the background)
person() { interactive && [ -z "${HS_CALLER:-}" ]; }
# a member is needed: only a person can be asked, everyone else gets the usage line as before
[ -z "$action" ] || [ -n "$member" ] || person || usage

# Questions. The installer (--plain: no gum) keeps its whiptail dialogs; everything else uses the shared
# components of lib/ui.sh (docs/CLI-DESIGN.md), so the commands look the same.
menu_pick() {   # menu_pick <title> <question> <key> <description>...: the chosen key
  local title=$1 q=$2
  shift 2
  if $plain; then whiptail --title "$title" --menu "$q" 14 100 $(($# / 2)) "$@" 3>&1 1>&2 2>&3
  else menu "$q" "$@"; fi
}
disk_pick() {   # disk_pick <title> <question> <id> <text> OFF ...: the chosen ids, one per line
  local title=$1 q=$2 lines=() i
  shift 2
  if $plain; then whiptail --title "$title" --separate-output --checklist "$q" 28 110 18 "$@" 3>&1 1>&2 2>&3
  else
    for ((i = 1; i <= $#; i += 3)); do lines+=("$(printf '%-44s %s' "${@:i:1}" "${@:i+1:1}")"); done
    choose_multi "$q" "${lines[@]}" | awk 'NF { print $1 }'
  fi
}

# ── The look of plans and summaries (docs/CLI-DESIGN.md) ──
# With gum on a terminal a plan is a heading, indented steps, facts, a danger line and a closing ok.
# In every other case (plain, a pipe, HS_PLAIN, the interface reading --dry-run through ui::run) the lines are
# printed exactly as they always were: the interface parses their text and prefixes (Plan:, Command:, Note:,
# ALL DATA, Dry run, Current array, the numbered steps), so nothing of that may change. tests/pool-look.sh
# compares the plain output with the old script.
fancy() { [ "$ui" = gum ]; }
pblank() { fancy || echo; }                        # the blank lines of the plain layout; the headings bring their own
phead() { if fancy; then step "${2:-${1#Plan: }}"; else echo "$1"; fi; }   # phead <plain line> [heading with gum]
pl() { if fancy; then paint "$c_text" "  $1"; else echo "$1"; fi; }         # a line as it is
plt() {                                              # a translated line (say); numbered steps stand out, prose is dimmed
  if fancy; then
    local s col=$c_dim
    s=$(_tr "$1")
    [[ "${s#"${s%%[! ]*}"}" =~ ^[0-9]+\. ]] && col=$c_text
    paint "$col" "  $s"
  else say "$1"; fi
}
pcmd() {                                             # pcmd <command text>: "Command:" and the line, or a fact
  if fancy; then kv "Command" "$1"; else echo; echo "Command:"; echo "  $1"; echo; fi
}
pplan() { local l; if fancy; then while IFS= read -r l; do pl "$l"; done <<<"${1%$'\n'}"; else printf '%s' "$1"; fi; }   # lines of the plan
pnote() { if fancy; then warn "$1"; else echo "Note: $1"; fi; }
pwarn() { if fancy; then warn "$1"; else echo "WARNING: $1"; fi; }
pdanger() { if fancy; then danger "$1"; else echo "$1"; fi; }   # the line before something is erased: starts with ALL DATA
pdry() { if fancy; then ok "Dry run: nothing changed."; else echo "Dry run: nothing changed."; fi; }
pdone() { if fancy; then ok "$1"; else echo "$1"; fi; }        # the closing line

# One line per pool for the menu: what it is for and what exists already
describe() {
  if [ "$1" = bulk ] && [ "$bulk_type" = snapraid ]; then
    echo "$(lsblk -nr -o LABEL | grep -c '^bulk-data-' || true) data, $(lsblk -nr -o LABEL | grep -c '^bulk-parity-' || true) parity disk(s)  ->  add disks"
  elif zpool list -H "$1" >/dev/null 2>&1; then
    zpool list -H -o size,alloc,health "$1" | awk '{printf "exists: %s, %s used, %s  ->  add mirror pairs", $1, $2, $3}'
  else
    echo "not created yet  ->  create from mirror pairs"
  fi
}

if [ "$mode" = list ]; then
  pool=none
elif [ -z "$pool" ]; then
  pool=$(menu_pick "Pools" "Which pool?" \
    fast "SSDs, containers and VMs.  $(describe fast)" \
    bulk "HDDs, data and shares.     $(describe bulk)") || { echo "cancelled"; exit 1; }
fi
[[ "$pool" =~ ^[a-z][a-z0-9_-]*$ ]] || { echo "invalid pool name '$pool'"; exit 1; }

# ── Candidate disks: whole disks that are not mounted and not in a pool ──
# One line per disk: by-id name, size in bytes, "SSD"/"HDD", model + serial
has_label_disk() {   # the disk or one of its partitions carries a filesystem label matching the regex
  local p l
  while read -r p; do
    l=$(blkid -p -o value -s LABEL "$p" 2>/dev/null || true)
    [[ "$l" =~ $2 ]] && return 0
  done < <(lsblk -nr -o PATH "$1")
  return 1
}
has_luks_disk() {   # the disk or one of its partitions holds a LUKS header
  local p
  while read -r p; do
    [ "$(blkid -p -o value -s TYPE "$p" 2>/dev/null || true)" = crypto_LUKS ] && return 0
  done < <(lsblk -nr -o PATH "$1")
  return 1
}
candidates() {
  local name size type rota rest id busy fsn
  # disks of the pools that are imported right now
  local in_pool
  in_pool=$(zpool status -L 2>/dev/null | awk '{ print $1 }' |
    sed -E 's/^(sd[a-z]+)[0-9]+$/\1/; s/^(nvme[0-9]+n[0-9]+)p[0-9]+$/\1/' | sort -u || true)
  while read -r name size type rota rest; do
    # HS_TEST_LOOP: the integration tests (tests/) use loop devices as disks
    [ "$type" = disk ] || { [ -n "${HS_TEST_LOOP:-}" ] && [ "$type" = loop ]; } || continue
    [ "$size" -gt 0 ] || continue                 # empty card readers
    [[ "$name" == zd* ]] && continue              # ZFS volumes
    # an encrypted disk that belongs to this server is never offered. One that does not (somebody else's data, or an old
    # system disk that carries a copy of our vault) is offered WITH a warning; every plan that uses it says "ALL DATA ... erased"
    # and asks for the typed confirmation (crypt_disk_class in lib/crypt.sh). Adopting lists them as [encrypted].
    # a second path to a disk that is open already (a dual-port SAS disk cabled to two controllers shows up twice, same WWID): never offered
    second_path "$name" && continue
    if has_luks_disk "/dev/$name"; then
      case "$(crypt_disk_class "/dev/$name")" in
        # own and OPEN, listing for adopting: not hidden. hs unlock (or --all) opens and records every disk the passphrase fits, adopted or
        # not; a member of the array is dropped by its label below, a disk that holds only files (no bulk- label) must stay adoptable.
        own) if [ -n "${ADOPT_LISTING:-}" ] && lsblk -nr -o TYPE "/dev/$name" | grep -qx crypt; then :; else continue; fi ;;
        ambiguous) continue ;;
        copy) rest="$rest [encrypted: a copy of this server's volume]" ;;
        *) rest="$rest [encrypted: not this server's]" ;;
      esac
      [ -z "${ADOPT_LISTING:-}" ] || rest="$rest [encrypted]"
    fi
    # in use: mounted, swap, or already a ZFS member
    grep -qx "$name" <<<"$in_pool" && continue
    # a ZFS label without an imported pool is a leftover (replaced or removed disk)
    busy=$(lsblk -nr -o FSTYPE,MOUNTPOINT "/dev/$name" | awk '$1 != "zfs_member" && ($2 != "" || $1 == "swap")' | head -n1)
    [ -z "$busy" ] || continue
    if lsblk -nr -o FSTYPE "/dev/$name" | grep -qx zfs_member; then rest="$rest [old ZFS label]"; fi
    fsn=$(lsblk -nr -o FSTYPE "/dev/$name" | grep -E '^(xfs|ext4|btrfs|ntfs|exfat)$' | sort -u | paste -sd, || true)
    [ -z "$fsn" ] || rest="$rest [has $fsn files]"
    # a member of the snapraid array, even while it isn't mounted
    lsblk -nr -o LABEL "/dev/$name" | grep -q '^bulk-' && continue
    # the disk of hs backup is unmounted between runs: it must not look free (label "backup")
    has_label_disk "/dev/$name" '^(bulk-.*|backup)$' && continue
    # stable name; prefer the readable ata-/nvme-/scsi- name over wwn-
    id=$(stable_id "$name" || true)   # a dual-port disk: udev gave the names to its other path
    [ -n "$id" ] || continue
    printf '%s\t%s\t%s\t%s\n' "$id" "$size" "$([ "$rota" = 1 ] && echo HDD || echo SSD)" "$rest"
  done < <(lsblk -dnb -o NAME,SIZE,TYPE,ROTA,MODEL,SERIAL)
}

# Erase a disk so it can be reused: old ZFS labels survive a plain wipefs of
# the whole disk because they sit on its partitions.
clean_disk() {
  local dev="/dev/disk/by-id/$1" part
  for part in $(lsblk -nr -o PATH "$dev" | tail -n +2); do
    zpool labelclear -f "$part" 2>/dev/null || true
    wipefs -a -q "$part" 2>/dev/null || true
  done
  zpool labelclear -f "$dev" 2>/dev/null || true
  wipefs -a -q "$dev"
  udevadm settle 2>/dev/null || true
}

# ── Adopting a disk that already holds files (e.g. an Unraid data disk) ──
# The filesystem is kept as it is: only its label is set and its top-level
# folders move into shares/ (a rename on the same filesystem, no data copied).
adopt_entries=()
adopt_loose=0
# the folder an adopted folder becomes inside shares/: per disk by default
# ("Media" on data-02 -> data-02-media: lowercase, spaces to dashes), or the same name (merge)
adopt_target() {   # adopt_target <label> <folder>
  if $merge_folders; then printf '%s\n' "$2"
  else printf '%s-%s\n' "${1#bulk-}" "$(tr 'A-Z ' 'a-z-' <<<"$2")"; fi
}
adopt_fs() {   # adopt_fs <by-id name>  ->  "device fstype luksdevice|-"  (LUKS: the opened /dev/mapper device)
  local dev="/dev/disk/by-id/$1" path type fstype found=() luks="-" mapper inner
  while read -r path type; do
    case "$type" in crypt|lvm) continue ;; esac     # an opened LUKS disk is handled through its header below
    # probe the device itself: lsblk only knows what udev has noticed so far
    fstype=$(blkid -p -o value -s TYPE "$path" 2>/dev/null || true)
    case "$fstype" in
      xfs|ext4|btrfs) found+=("$path $fstype -") ;;
      crypto_LUKS)
        # already open (unlocked at boot, or through the twin path of a dual-port disk): no passphrase needed, the mapper has the same name
        if [ ! -e "/dev/mapper/$(luks_name "$path")" ]; then
          crypt_get_pass || { echo "No passphrase for $1." >&2; return 1; }
        fi
        if ! luks_open "$path"; then echo "$1: the passphrase does not open $path (is it the passphrase of these disks?)." >&2; return 1; fi
        mapper="/dev/mapper/$(luks_name "$path")"
        inner=$(blkid -p -o value -s TYPE "$mapper" 2>/dev/null || true)
        case "$inner" in
          xfs|ext4|btrfs) found+=("$mapper $inner $path") ;;
          *) echo "$1 is encrypted and holds '${inner:-nothing}' inside: adopting needs xfs, ext4 or btrfs." >&2; return 1 ;;
        esac ;;
      ntfs|exfat|vfat) echo "$1 holds $fstype: copy it with hs disk temp instead, adopting needs xfs, ext4 or btrfs." >&2; return 1 ;;
    esac
  done < <(lsblk -nr -o PATH,TYPE "$dev")
  if [ "${#found[@]}" -ne 1 ]; then
    echo "$1: expected exactly one xfs/ext4/btrfs filesystem, found ${#found[@]}." >&2
    return 1
  fi
  echo "${found[0]}"
}
adopt_inspect() {   # adopt_inspect <partition> <fstype>: read-only look, nothing is replayed or written
  local part=$1 fs=$2 tmp opts=ro e
  case "$fs" in xfs) opts=ro,norecovery ;; ext4) opts=ro,noload ;; esac
  tmp=$(mktemp -d)
  if ! mount -t "$fs" -o "$opts" "$part" "$tmp" 2>/dev/null; then
    rmdir "$tmp"
    echo "Can't read $part ($fs). Was it shut down cleanly? Stop the array in Unraid properly, or repair it (xfs_repair) first." >&2
    return 1
  fi
  adopt_entries=()
  while IFS= read -r e; do adopt_entries+=("$e"); done < \
    <(find "$tmp" -mindepth 1 -maxdepth 1 -type d ! -name '.*' ! -name 'lost+found' ! -name shares ! -name sensitive -printf '%f\n' | sort)
  adopt_loose=$(find "$tmp" -mindepth 1 -maxdepth 1 ! -type d ! -name '.*' | wc -l)
  umount "$tmp"; rmdir "$tmp"
}
adopt_label() {   # adopt_label <partition> <fstype> <label>
  local tool
  case "$2" in xfs) tool=xfs_admin ;; ext4) tool=e2label ;; btrfs) tool=btrfs ;; esac
  command -v "$tool" >/dev/null || { echo "$tool is not installed (package for $2 disks); nothing was changed." >&2; return 2; }
  case "$2" in
    xfs)   xfs_admin -L "$3" "$1" >/dev/null ;;
    ext4)  e2label "$1" "$3" ;;
    btrfs) btrfs filesystem label "$1" "$3" >/dev/null ;;
  esac
}

# Make a data or parity disk: ext4 with its label, inside LUKS when --encrypt.
format_member() {   # format_member <by-id name> <label>: one spinner line, the output only if it fails
  spin "Formatting $1 as $2 (${fs_type:-ext4}$($encrypt && echo ', LUKS'))" format_member_run "$@" || exit 1
}
format_member_run() {
  local dev="/dev/disk/by-id/$1" label=$2 target
  target=$dev
  if $encrypt; then
    luks_format "$dev"
    luks_open "$dev" || { echo "Could not open the new encrypted disk $1" >&2; exit 1; }
    crypt_record "$dev"
    target="/dev/mapper/$(luks_name "$dev")"
  fi
  case "${fs_type:-ext4}" in
    xfs)   mkfs.xfs -q -f -L "$label" "$target" ;;
    btrfs) mkfs.btrfs -q -f -L "$label" "$target" ;;
    *)
      if [[ "$label" == bulk-parity-* ]]; then
        mkfs.ext4 -q -F -m 0 -T largefile4 -L "$label" "$target"   # one huge file
      else
        mkfs.ext4 -q -F -m 0 -L "$label" "$target"
      fi ;;
  esac
}

# The preparation questions for disks that are about to be formatted:
# filesystem and encryption, asked on a terminal when the options were not given.
prepare_questions() {
  [ "$bulk_type" = snapraid ] || return 0
  person && ! $dry || return 0
  # the order of : encrypt?, filesystem, key
  if ! $encrypt && confirm "Encrypt the new disk(s)? (LUKS, one passphrase for all encrypted disks; you type it next)"; then encrypt=true; fi
  if [ -z "$fs_type" ]; then
    fs_type=$(choose "Filesystem for the new disk(s)" "ext4 (default, best tested)" "xfs (big files, cannot be shrunk)" "btrfs (checksums, more moving parts)") || exit 1
    fs_type=${fs_type%% *}
  fi
  # ask for the passphrase right away (a new one the first time, else the one in use), not after the plan
  if $encrypt; then crypt_new_pass || exit 1; fi
}

human() { numfmt --to=si --round=nearest --suffix=B --format='%.1f' "$1"; }

# `--list-disks --role adopt` also lists encrypted disks (the interface's adopt mode)
if [ "$mode" = list ] && [ "$role" = adopt ]; then ADOPT_LISTING=1; export ADOPT_LISTING; fi
# the free disks are only needed to list or to choose them: --info, --members and --show (the interface reads those on every load) skip the scan
disks=()
case "$mode" in info|members|show) ;; *) mapfile -t disks < <(candidates | sort -t$'\t' -k3,3 -k2,2n -k1,1) ;; esac
# ── Output for the full-screen interface ──
if [ "$mode" = list ]; then
  if [ "$role" = adopt ]; then
    # adopting: a 5th column with the used bytes (empty when unknown), read from the superblock (lib/diskused.sh)
    for l in "${disks[@]}"; do
      id=${l%%$'\t'*}
      printf '%s\t%s\n' "$l" "$(disk_used_bytes "$(basename "$(readlink -f "/dev/disk/by-id/$id")")")"
    done
  else
    [ ${#disks[@]} -eq 0 ] || printf '%s\n' "${disks[@]}"
  fi
  exit 0
fi
if [ "$mode" = info ]; then
  if [ "$pool" = bulk ] && [ "$bulk_type" = snapraid ]; then
    echo "layout: SnapRAID + mergerfs"
    nd=$(lsblk -nr -o LABEL | grep -c '^bulk-data-' || true)
    np=$(lsblk -nr -o LABEL | grep -c '^bulk-parity-' || true)
    echo "disks: $nd data, $np parity"
    if mountpoint -q /bulk; then
      df -h --output=size,used,avail,pcent /bulk | tail -n1 |
        awk '{ printf "size: %s\nused: %s (%s)\nfree: %s\n", $1, $2, $4, $3 }'
    else
      echo "state: not mounted"
    fi
    if [ "$np" -gt 0 ]; then echo "state: protected by parity"; else echo "state: NO PARITY"; fi
    content=/var/lib/snapraid/snapraid.content
    if [ -e "$content" ]; then echo "last sync: $(date -r "$content" '+%d.%m. %H:%M')"; else echo "last sync: never"; fi
    if mountpoint -q /mnt/bulk/cache; then
      echo "upload cache: $(df -h --output=used,size /mnt/bulk/cache | tail -n1 | awk '{ print $1 " of " $2 }') on the SSD pool (hs share <share> cache)"
    fi
    echo
    while read -r l s; do
      used=$(df --output=pcent "$(disk_dir "$l")" 2>/dev/null | tail -n1 | tr -d ' ' || true)
      printf '%-10s %8s  %s\n' "${l#bulk-}" "$(human "$s")" "${used:+$used used}"
    done < <(lsblk -nrb -o LABEL,SIZE | awk '$1 ~ /^bulk-(data|parity)-[0-9]+$/' | sort -u)
  elif zpool list -H "$pool" >/dev/null 2>&1; then
    echo "layout: ZFS mirror pairs"
    zpool list -H -o health,size,alloc,cap,free "$pool" |
      awk '{ printf "state: %s\nsize: %s\nused: %s (%s)\nfree: %s\n", $1, $2, $3, $4, $5 }'
    echo
    # the vdev tree: mirrors and their disks with state
    zpool status "$pool" | awk -v p="$pool" '
      /^[ \t]*NAME/ { on = 1; next }
      on && NF == 0  { on = 0 }
      on && $1 != p  {
        if ($1 ~ /^mirror/) { print $1 " " $2; next }
        n = length($1)   # long by-id names: keep the end, that is the serial number
        print "  " (n > 26 ? ".." substr($1, n - 23) : $1) " " $2
      }'
  else
    if [ "$pool" = bulk ] && [ "$bulk_type" != snapraid ] || [ "$pool" = fast ]; then
      echo "layout: ZFS mirror pairs"
    fi
    echo "state: not created yet"
  fi
  exit 0
fi

# ── Members of a pool: name, bytes, state, group (tab separated) ──
members() {
  if [ "$pool" = bulk ] && [ "$bulk_type" = snapraid ]; then
    local l size state fsname enc closed
    # everything ever added (recorded by bulk-mount.sh) plus what carries a label now,
    # so a disk that died completely still shows up as MISSING
    for l in $({ cat /var/lib/snapraid/members 2>/dev/null; lsblk -nr -o LABEL | grep -E '^bulk-(data|parity)-[0-9]+$' || true; } | sort -u); do
      size=$(lsblk -nrb -o LABEL,SIZE | awk -v l="$l" '$1 == l { print $2; exit }')
      if mountpoint -q "$(disk_dir "$l")"; then state=ONLINE
      elif [ -n "$size" ]; then state=UNMOUNTED
      else state=MISSING; fi
      # fifth and sixth field (appended for the interface): filesystem and encryption
      fsname=$(blkid -s TYPE -o value "$(blkid -L "$l" 2>/dev/null)" 2>/dev/null || true)
      case "$(findmnt -no SOURCE "$(disk_dir "$l")" 2>/dev/null)" in /dev/mapper/*) enc=luks ;; *) enc=- ;; esac
      # seventh field: "closed" = no new files go to this disk (hs pool bulk close)
      closed=-; grep -qx "${l#bulk-}" "${HS_BULK_CLOSED:-/var/lib/hs/bulk-closed}" 2>/dev/null && closed=closed
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${l#bulk-}" "${size:-0}" "$state" "$([[ "$l" == bulk-parity-* ]] && echo parity || echo data)" "${fsname:--}" "$enc" "$closed"
    done
  else
    local dev state group name size zenc
    zenc=-; [ "$(zfs get -H -o value encryption "$pool" 2>/dev/null || echo off)" = off ] || zenc=zfs-native
    while IFS=$'\t' read -r dev state group; do
      name=${dev##*/}; name=${name%-part[0-9]*}
      size=$(lsblk -dnb -o SIZE "$(readlink -f "${dev%-part[0-9]*}" 2>/dev/null)" 2>/dev/null | head -n1 || true)
      printf '%s\t%s\t%s\t%s\tzfs\t%s\n' "$name" "${size:-0}" "$state" "${group:-single}" "${zenc:--}"
    done < <(zpool status -P "$pool" 2>/dev/null | awk -v p="$pool" '
      /^[ \t]*NAME/ { on = 1; next }
      on && NF == 0 { on = 0 }
      on && $1 ~ /^mirror/ { g = $1; next }
      on && $1 != p && $1 !~ /^(replacing|spare)/ { print $1 "\t" $2 "\t" g }')
  fi
}

if [ "$mode" = members ]; then
  members
  exit 0
fi

# ── Bare `hs pool <pool>`: what the pool is and what is in it. Changes nothing: adding is `hs pool <pool> add` ──
if [ "$mode" = show ]; then
  [ -n "$pool" ] || usage
  step "$(t 'Pool %s' "$pool")"
  info=$(bash "$0" "$pool" --info 2>/dev/null || true)
  # the "key: value" lines up to the first empty line are facts; what follows (disk lines, the mirror tree) is shown as it is
  while IFS= read -r l; do
    case "$l" in "") break ;; *:*) kv "${l%%:*}" "${l#*: }" ;; esac
  done <<<"$info"
  rest=$(sed '1,/^$/d' <<<"$info")
  [ -z "$rest" ] || { echo; trail <<<"$rest"; }
  mem=$(members)
  if [ -n "$mem" ]; then
    echo
    { thead 'DISK' 'SIZE' 'STATE' 'GROUP' 'FILESYSTEM' 'ENCRYPTION'
      while IFS=$'	' read -r n b s g f e c; do printf '%s	%s	%s	%s	%s	%s
' "$n" "$(human "${b:-0}")" "$s$([ "$c" = closed ] && echo ' (no new files)' || true)" "$g" "$f" "$e"; done <<<"$mem"
    } | table
  fi
  echo
  note "$(t 'Change it: hs pool %s add | replace | remove | convert%s' "$pool" "$([ "$pool" = bulk ] && [ "$bulk_type" = snapraid ] && echo ' | sync')")"
  exit 0
fi

# ── Replace or remove a member ──
if [ -n "$action" ]; then
  here=$(dirname "$0")
  steps 1   # one heading on every path: the plan (the job offer prints none)
  # bare use (hs pool bulk replace): a person is asked which disk (and, for replace, with which new one)
  if [ -z "$member" ]; then
    items=()
    while IFS=$'	' read -r mname msz mst mgrp mfs menc mclosed; do
      [ -n "$mname" ] || continue
      # close/open only apply to online data disks (close: not closed yet; open: only the closed ones)
      [ "$action" != close ] || { [ "$mgrp" = data ] && [ "$mst" = ONLINE ] && [ "$mclosed" != closed ]; } || continue
      [ "$action" != open ] || [ "$mclosed" = closed ] || continue
      # convert empties a data disk onto the others: only online data disks qualify
      [ "$action" != convert ] || { [ "$mgrp" = data ] && [ "$mst" = ONLINE ]; } || continue
      items+=("$mname" "$(printf '%8s  %-9s %-6s %-10s %s' "$(human "${msz:-0}")" "$mst" "${mfs:--}" "${menc:--}" "$mgrp")")
    done < <(members)
    if [ ${#items[@]} -eq 0 ]; then
      if [ "$action" = convert ]; then say "$(t "No data disk in '%s' can be converted (it must be online)." "$pool")"
      else say "$(t "'%s' has no disks to %s." "$pool" "$action")"; fi
      exit 1
    fi
    case "$action" in
      replace) q="$(t 'Which disk do you want to replace?')" ;;
      remove)  q="$(t 'Which disk do you want to take out?')" ;;
      close)   q="$(t 'On which data disk should no new files be written?')" ;;
      open)    q="$(t 'Which data disk takes new files again?')" ;;
      *)       q="$(t 'Which data disk do you want to empty and format again?')" ;;
    esac
    member=$(menu_pick "Pool '$pool'" "$q" "${items[@]}") || { echo "cancelled"; exit 1; }
  fi
  line=$(members | awk -F'\t' -v m="$member" '$1 == m')
  [ -n "$line" ] || { echo "'$member' is not a member of $pool."; exit 1; }
  IFS=$'\t' read -r _ msize mstate mgroup _mfs _menc mclosed <<<"$line"

  new=""; nsize=0
  if [ "$action" = replace ] && [ -z "$picked" ] && person; then
    if [ ${#disks[@]} -eq 0 ]; then say "No free disks found (every disk is mounted or already in use)."; exit 1; fi
    items=()
    for d in "${disks[@]}"; do
      IFS=$'	' read -r id size kind rest <<<"$d"
      items+=("$id" "$(printf '%8s  %s  %s' "$(human "$size")" "$kind" "$rest")")
    done
    picked=$(menu_pick "Pool '$pool'" "$(t 'Which free disk replaces %s?' "$member")" "${items[@]}") || { echo "cancelled"; exit 1; }
  fi
  if [ "$action" = replace ]; then
    IFS=',' read -r -a chosen <<<"${picked%,}"
    [ ${#chosen[@]} -eq 1 ] && [ -n "${chosen[0]}" ] || { echo "Pick exactly one free disk as the replacement."; exit 1; }
    for d in "${disks[@]}"; do
      [ "${d%%$'\t'*}" = "${chosen[0]}" ] && { new=${chosen[0]}; nsize=$(cut -f2 <<<"$d"); }
    done
    [ -n "$new" ] || { echo "'${chosen[0]}' is not a free disk (unknown, mounted, or already in use)."; exit 1; }
  fi

  # The typed confirmation names what is changed: the disk for replace/remove/convert, else the pool.
  confirm_plan() {
    pblank
    if $dry; then pdry; exit 0; fi
    local word=$pool what="the pool name"
    if [ -n "$member" ]; then word=$member; what="the name of the disk"; fi
    if ! $assume_yes; then
      confirm_name "$word" "$what" || { echo "cancelled"; exit 1; }
      offer_job
    fi
    # hours of work on the disks: no parity sync or cache mover run may start meanwhile
    # (they skip while this runs; a sync from the timer would fail on SnapRAID's own lock)
    if [ "$pool" = bulk ] && [ "$bulk_type" = snapraid ]; then
      . "$here/lib/bulklock.sh"
      bulk_lock_admin 60
    fi
  }

  # Hours of work: after the questions and the typed confirmation, offer to do the rest as a background
  # job (survives a closed terminal; follow it with hs job follow). The job repeats this command with
  # --yes and the answers; a passphrase goes through a root-only file that the job reads and deletes.
  offer_job() {
    [ -n "$action" ] && [ "$pool" = bulk ] && [ "$bulk_type" = snapraid ] || return 0
    person || return 0
    confirm "Run the work as a background job? (recommended: it keeps going if the terminal closes; follow it with: hs job follow)" || return 0
    . "$here/lib/job.sh"
    local args=("${orig_args[@]}" --yes) pf="" unit
    [ -z "$fs_type" ] || args+=(--fs "$fs_type")
    if $encrypt; then
      args+=(--encrypt)
      if [ -n "$crypt_pass" ]; then
        mkdir -p /run/hs && chmod 700 /run/hs
        pf=$(mktemp /run/hs/job-pass.XXXXXX)
        printf %s "$crypt_pass" > "$pf"
      fi
    fi
    unit=$(HS_DISK_PASSPHRASE_FILE=$pf hs_job "pool-$action-${member:-$pool}" "hs pool $pool $action ${member:-}" -- bash "$here/manage-pool.sh" "${args[@]}") || { [ -z "$pf" ] || rm -f "$pf"; exit 1; }
    ok "$(t 'Started as job %s. Follow it: hs job follow %s' "$unit" "$unit")"
    exit 0
  }

  if [ "$pool" = bulk ] && [ "$bulk_type" = snapraid ]; then
    conf=/var/lib/snapraid/snapraid.conf
    label="bulk-$member"; dir=$(disk_dir "$member")
    # SnapRAID's own name for the disk: data-03, parity, 2-parity, ...
    if [ "$mgroup" = parity ]; then
      n=${member##*-}; if [ "$n" = 1 ]; then sname=parity; else sname="$n-parity"; fi
    else
      sname=$member
    fi
    max_data=$(members | awk -F'\t' '$4 == "data" { if ($2 > m) m = $2 } END { print m + 0 }')
    min_parity=$(members | awk -F'\t' -v me="$member" '$4 == "parity" && $1 != me && $2 > 0 { if (!m || $2 < m) m = $2 } END { print m + 0 }')

    # Put no new files on a data disk and move what it holds to the other data disks.
    # (/mnt/bulk/pool: the same disks without the upload caches on top, so the files go to
    # the disks and not into a share's cache.) Leaves the disk unmounted when everything moved.
    evacuate_disk() {
      local target=/bulk left left_n m
      # without /bulk the files would land in a folder on the system disk and the disk would be wiped
      mountpoint -q /bulk || { echo "Not possible: /bulk is not mounted. $member is not changed."; exit 1; }
      # a retry after a failed convert/remove: the branch may be gone already, that is fine; any other failure is not
      for m in /bulk /mnt/bulk/pool; do
        [ "$m" = /bulk ] || mountpoint -q "$m" || continue
        setfattr -n user.mergerfs.branches -v "-$dir" "$m/.mergerfs" 2>/dev/null && continue
        case "$(getfattr --only-values -n user.mergerfs.branches "$m/.mergerfs" 2>/dev/null || true)" in
          *"$dir"*) echo "Could not take $member out of $m. $member is not changed."; exit 1 ;;
        esac
      done
      ! mountpoint -q /mnt/bulk/pool || target=/mnt/bulk/pool
      # progress2 = bytes, percent, speed and time left of the whole job (--no-inc-recursive: the percent is real),
      # name1 = each file as it is moved; spin shows the last lines while it runs
      rsync -aHAX --remove-source-files --no-inc-recursive --info=progress2,name1 \
        --exclude=/snapraid.content --exclude=/lost+found "$dir"/ "$target"/
      left=$(find "$dir" -type f ! -name snapraid.content ! -path "$dir/lost+found/*" -print -quit)
      if [ -n "$left" ]; then
        left_n=$(find "$dir" -type f ! -name snapraid.content ! -path "$dir/lost+found/*" | wc -l)
        echo "Some files could not be moved: $left_n left (e.g. $left; hidden files count too). $member stays out of /bulk but is not changed."
        exit 1
      fi
      ! mountpoint -q "$dir" || umount "$dir" || umount -l "$dir"
    }
    # --discard: take the disk out of /bulk and unmount it, its files are not moved (they go with the format)
    discard_disk() {
      setfattr -n user.mergerfs.branches -v "-$dir" /bulk/.mergerfs
      if mountpoint -q /mnt/bulk/pool; then setfattr -n user.mergerfs.branches -v "-$dir" /mnt/bulk/pool/.mergerfs; fi
      umount "$dir" || umount -l "$dir"
    }
    # does everything on the disk fit on the others? sets used / free_others
    data_room() {
      used=$(df -B1 --output=used "$dir" | tail -n1 | tr -d ' ')
      if $discard; then free_others=0; return 0; fi
      free_others=$(for d in "$(disks_root)"/data-*; do [ "$d" = "$dir" ] || { ! mountpoint -q "$d" || df -B1 --output=avail "$d" | tail -n1; }; done | awk '{ s += $1 } END { print s + 0 }')
      [ "$free_others" -gt "$used" ] || { echo "Not possible: $member holds $(human "$used"), the other data disks have only $(human "$free_others") free."; exit 1; }
    }

    # Close: no NEW file is written to the disk any more (mergerfs mode NC, applied by bulk-mount.sh from
    # /var/lib/hs/bulk-closed). It stays in /bulk and keeps what it holds; --drain also moves that away.
    # Open: the mark goes again. Neither touches the parity; only --drain moves files.
    if [ "$action" = close ] || [ "$action" = open ]; then
      closed_file=${HS_BULK_CLOSED:-/var/lib/hs/bulk-closed}
      [ "$mgroup" = data ] || { echo "Not possible: only data disks take files; $member is a parity disk."; exit 1; }
      if [ "$action" = open ]; then
        [ "$mclosed" = closed ] || { echo "Not possible: $member takes new files already."; exit 1; }
        phead "Plan: let $member take new files again in '$pool'"
        plt "  1. remove the mark; new files are spread over the disks as before"
        pblank
        if $dry; then pdry; exit 0; fi
        sed -i "/^$member\$/d" "$closed_file"
        bash "$here/bulk-mount.sh"
        pdone "$member takes new files again."
        exit 0
      fi
      [ "$mstate" = ONLINE ] || { echo "Not possible: $member is $mstate."; exit 1; }
      if [ "$mclosed" = closed ] && ! $drain; then echo "Not possible: $member takes no new files already (add --drain to move its files away)."; exit 1; fi
      others=$(members | awk -F'\t' -v me="$member" '$4 == "data" && $3 == "ONLINE" && $1 != me && $7 != "closed" { n++ } END { print n + 0 }')
      [ "$others" -gt 0 ] || { echo "Not possible: no other open data disk would take the new files."; exit 1; }
      if $drain; then data_room; fi
      phead "Plan: no new files on $member in '$pool'"
      plt "  1. mark $member as closed: nothing new is written to it; it stays in /bulk and keeps its files"
      if $drain; then
        pl "  2. move its $(human "$used") onto the other data disks ($(human "$free_others") free); until that is done its files are not visible in /bulk"
        plt "Moving the files can take hours. The disk stays in the array, only emptied."
      else
        plt "Files already on it stay; an existing file that grows is still written there."
        plt "To empty it use --drain. NEVER mv/cp/mc its files into /bulk or /mnt/bulk/pool by hand: they are the same files, and the copy empties them."
      fi
      pblank
      if $dry; then pdry; exit 0; fi
      if $drain; then confirm_plan; fi
      mkdir -p "$(dirname "$closed_file")"
      grep -qx "$member" "$closed_file" 2>/dev/null || echo "$member" >> "$closed_file"
      bash "$here/bulk-mount.sh"
      if ! $drain; then pdone "$member takes no new files any more. Undo: hs pool $pool open $member. To empty it: hs pool $pool close $member --drain (not by hand)"; exit 0; fi
      # drain: leave the branch, move everything onto the others, join again (closed)
      drain_disk() {
        local target=/bulk rc=0 left
        for m in /bulk /mnt/bulk/pool; do setfattr -n user.mergerfs.branches -v "-$dir" "$m/.mergerfs" 2>/dev/null || true; done
        mountpoint -q /mnt/bulk/pool && target=/mnt/bulk/pool
        rsync -aHAX --remove-source-files --no-inc-recursive --info=progress2,name1 \
          --exclude=/snapraid.content --exclude=/lost+found "$dir"/ "$target"/ || rc=$?
        bash "$here/bulk-mount.sh" >/dev/null
        left=$(find "$dir" -type f ! -name snapraid.content | head -n1)
        if [ "$rc" -ne 0 ] || [ -n "$left" ]; then echo "Some files could not be moved (e.g. ${left:-see above}). $member is back in /bulk, closed."; return 1; fi
      }
      SPIN_STREAM=1 SPIN_TAIL=15 spin "Moving the files of $member onto the other data disks ($(human "$used"); hours, the lines below show where it is)" drain_disk || exit 1
      pdone "$member is empty and takes no new files. Undo: hs pool $pool open $member"
      plt "The parity is brought in line by the next scheduled sync."
      exit 0
    fi

    if $discard && [ "$action" != convert ]; then echo "--discard only goes with --convert."; exit 1; fi
    if [ "$action" = convert ]; then
      [ "$mgroup" = data ] || { echo "Not possible: only data disks can be converted."; exit 1; }
      [ "$mstate" = ONLINE ] || { echo "Not possible: $member is $mstate."; exit 1; }
      data_room
      prepare_questions
      src=$(findmnt -no SOURCE "$dir" || true)
      phead "Plan: convert the data disk $member in '$pool' (${fs_type:-ext4}$($encrypt && echo ', encrypted (LUKS)'))"
      plt "  1. stop putting new files on it"
      if $discard; then
        pl "  2. take it out of /bulk WITHOUT moving its files ($(human "$used") are erased with it, also files that /bulk does not show)"
      else
        pl "  2. move its $(human "$used") onto the other data disks ($(human "$free_others") free)"
      fi
      pl "  3. erase it and format it again as $member (${fs_type:-ext4}$($encrypt && echo ', encrypted (LUKS)'))"
      plt "  4. the parity follows with the next scheduled sync"
      if $discard; then
        pdanger "ALL DATA on the disk is erased, NOT moved anywhere. It cannot be brought back."
      else
        plt "Moving the files can take hours. The moved files exist once until that sync, like every new file."
        pdanger "ALL DATA on the disk is erased after it was moved."
      fi
      confirm_plan
      # the disk as the system names it, also when it sits under LUKS
      base=$src
      # climb to the whole disk: through LUKS (mapper) and from a partition (an adopted Unraid disk is sdX1)
      while pk=$(lsblk -no PKNAME "$base" 2>/dev/null | head -n1); [ -n "$pk" ]; do base="/dev/$pk"; done
      byid=""
      for l in /dev/disk/by-id/*; do
        case "$l" in *-part[0-9]*|*/wwn-*|*/nvme-eui.*) continue ;; esac
        [ "$(readlink -f "$l")" = "$(readlink -f "$base")" ] && { byid=$(basename "$l"); break; }
      done
      [ -n "$byid" ] || { echo "Can't find the stable name of $base in /dev/disk/by-id."; exit 1; }
      if $encrypt; then crypt_new_pass || exit 1; fi
      if $discard; then
        discard_disk || exit 1
      else
        SPIN_STREAM=1 SPIN_TAIL=15 spin "Moving the files of $member onto the other data disks ($(human "$used"); hours, the lines below show where it is)" evacuate_disk || exit 1
      fi
      case "$src" in /dev/mapper/*) cryptsetup close "${src##*/}" 2>/dev/null || true ;; esac
      old=$(blkid -L "$label" 2>/dev/null || true); [ -z "$old" ] || wipefs -a -q "$old" || true
      clean_disk "$byid"
      format_member "$byid" "$label"
      udevadm settle 2>/dev/null || true
      mkdir -p /var/lib/hs
      # (only with a parity disk: without one there is no parity that knows the name, and no sync would ever drop it)
      [ "$min_parity" -gt 0 ] && { grep -qx "$sname" /var/lib/hs/removals 2>/dev/null || echo "$sname" >> /var/lib/hs/removals; }
      bash "$here/bulk-mount.sh"
      pdone "$member is converted."
      plt "The parity is brought in line by the next scheduled sync."
      exit 0
    fi

    if [ "$action" = replace ]; then
      if [ "$mgroup" = parity ]; then
        [ "$nsize" -ge "$max_data" ] || { echo "Not possible: the new parity disk ($(human "$nsize")) is smaller than the largest data disk ($(human "$max_data"))."; exit 1; }
      else
        [ "$min_parity" -eq 0 ] && { echo "Not possible: without a parity disk there is nothing to restore $member from."; exit 1; }
        [ "$nsize" -le "$min_parity" ] || { echo "Not possible: the new data disk ($(human "$nsize")) is larger than the parity disk ($(human "$min_parity"))."; exit 1; }
        [ "$msize" -eq 0 ] || [ "$nsize" -ge "$msize" ] || pnote "the new disk ($(human "$nsize")) is smaller than the old one ($(human "$msize")). The restore fails if the files don't fit."
      fi
      prepare_questions
      phead "Plan: replace $member ($mstate) in '$pool'"
      pl "  1. take the old disk out of the array$([ "$mstate" = MISSING ] && echo " (it is gone already)")"
      pl "  2. format $new ($(human "$nsize")) as $member (${fs_type:-ext4}$($encrypt && echo ', encrypted (LUKS)'))"
      if [ "$mgroup" = parity ]; then
        pl "  3. recompute the parity onto it:  snapraid -d $sname fix"
      else
        pl "  3. restore its files from parity:  snapraid -d $sname fix"
        plt "  4. update the parity:  snapraid sync"
      fi
      plt "Step 3 reads every disk completely and can take many hours."
      pdanger "ALL DATA on $new will be erased.$($encrypt && echo ' It will be encrypted (LUKS).')"
      confirm_plan
      if $encrypt; then crypt_new_pass || exit 1; fi

      if mountpoint -q "$dir"; then
        [ "$mgroup" = parity ] || for m in /bulk /mnt/bulk/pool; do
          setfattr -n user.mergerfs.branches -v "-$dir" "$m/.mergerfs" 2>/dev/null || true
        done
        umount "$dir" || umount -l "$dir"
      fi
      old=$(blkid -L "$label" 2>/dev/null || true)
      [ -z "$old" ] || wipefs -a -q "$old" || true     # so it is never mounted as $member again
      clean_disk "$new"
      format_member "$new" "$label"
      udevadm settle 2>/dev/null || true
      bash "$here/bulk-mount.sh"
      SPIN_STREAM=1 SPIN_TAIL=15 spin "Restoring $member from the parity (reads every disk, hours)" \
        snapraid -c "$conf" -d "$sname" -l "/var/lib/snapraid/fix-$member.log" fix || exit 1
      [ "$mgroup" = parity ] || SPIN_STREAM=1 SPIN_TAIL=15 spin "Updating the parity (hours)" snapraid -c "$conf" sync || exit 1
      pblank
      pdone "$member is replaced. Log: /var/lib/snapraid/fix-$member.log"
      exit 0
    fi

    # remove
    if [ "$mgroup" = parity ]; then
      phead "Plan: remove the parity disk $member from '$pool'"
      [ "$min_parity" -gt 0 ] || pl "  This is the only parity disk: afterwards a failed disk loses its data."
      confirm_plan
      mountpoint -q "$dir" && { umount "$dir" || umount -l "$dir"; }
      old=$(blkid -L "$label" 2>/dev/null || true); [ -z "$old" ] || wipefs -a -q "$old" || true
      case "$old" in /dev/mapper/*) crypt_close_forget "$old" ;; esac   # closed and no longer ours: hs unlock must not call it locked
    udevadm settle 2>/dev/null || true   # let the system notice the label is gone
      sed -i "/^$label\$/d" /var/lib/snapraid/members 2>/dev/null || true
      rmdir "$dir" 2>/dev/null || true
      bash "$here/bulk-mount.sh"
      pdone "$member removed."
      exit 0
    fi
    [ "$mstate" = ONLINE ] || { echo "Not possible: $member is $mstate. Replace it instead, that restores its files from parity."; exit 1; }
    if [ -z "$zfs_how" ] && person && ! $assume_yes; then
      how=$(choose "What happens to the files on $member?" "move: move them onto the other data disks (hours)" "nomove: leave them on the disk; they are no longer in /bulk" "cancel") || exit 1
      case "${how%%:*}" in move|nomove) zfs_how=${how%%:*} ;; *) echo "cancelled"; exit 1 ;; esac
      orig_args+=(--mode "$zfs_how")   # a background job repeats the answer
    fi
    case "$zfs_how" in ""|move|nomove) ;; *) echo "--mode for a snapraid disk: move (default) or nomove." >&2; exit 1 ;; esac
    if [ "$zfs_how" = nomove ]; then
      # Leave the files where they are: the disk only leaves the array. What is on it (df also counts the
      # filesystem's own tables and SnapRAID's content file, which are no files) is no longer in /bulk.
      left_n=$(find "$dir" -xdev -type f ! -name snapraid.content ! -path "$dir/lost+found/*" 2>/dev/null | wc -l || true)
      left_b=$(du -sb --exclude=snapraid.content --exclude=lost+found "$dir" 2>/dev/null | cut -f1 || true)
      phead "Plan: take the data disk $member out of '$pool' without moving its files"
      plt "  1. stop putting new files on it and take it out of /bulk"
      if [ "$left_n" -gt 0 ]; then
        pdanger "$left_n file(s), $(human "$left_b"), stay on $member and are no longer in /bulk. They are dropped from the parity too."
      else
        plt "  The disk holds no files (the rest df shows is the filesystem's own space)."
      fi
      plt "  2. take it out of the array (the parity follows with the next scheduled sync, or now if you ask for it)"
      plt "The disk itself is not erased, only unlabelled; format it afterwards."
      confirm_plan
      for m in /bulk /mnt/bulk/pool; do
        setfattr -n user.mergerfs.branches -v "-$dir" "$m/.mergerfs" 2>/dev/null || true
      done
      umount "$dir" || umount -l "$dir"
    else
    data_room
    phead "Plan: remove the data disk $member from '$pool'"
    plt "  1. stop putting new files on it"
    pl "  2. move its $(human "$used") onto the other data disks ($(human "$free_others") free)"
    plt "  3. take it out of the array (the parity follows with the next scheduled sync, or now if you ask for it)"
    plt "Moving the files can take hours. The disk itself is not erased, only unlabelled."
    confirm_plan
    SPIN_STREAM=1 SPIN_TAIL=15 spin "Moving the files of $member onto the other data disks ($(human "$used"); hours, the lines below show where it is)" evacuate_disk || exit 1
    fi
    old=$(blkid -L "$label" 2>/dev/null || true); [ -z "$old" ] || wipefs -a -q "$old" || true
    case "$old" in /dev/mapper/*) crypt_close_forget "$old" ;; esac   # an encrypted disk stays open otherwise, and would show as locked
    udevadm settle 2>/dev/null || true   # let the system notice the label is gone
    sed -i "/^$label\$/d" /var/lib/snapraid/members 2>/dev/null || true
    rmdir "$dir" 2>/dev/null || true
    bash "$here/bulk-mount.sh"
    # SnapRAID refuses a config that simply lacks a disk it knows. Its own way to drop one is a
    # sync with the disk pointing at an empty folder (-E). That sync covers every change since the
    # last one (hours, not the size of this disk), so it is not run here: the disk is recorded in
    # /var/lib/hs/removals, bulk-mount.sh keeps it in the config pointing at an empty folder, and
    # the next scheduled sync (or one started now as a job) does the -E run and forgets it.
    mkdir -p /var/lib/hs
    [ "$min_parity" -gt 0 ] && { grep -qx "$sname" /var/lib/hs/removals 2>/dev/null || echo "$sname" >> /var/lib/hs/removals; }
    bash "$here/bulk-mount.sh"
    if [ "$zfs_how" = nomove ]; then pdone "$member removed from /bulk; its files were left on it."
    else pdone "$member removed from /bulk; its files are on the other disks."; fi
    plt "The parity is brought in line by the next scheduled sync. Until then everything that did not move is protected as before."
    if person && confirm "Update the parity now instead, as a background job? (all changes since the last sync, can take hours)"; then
      . "$here/lib/job.sh"
      unit=$(hs_job bulk-sync "hs pool bulk sync (after removing $member)" -- bash "$here/bulk-sync.sh" --no-mover) || exit 1
      ok "$(t 'Started as job %s. Follow it: hs job follow %s' "$unit" "$unit")"
    fi
    pdone "$member removed."
    exit 0
  fi

  # ZFS
  case "$action" in close|open) echo "Not possible: close/open is for the data disks of the snapraid layout; a ZFS mirror writes every file to both disks."; exit 1 ;; esac
  [ "$action" != convert ] || { echo "Not possible: convert is for the data disks of the snapraid layout; a ZFS disk has no filesystem to change."; exit 1; }
  full=$(zpool status -P "$pool" | awk -v m="$member" '{ n = $1; sub(/.*\//, "", n); sub(/-part[0-9]+$/, "", n); if (n == m) { print $1; exit } }')
  [ -n "$full" ] || { echo "Can't find '$member' in zpool status."; exit 1; }
  if [ "$action" = replace ]; then
    [ "$msize" -eq 0 ] || [ "$nsize" -ge "$msize" ] || { echo "Not possible: the new disk ($(human "$nsize")) is smaller than the one it replaces ($(human "$msize"))."; exit 1; }
    phead "Plan: replace $member ($mstate, $mgroup) in '$pool' with $new ($(human "$nsize"))"
    pcmd "zpool replace $pool $full /dev/disk/by-id/$new"
    plt "ZFS copies the data onto the new disk in the background (resilver); the pool stays usable."
    pdanger "ALL DATA on $new will be erased."
    confirm_plan
    clean_disk "$new"
    zpool replace "$pool" "$full" "/dev/disk/by-id/$new"
    zpool status "$pool" | sed 's/^/      /'
    if fancy; then ok "$(t 'Resilvering %s: the pool stays usable; watch it with zpool status' "$new")"; fi
    exit 0
  fi
  [ "$mgroup" != single ] || { echo "Not possible: $member is not part of a single-disk vdev; remove needs a mirror."; exit 1; }
  # How many disks does this mirror have, and how many mirrors does the pool have?
  mirror_disks=$(members | awk -F'\t' -v g="$mgroup" '$4 == g' | wc -l)
  mirrors=$(zpool status "$pool" | grep -c '^[[:space:]]*mirror-')
  if [ "$mirror_disks" -ge 3 ]; then
    how=detach
  elif [ -n "$zfs_how" ]; then
    how=$zfs_how
  elif interactive && ! $dry; then
    how=$(choose "$member is one of 2 disks in $mgroup" "detach: take only this disk out (the other one is alone afterwards, no redundancy)" "vdev: remove the whole mirror (its data moves to the other mirrors)" "cancel") || exit 1
    how=${how%%:*}
  else
    how=detach
  fi
  case "$how" in
    cancel*) echo "cancelled"; exit 1 ;;
    detach)
      phead "Plan: take $member out of $mgroup in '$pool'"
      pcmd "zpool detach $pool $full"
      if [ "$mirror_disks" -ge 3 ]; then
        plt "The mirror keeps working with $((mirror_disks - 1)) disks."
      else
        pwarn "the other disk of $mgroup will be alone in its vdev: no redundancy, a failure of it loses the data of this vdev."
      fi
      confirm_plan
      zpool detach "$pool" "$full"
      zpool status "$pool" | sed 's/^/      /'
      if fancy; then ok "$(t '%s is out of %s' "$member" "$mgroup")"; fi
      exit 0 ;;
    vdev|whole) ;;
    *) echo "--mode: detach or vdev." >&2; exit 1 ;;
  esac
  [ "$mirrors" -gt 1 ] || { echo "Not possible: $mgroup is the only vdev of '$pool'. To stop using the pool, add the new vdev first (hs pool bulk), or destroy the pool."; exit 1; }
  if zpool status "$pool" | grep -Eq '^[[:space:]]*raidz'; then echo "Not possible: '$pool' has a raidz vdev; ZFS cannot remove a vdev from such a pool."; exit 1; fi
  # data in this mirror, and the free space of the others (bytes, from zpool list -v)
  alloc=$(zpool list -vHp "$pool" | awk -F'\t' -v g="$mgroup" '{ sub(/^[ \t]+/, ""); $0 = $0 } $1 == g { print $3; exit }')
  free_others=$(zpool list -vHp "$pool" | awk -F'\t' -v g="$mgroup" '{ sub(/^[ \t]+/, ""); $0 = $0 } $1 ~ /^mirror-/ && $1 != g { f += $4 } END { print f + 0 }')
  alloc=${alloc:-0}
  margin=$((free_others / 10))
  [ "$((free_others - margin))" -gt "$alloc" ] || { echo "Not possible: $mgroup holds $(human "$alloc"), the other mirrors have only $(human "$free_others") free (a 10 % margin is kept)."; exit 1; }
  phead "Plan: remove the whole mirror $mgroup (the pair that contains $member) from '$pool'"
  pcmd "zpool remove $pool $mgroup"
  plt "The mirror will be removed. About $(human "$alloc") of data move to the other mirrors, which have $(human "$free_others") free."
  plt "This can take hours; the pool stays usable. Cancel with: zpool remove -s $pool"
  plt "ZFS keeps a small mapping table for the removed data until it is rewritten."
  confirm_plan
  zpool remove "$pool" "$mgroup"
  zpool status "$pool" | sed 's/^/      /'
  if fancy; then ok "$(t 'The mirror %s is being removed; the pool stays usable' "$mgroup")"; fi
  exit 0
fi

# ── SnapRAID layout: /bulk is made of single labelled disks, not a ZFS pool ──
if [ "$pool" = bulk ] && [ "$bulk_type" = snapraid ]; then
  here=$(dirname "$0")
  steps 2   # "Current array" and the plan (add and adopt; the job offer prints no heading)
  # existing members: label and size in bytes
  mapfile -t members < <(lsblk -nrb -o LABEL,SIZE | awk '$1 ~ /^bulk-(data|parity)-[0-9]+$/' | sort -u)
  if fancy; then step "Current array"; else echo "Current array:"; fi
  if [ ${#members[@]} -eq 0 ]; then
    if fancy; then note "(empty)"; else say "  (empty)"; fi
  else
    for m in "${members[@]}"; do
      read -r l s <<<"$m"
      used=$(df -h --output=pcent "$(disk_dir "$l")" 2>/dev/null | tail -n1 | tr -d ' ' || true)
      if fancy; then kv "${l#bulk-}" "$(printf '%8s  %s' "$(human "$s")" "${used:+$used used}")"
      else printf '  %-14s %8s  %s\n' "${l#bulk-}" "$(human "$s")" "${used:+$used used}"; fi
    done
  fi
  pblank

  if [ -z "$role" ]; then
    role=$(menu_pick "Pool 'bulk'" "What do you want to add?" \
      data   "Data disks: more space. Any size up to the parity disk's." \
      parity "Parity disk: protects against one disk failing. Must be the largest." \
      adopt  "Disks that already hold files (xfs/ext4/btrfs, e.g. from Unraid): kept as they are.") || { echo "cancelled"; exit 1; }
  fi
  case "$role" in data|parity|adopt) ;; *) usage ;; esac
  # encrypted disks are listed for adopting only
  if [ "$role" = adopt ]; then
    mapfile -t disks < <(ADOPT_LISTING=1 candidates | sort -t$'\t' -k3,3 -k2,2n -k1,1)
  fi

  if [ ${#disks[@]} -eq 0 ]; then
    say "No free disks found (every disk is mounted or already in use)."
    exit 1
  fi
  if [ -z "$picked" ]; then
    items=()
    for d in "${disks[@]}"; do
      IFS=$'\t' read -r id size kind rest <<<"$d"
      items+=("$id" "$(printf '%8s  %s  %s' "$(human "$size")" "$kind" "$rest")" OFF)
    done
    picked=$(disk_pick "Pool 'bulk'" "New $role disk(s)" "${items[@]}") || { echo "cancelled"; exit 1; }
    picked=$(tr '\n' ',' <<<"$picked")
  fi
  IFS=',' read -r -a chosen <<<"${picked%,}"
  [ ${#chosen[@]} -ge 1 ] || { echo "No disk picked."; exit 1; }

  # The next data label is the lowest number that is free: a gap left by a removed disk is filled again. Not free: a member, and
  # a disk that waits to be dropped from the parity (HS_REMOVALS_FILE, /var/lib/hs/removals: that name stays in the parity until the next sync).
  data_taken=" "
  for m in "${members[@]}"; do read -r l _ <<<"$m"; data_taken+="$l "; done
  # (without a parity disk nothing waits: a record left from before is ignored, and `hs pool bulk sync` could never clear it)
  if [[ "$data_taken" == *" bulk-parity-"* ]]; then
    while read -r r; do [ -z "$r" ] || data_taken+="bulk-$r "; done < <(cat "${HS_REMOVALS_FILE:-/var/lib/hs/removals}" 2>/dev/null || true)
  fi
  next_data_label() {   # sets $label
    local n=1 l
    while :; do
      l=$(printf 'bulk-data-%02d' "$n")
      case "$data_taken" in *" $l "*) n=$((n + 1)) ;; *) break ;; esac
    done
    label=$l; data_taken+="$l "
  }

  # ── Adopt: keep the files, label the disk, tidy the folders into shares/ ──
  if [ "$role" = adopt ]; then
    max_data=0; min_parity=0; next_data=0
    for m in "${members[@]}"; do
      read -r l s <<<"$m"
      n=$((10#${l##*-}))
      if [[ "$l" == bulk-data-* ]]; then
        [ "$s" -gt "$max_data" ] && max_data=$s
        [ "$n" -gt "$next_data" ] && next_data=$n
      else
        { [ "$min_parity" -eq 0 ] || [ "$s" -lt "$min_parity" ]; } && min_parity=$s
      fi
    done
    todo=()
    phead "Plan (no file is erased or copied):" "Plan: no file is erased or copied"
    for c in "${chosen[@]}"; do
      line=""
      for d in "${disks[@]}"; do [ "${d%%$'\t'*}" = "$c" ] && line="$d"; done
      [ -n "$line" ] || { echo "'$c' is not a free disk (unknown, mounted, or already in use)."; exit 1; }
      IFS=$'\t' read -r id size _ _ <<<"$line"
      part_fs=$(adopt_fs "$id") || exit 1
      read -r part fs luksdev <<<"$part_fs"
      adopt_inspect "$part" "$fs" || exit 1
      next_data_label
      [ "$size" -gt "$max_data" ] && max_data=$size
      pl "$(printf '  %s (%s, %s%s): label %s' "$id" "$(human "$size")" "$fs" "$([ "$luksdev" = - ] || echo ', encrypted: unlocked')" "${label#bulk-}")"
      if [ ${#adopt_entries[@]} -eq 0 ]; then
        plt "      no folders to move"
      else
        if $merge_folders; then
          pl "$(printf '      moves into shares/ (merged with folders of the same name): %s' "${adopt_entries[*]}")"
        else
          plt "      moves into shares/ as its own share:"
          for e in "${adopt_entries[@]}"; do pl "$(printf '        %s -> %s' "$e" "$(adopt_target "$label" "$e")")"; done
        fi
      fi
      for e in "${adopt_entries[@]}"; do
        case "$(adopt_target "$label" "$e" | tr A-Z a-z)" in shares|sensitive|global|homes|printers)
          pl "      note: '$e' is a reserved share name, hs share repair will not publish it" ;;
        esac
      done
      [ "$adopt_loose" -eq 0 ] || pl "      $adopt_loose loose file(s) in the top folder stay where they are"
      todo+=("$part"$'\t'"$fs"$'\t'"$label"$'\t'"$luksdev")
    done
    pblank
    if [ "$min_parity" -gt 0 ] && [ "$max_data" -gt "$min_parity" ]; then
      warn "$(t 'Not possible: a data disk (%s) would be larger than a parity disk (%s).' "$(human "$max_data")" "$(human "$min_parity")")"
      exit 1
    fi
    [ "$min_parity" -gt 0 ] || pnote "no parity disk yet. Add one afterwards: hs pool bulk add --role parity (it ERASES that disk)."
    if $dry; then
      pdry
      exit 0
    fi
    say "The disks keep all their files. Their label is written and their folders are renamed."
    $assume_yes || confirm_name bulk "the pool name" || fail "cancelled"   # --yes: a background job, the typed name was checked before

    for t in "${todo[@]}"; do
      IFS=$'\t' read -r part fs label luksdev <<<"$t"
      mp=$(disk_dir "$label")
      adopt_label "$part" "$fs" "$label" || { rc=$?
        [ "$rc" = 2 ] || echo "Could not write the label on $part. A filesystem that was not unmounted cleanly needs a repair first." >&2
        exit 1; }
      [ "$luksdev" = - ] || crypt_record "$luksdev"      # from now on hs unlock opens it at every boot
      udevadm settle 2>/dev/null || true
      mkdir -p "$mp"
      mount -o noatime "$part" "$mp"
      mkdir -p "$mp/shares"
      mapfile -t names < <(find "$mp" -mindepth 1 -maxdepth 1 -type d ! -name '.*' ! -name 'lost+found' ! -name shares ! -name sensitive -printf '%f\n' | sort)
      for e in "${names[@]}"; do
        t=$(adopt_target "$label" "$e")
        if [ -e "$mp/shares/$t" ]; then echo "  $e: $t is already in shares/, left alone"; continue; fi
        mv "$mp/$e" "$mp/shares/$t"
      done
      chmod 2775 "$mp/shares"
      if chown adminuser:users "$mp/shares" 2>/dev/null; then
        if $chown_files; then chown -R adminuser:users "$mp/shares"; fi
      else
        say "  (no user adminuser here: ownership left as it was)"
      fi
      ok "$(t '%s: %s folder(s) moved into shares/' "${label#bulk-}" "${#names[@]}")"
    done
    # merge the disks into /bulk (skipped in tests that have no mergerfs)
    [ -n "${HS_ADOPT_SKIP_MERGE:-}" ] || bash "$here/bulk-mount.sh"
    pblank
    if $merge_folders; then pdone "Done. Every folder is now /bulk/shares/<name>, like the shares before."
    else pdone "Done. Every folder is now its own share /bulk/shares/<disk>-<name>. Move what belongs together by hand on the server, e.g.  mv /bulk/shares/data-02-media/Movies /bulk/shares/media/  (a rename on the same disk, copies nothing; always inside /bulk, never from /mnt/bulk/data-NN: those are the same files and a copy empties them); rename a share with: hs share <share> rename <new>"; fi
    say "Publish them over Samba: hs share repair (new shares start closed to Domain Admins; open them in hs share <share> perm)."
    $chown_files || echo "Files still belong to their old owner (Unraid: nobody:users). To make them adminuser's: sudo chown -R adminuser:users /bulk/shares (slow on big disks), or use --chown next time."
    say "Parity is only written by the next sync: hs pool bulk sync."
    exit 0
  fi

  # sizes of what exists, to keep the rule "parity >= every data disk"
  max_data=0; min_parity=0; next_data=0; next_parity=0
  for m in "${members[@]}"; do
    read -r l s <<<"$m"
    n=$((10#${l##*-}))
    if [[ "$l" == bulk-data-* ]]; then
      [ "$s" -gt "$max_data" ] && max_data=$s
      [ "$n" -gt "$next_data" ] && next_data=$n
    else
      { [ "$min_parity" -eq 0 ] || [ "$s" -lt "$min_parity" ]; } && min_parity=$s
      [ "$n" -gt "$next_parity" ] && next_parity=$n
    fi
  done

  [ "$role" = adopt ] || prepare_questions
  todo=()
  phead "Plan:" "Plan"
  for c in "${chosen[@]}"; do
    line=""
    for d in "${disks[@]}"; do [ "${d%%$'\t'*}" = "$c" ] && line="$d"; done
    [ -n "$line" ] || { echo "'$c' is not a free disk (unknown, mounted, or already in use)."; exit 1; }
    IFS=$'\t' read -r id size _ _ <<<"$line"
    if [ "$role" = data ]; then
      next_data_label
      [ "$size" -gt "$max_data" ] && max_data=$size
    else
      next_parity=$((next_parity + 1))
      label="bulk-parity-$next_parity"
      { [ "$min_parity" -eq 0 ] || [ "$size" -lt "$min_parity" ]; } && min_parity=$size
    fi
    todo+=("$id"$'\t'"$label")
    pl "$(printf '  format %s (%s) as %s (%s%s)' "$id" "$(human "$size")" "${label#bulk-}" "${fs_type:-ext4}" "$($encrypt && echo ', encrypted (LUKS)')")"
  done
  pblank
  if [ "$min_parity" -gt 0 ] && [ "$max_data" -gt "$min_parity" ]; then
    warn "$(t 'Not possible: a data disk (%s) would be larger than a parity disk (%s).' "$(human "$max_data")" "$(human "$min_parity")")"
    say "The parity disk must be at least as large as the largest data disk."
    exit 1
  fi
  [ "$min_parity" -gt 0 ] || pnote "no parity disk yet. Until you add one, a failed disk loses its data."

  if $dry; then
    pdry
    exit 0
  fi

  pdanger "ALL DATA on these ${#todo[@]} disk(s) will be erased."
  $assume_yes || confirm_name bulk "the pool name" || fail "cancelled"   # --yes: a background job (hs sys pool start), the typed name was checked before
  if $encrypt; then crypt_new_pass || exit 1; fi

  for t in "${todo[@]}"; do
    IFS=$'\t' read -r id label <<<"$t"
    clean_disk "$id"
    format_member "$id" "$label"
  done
  udevadm settle 2>/dev/null || true
  bash "$here/bulk-mount.sh"
  df -h /bulk "$(disks_root)"/data-* "$(disks_root)"/parity-* 2>/dev/null | sed 's/^/      /'
  if fancy; then ok "$(t '%s disk(s) added to the array' "${#todo[@]}")"; fi
  say "New data is protected after the next sync (three times a day, or now: hs pool bulk sync)."
  exit 0
fi

if [ ${#disks[@]} -eq 0 ]; then
  say "No free disks found (every disk is mounted or already in a pool)."
  exit 1
fi

# ── Choose ──
if [ -z "$picked" ]; then
  items=()
  for d in "${disks[@]}"; do
    IFS=$'\t' read -r id size kind rest <<<"$d"
    items+=("$id" "$(printf '%8s  %s  %s' "$(human "$size")" "$kind" "$rest")" OFF)
  done
  picked=$(disk_pick "Pool '$pool'" "Disks for '$pool'. Pick an even number: they are paired into mirrors by size." "${items[@]}") || { echo "cancelled"; exit 1; }
  picked=$(tr '\n' ',' <<<"$picked")
fi

IFS=',' read -r -a chosen <<<"${picked%,}"
[ ${#chosen[@]} -ge 2 ] || { echo "Pick at least two disks."; exit 1; }
[ $(( ${#chosen[@]} % 2 )) -eq 0 ] || { echo "${#chosen[@]} disks picked: mirrors need an even number."; exit 1; }

# ── Pair by size (ties broken by name), so equal disks end up together ──
sel=()
for c in "${chosen[@]}"; do
  line=""
  for d in "${disks[@]}"; do [ "${d%%$'\t'*}" = "$c" ] && line="$d"; done
  [ -n "$line" ] || { echo "'$c' is not a free disk (unknown, mounted, or already in a pool)."; exit 1; }
  sel+=("$line")
done
mapfile -t sel < <(printf '%s\n' "${sel[@]}" | sort -t$'\t' -k2,2n -k1,1)

vdevs=()
plan=""
for ((i = 0; i < ${#sel[@]}; i += 2)); do
  IFS=$'\t' read -r a asize akind _ <<<"${sel[i]}"
  IFS=$'\t' read -r b bsize bkind _ <<<"${sel[i + 1]}"
  note=""
  [ "$asize" = "$bsize" ] || note="   <- sizes differ, the pair only holds $(human "$asize")"
  [ "$akind" = "$bkind" ] || note="$note   <- SSD paired with HDD"
  vdevs+=(mirror "/dev/disk/by-id/$a" "/dev/disk/by-id/$b")
  plan+=$(printf 'mirror %2d  %8s  %s\n           %8s  %s%s' $((i / 2 + 1)) "$(human "$asize")" "$a" "$(human "$bsize")" "$b" "$note")$'\n'
done

# ── Build the command ──
if zpool list -H "$pool" >/dev/null 2>&1; then
  mode="add to the existing pool"
  cmd=(zpool add "$pool" "${vdevs[@]}")
else
  mode="create the new pool"
  # The pool is mounted at /<pool>, and ZFS refuses a folder that is not empty.
  # Before the pool existed, something may have created folders there on the
  # system disk (an older configuration made /bulk/shares at every boot).
  # Empty folders are leftovers and are removed; files are never touched.
  leftover=""
  if [ "$pool" != fast ] && [ -d "/$pool" ] && ! mountpoint -q "/$pool" && [ -n "$(ls -A "/$pool")" ]; then
    stray=$(find "/$pool" -mindepth 1 ! -type d | head -n 3)
    if [ -n "$stray" ]; then
      warn "$(t 'Not possible: /%s already holds files, although no pool is mounted there' "$pool")"
      note "(they are on the system disk), for example:"
      sed 's/^/      /' <<<"$stray"
      note "$(t 'Move the folder out of the way, then try again:  sudo mv /%s /%s.old' "$pool" "$pool")"
      exit 1
    fi
    leftover="/$pool"
  fi
  if ! $encrypt && person && ! $dry && confirm "Encrypt the new pool? (ZFS native encryption, one passphrase for all encrypted disks and pools; you type it next)"; then encrypt=true; fi
  if $encrypt && person && ! $dry; then crypt_new_pass || exit 1; fi
  cmd=(zpool create -o ashift=12 -O compression=lz4 -O atime=off -O xattr=sa)
  # the Incus pool has no mount point of its own, Incus mounts its datasets itself
  [ "$pool" = fast ] && cmd+=(-O mountpoint=none)
  # one passphrase for the whole pool; every dataset below inherits the encryption
  $encrypt && cmd+=(-O encryption=aes-256-gcm -O keyformat=passphrase -O keylocation=prompt)
  cmd+=("$pool" "${vdevs[@]}")
fi

steps 1
pblank
phead "Plan: $mode '$pool' with $(( ${#sel[@]} / 2 )) mirror pair(s)"
pblank
pplan "$plan"
pcmd "$(printf '%s' "${cmd[0]}"; printf ' %q' "${cmd[@]:1}")"
if [ -n "${leftover:-}" ]; then
  pnote "$leftover holds empty folders from before the pool existed ($(ls -A "$leftover" | tr '\n' ' ')); they are removed first."
  pblank
fi

if $dry; then
  pdry
  exit 0
fi

pdanger "ALL DATA on these ${#sel[@]} disks will be erased."
$assume_yes || confirm_name "$pool" "the pool name" || fail "cancelled"

if $encrypt && [ "$mode" = "create the new pool" ]; then
  crypt_new_pass || exit 1
elif $encrypt; then
  echo "Note: --encrypt only applies to a new pool; '$pool' keeps the encryption it has."
fi
for d in "${sel[@]}"; do clean_disk "${d%%$'\t'*}"; done
if [ -n "${leftover:-}" ]; then
  # deepest first; rmdir only removes what is empty
  find "$leftover" -mindepth 1 -depth -type d -exec rmdir {} +
fi
if $encrypt && [ "$mode" = "create the new pool" ]; then
  printf '%s\n' "$crypt_pass" | "${cmd[@]}"
else
  "${cmd[@]}"
fi

# Datasets the configuration expects
if [ "$mode" = "create the new pool" ]; then
  case "$pool" in
    fast) zfs create fast/incus ;;
    bulk)
      zfs create bulk/shares; zfs create bulk/sensitive
      # everything in a share is written as adminuser (the configuration sets
      # this at boot too; without it the new pool would not be writable until then)
      if id adminuser >/dev/null 2>&1; then chown adminuser:users /bulk/shares; chmod 2775 /bulk/shares; fi ;;
  esac
fi

zpool status "$pool" | sed 's/^/      /'
if fancy; then ok "$(t "The pool '%s' is ready" "$pool")"; fi
