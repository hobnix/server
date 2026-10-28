#!/usr/bin/env bash
# help: mount a disk that has data on it (hot-plug, USB), share it over Samba, copy from it, eject
# help.de: hängt eine Platte mit Daten ein (Hot-Plug, USB), gibt sie per Samba frei, kopiert davon, wirft sie aus
# args: [list | mount <device> [--rw] [--name <n>] | copy <name> <share> | eject [name]] [--dry-run]
# Used by the web interface (Disks): `raw` prints device|fs|label|bytes|mountpoints per line.
set -euo pipefail
. "$(dirname "$0")/lib/ui.sh"

usage() {
  while IFS= read -r _l; do say "$_l"; done <<'EOF'
usage: hs disk temp [list]
       hs disk temp mount <device> [--rw] [--name <name>] [--dry-run]
       hs disk temp copy <name> <share> [--dry-run]
       hs disk temp eject [name]

  list    disks that are not part of this server (nothing is changed)
  mount   mount a partition read-only under /mnt/temp/<name> and share it as
          temp-<name> (only Domain Admins at first). --rw makes it writable.
          The data on the disk is never formatted or changed by mounting.
  copy    rsync the whole disk into /bulk/shares/<share> on the server
  eject   remove the share and unmount; afterwards it is safe to unplug
EOF
  exit 1
}

die() { fail "$@" >&2; }   # the same red line as everywhere, on stderr

dry=false
args=()
for a in "$@"; do
  case "$a" in
    --dry-run) dry=true ;;
    -h|--help) usage ;;
    *) args+=("$a") ;;
  esac
done
set -- "${args[@]+"${args[@]}"}"
cmd=${1:-list}
[ $# -gt 0 ] && shift

TEMP_ROOT=/mnt/temp

# Partitions that may be mounted here: every filesystem on a disk that holds
# neither the system, nor a ZFS/SnapRAID/RAID member, nor swap. One line per
# partition: device|fstype|label|bytes|mountpoints
candidates() {
  # -l: flat list, partitions are tied to their disk by PKNAME (the JSON of
  # a tree and of a list differ between lsblk versions and column sets)
  lsblk -J -l -b -o NAME,PKNAME,PATH,TYPE,FSTYPE,LABEL,SIZE,MOUNTPOINTS | jq -r '
    .blockdevices as $all
    | def below($n): $all[] | select(.pkname == $n) | ., below(.name);
    $all[] | select(.type == "disk" and (.size | tonumber) > 0
                    and (.path | test("^/dev/(zd|loop|ram)") | not))
    | . as $d | [$d, below($d.name)] as $grp
    | ($grp | map(.mountpoints // [] | map(select(. != null))) | flatten) as $mps
    | select(
        ($mps | any(. == "/" or startswith("/boot") or startswith("/nix")
                    or startswith("/bulk") or startswith("/mnt/bulk") or startswith("/var/lib/hs/disks")
                    or startswith("/var/lib/incus") or startswith("[SWAP"))
         or ($grp | any(.fstype == "zfs_member" or .fstype == "swap"
                        or .fstype == "linux_raid_member" or .fstype == "LVM2_member"
                        or ((.label // "") | test("^(bulk-(data|parity)-|backup$)")))))
        | not)
    | $grp[] | select(.fstype != null and .fstype != "")
    | [.path, .fstype, (.label // ""), (.size | tostring),
       ((.mountpoints // []) | map(select(. != null)) | join(","))]
    | join("|")'
}

# Shares of disks that were pulled without `eject` leave a stale entry behind
cleanup_stale() {
  local s p
  while read -r s; do
    case "$s" in
      temp-*)
        p=$(net conf getparm "$s" path 2>/dev/null || true)
        if [ -z "$p" ] || ! findmnt -rn "$p" >/dev/null 2>&1; then
          net conf delshare "$s" 2>/dev/null || true
        fi ;;
    esac
  done < <(net conf listshares 2>/dev/null || true)
}

sanitize() {
  local n
  n=$(printf %s "$1" | tr 'A-Z ' 'a-z-' | tr -cd 'a-z0-9-')
  printf %s "${n:-disk}"
}

cmd_list() {
  local rows dev fs label bytes mps state
  rows=$(while IFS='|' read -r dev fs label bytes mps; do
    state=$(t 'free (hs disk temp mount %s)' "$dev")
    [ -z "$mps" ] || state=$(t 'mounted at %s' "$mps")
    printf '%s\t%s\t%s\t%s\t%s\n' "$dev" "$fs" "${label:--}" "$(numfmt --to=iec "$bytes")" "$state"
  done < <(candidates))
  if [ -n "$rows" ]; then
    { thead 'Device' 'FS' 'Label' 'Size' 'State'; printf '%s\n' "$rows"; } | table
  else
    note "No other disk found: plug it in, then run this again."
  fi
}

cmd_mount() {
  local dev="" rw=false name="" row fs label mps type opts mp share
  while [ $# -gt 0 ]; do
    case "$1" in
      --rw)   rw=true; shift ;;
      --name) [ $# -ge 2 ] || usage; name=$(sanitize "$2"); shift 2 ;;
      -*)     usage ;;
      *)      [ -z "$dev" ] || usage; dev=$1; shift ;;
    esac
  done
  [ -n "$dev" ] || usage

  row=$(candidates | awk -F'|' -v d="$dev" '$1 == d')
  [ -n "$row" ] || die "$(t '%s is not offered (see: hs disk temp). System, pool and swap disks are never mounted here.' "$dev")"
  IFS='|' read -r _ fs label _ mps <<<"$row"
  [ -z "$mps" ] || die "$(t '%s is already mounted at %s' "$dev" "$mps")"

  [ -n "$name" ] || name=$(sanitize "${label:-$(basename "$dev")}")
  mp=$TEMP_ROOT/$name
  share=temp-$name
  findmnt -rn "$mp" >/dev/null 2>&1 && die "$(t '%s is already in use, pick another --name' "$mp")"
  grep -qix "$share" < <(net conf listshares 2>/dev/null) && die "$(t 'A share called %s already exists, pick another --name' "$share")"

  case "$fs" in
    ntfs)
      type=ntfs3
      grep -qw ntfs3 /proc/filesystems || type=ntfs-3g ;;
    exfat|vfat|ext2|ext3|ext4|xfs|btrfs) type=$fs ;;
    *) die "$(t "Filesystem '%s' is not supported here (NTFS, exFAT, FAT, ext4, XFS, btrfs are)." "$fs")" ;;
  esac
  opts=noatime
  if $rw; then opts+=,rw; else opts+=,ro; fi

  # A domain: only Domain Admins at first, like every new share
  local admins="" admins_sid=""
  if [ "$(testparm -s --parameter-name=security 2>/dev/null)" = "ADS" ]; then
    admins="$(testparm -s --parameter-name=workgroup 2>/dev/null)\Domain Admins"
    admins_sid=$(wbinfo -n "$admins" 2>/dev/null | cut -d" " -f1 || true)
    [ -n "$admins_sid" ] || die "$(t "Can't look up %s (is winbind running?), the share would start open." "$admins")"
  fi

  echo "Disk:   $dev ($fs${label:+, \"$label\"})"
  echo "Mount:  $mp ($type, $($rw && echo read-write || echo read-only))"
  echo "Share:  \\\\$(hostname)\\$share${admins:+ (only $admins)}"
  if $dry; then echo "(dry run, nothing changed)"; exit 0; fi

  mkdir -p "$mp"
  if ! mount -t "$type" -o "$opts" "$dev" "$mp"; then
    rmdir "$mp" 2>/dev/null || true
    ! $rw || warn "Hint: a disk Windows did not shut down cleanly mounts read-only only (or after a check in Windows)." >&2
    exit 1
  fi
  # when it was mounted, for the health check (/run is cleared at a restart, like the mount)
  mkdir -p "${HS_RUN_DIR:-/run/hs}"; date +%s > "${HS_RUN_DIR:-/run/hs}/temp-$name.since"
  # force user root: whatever owner the files have on the disk, the share can read them
  net conf addshare "$share" "$mp" "writeable=$($rw && echo y || echo n)" guest_ok=n
  net conf setparm "$share" "force user" root
  if [ -n "$admins" ]; then
    sharesec "$share" --replace "$admins_sid:ALLOWED/0x0/FULL" ||
      warn "$(t 'could not restrict %s, it is open to every domain user' "$share")"
  fi
  ok "$(t 'Mounted and shared as %s' "$share")"
  note "$(t 'Browse it from Windows, or copy on the server: hs disk temp copy %s <share>' "$name")"
  note "$(t 'Done with it? hs disk temp eject %s' "$name")"
}

cmd_copy() {
  [ $# -eq 2 ] || usage
  local name=$1 dest=$2 src target used avail
  src=$TEMP_ROOT/$name
  target=/bulk/shares/$dest
  findmnt -rn "$src" >/dev/null 2>&1 || die "$(t '%s is not mounted (see: hs disk temp)' "$name")"
  [ -d "$target" ] || die "$(t 'No share %s. Create it first: hs share add %s' "$dest" "$dest")"

  used=$(df -B1 --output=used "$src" | tail -n1 | tr -d ' ')
  avail=$(df -B1 --output=avail "$target" | tail -n1 | tr -d ' ')
  step "$(t 'Copy %s' "$name")"
  kv "From" "$(t '%s (%s on the disk)' "$src" "$(numfmt --to=iec "$used")")"
  kv "To" "$(t '%s (%s free)' "$target" "$(numfmt --to=iec "$avail")")"
  [ "$used" -le "$avail" ] || die "$(t 'Not enough room in %s.' "$target")"

  # Written as adminuser like everything on the shares; Windows leftovers skipped
  local r=(rsync -rltD --partial --info=progress2 --human-readable
           --chmod=D775,F664 --chown=adminuser:users
           --exclude='$RECYCLE.BIN' --exclude='System Volume Information')
  $dry && r+=(--dry-run)
  "${r[@]}" "$src/" "$target/"
  ok "$(t 'Copied. Check the result, then: hs disk temp eject %s' "$name")"
}

eject_one() {
  local mp=$1 name share
  name=$(basename "$mp")
  share=temp-$name
  # Close open Windows connections first, otherwise the unmount is busy
  smbcontrol smbd close-share "$share" >/dev/null 2>&1 || true
  net conf delshare "$share" 2>/dev/null || true
  sync
  if umount "$mp"; then
    rmdir "$mp" 2>/dev/null || true
    rm -f "${HS_RUN_DIR:-/run/hs}/temp-$name.since"
    ok "$(t '%s: unmounted, safe to unplug' "$name")"
  else
    warn "$(t '%s: still in use (a shell in %s, or a running copy). The share is removed; close it and run eject again.' "$name" "$mp")" >&2
    return 1
  fi
}

cmd_eject() {
  local mp rc=0 any=0
  if [ $# -ge 1 ]; then
    # the mount is named after the partition (sdg1); a disk name (sdg) ejects its partitions
    local m mounted=()
    while read -r m; do
      case "${m##*/}" in "$1"|"$1"[0-9]|"$1"p[0-9]) mounted+=("$m") ;; esac
    done < <(findmnt -rn -o TARGET | grep "^$TEMP_ROOT/" || true)
    if [ ${#mounted[@]} -eq 0 ]; then
      die "$(t '%s is not mounted. Mounted: %s' "$1" "$(findmnt -rn -o TARGET | grep "^$TEMP_ROOT/" | sed "s|^$TEMP_ROOT/||" | paste -sd' ' - || true)")"
    fi
    for m in "${mounted[@]}"; do eject_one "$m" || rc=1; done
    return $rc
  fi
  while read -r mp; do
    any=1
    eject_one "$mp" || rc=1
  done < <(findmnt -rn -o TARGET | grep "^$TEMP_ROOT/" || true)
  [ "$any" = 1 ] || line "$(t 'Nothing is mounted under %s.' "$TEMP_ROOT")"
  return $rc
}

cleanup_stale
case "$cmd" in
  list)  cmd_list ;;
  raw)   candidates ;;
  mount) cmd_mount "$@" ;;
  copy)  cmd_copy "$@" ;;
  eject) cmd_eject "$@" ;;
  *)     usage ;;
esac
