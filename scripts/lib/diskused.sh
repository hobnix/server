# Used bytes of the files on a disk that is not mounted, read from the filesystem's superblock (nothing is mounted or written):
# ext4, xfs, btrfs. A disk without any filesystem is 0. Empty output = not known (other filesystems such as ntfs, LUKS, a damaged superblock,
# or a sleeping HDD that has no answer cached): the interface then shows only the size.
# The answer is cached for 6 hours per disk (HS_DISK_USED_DIR, default /var/lib/hs/disk-used), so looking at the overview does not read
# every disk again, and a spinning disk that sleeps is never woken for it (its last answer, however old, is used instead).
# usage: disk_used_bytes <kernel name, e.g. sdc>

_disk_used_read() {   # the superblocks of every partition (or of the bare disk)
  local dev="/dev/$1" path fst u total=0 seen=false
  while read -r path fst; do
    [ -n "$fst" ] || continue
    case "$fst" in
      ext4) u=$(dumpe2fs -h "$path" 2>/dev/null | awk -F: '/^Block count:/ { b = $2 + 0 } /^Free blocks:/ { f = $2 + 0 } /^Block size:/ { s = $2 + 0 } END { if (s && b) printf "%.0f", (b - f) * s }' || true) ;;
      xfs) u=$(xfs_db -r -c 'sb 0' -c 'p dblocks fdblocks blocksize' "$path" 2>/dev/null | awk '$1 == "dblocks" { b = $3 } $1 == "fdblocks" { f = $3 } $1 == "blocksize" { s = $3 } END { if (s && b) printf "%.0f", (b - f) * s }' || true) ;;
      btrfs) u=$(btrfs inspect-internal dump-super "$path" 2>/dev/null | awk '$1 == "bytes_used" { printf "%s", $2 }' || true) ;;
      zfs_member) continue ;;   # an old ZFS label: no files
      *) return 0 ;;
    esac
    [[ "$u" =~ ^[0-9]+$ ]] || return 0
    total=$((total + u)); seen=true
  done < <(lsblk -nr -o PATH,FSTYPE "$dev" 2>/dev/null | tail -n +2 || true)
  # no partition has a filesystem: also look at the bare disk (a filesystem without a partition table)
  if ! $seen; then
    local fst
    fst=$(lsblk -dnr -o FSTYPE "$dev" 2>/dev/null || true)
    case "$fst" in
      "") printf '0'; return 0 ;;
      ext4|xfs|btrfs) ;;
      *) return 0 ;;
    esac
    case "$fst" in
      ext4) u=$(dumpe2fs -h "$dev" 2>/dev/null | awk -F: '/^Block count:/ { b = $2 + 0 } /^Free blocks:/ { f = $2 + 0 } /^Block size:/ { s = $2 + 0 } END { if (s && b) printf "%.0f", (b - f) * s }' || true) ;;
      xfs) u=$(xfs_db -r -c 'sb 0' -c 'p dblocks fdblocks blocksize' "$dev" 2>/dev/null | awk '$1 == "dblocks" { b = $3 } $1 == "fdblocks" { f = $3 } $1 == "blocksize" { s = $3 } END { if (s && b) printf "%.0f", (b - f) * s }' || true) ;;
      btrfs) u=$(btrfs inspect-internal dump-super "$dev" 2>/dev/null | awk '$1 == "bytes_used" { printf "%s", $2 }' || true) ;;
    esac
    [[ "$u" =~ ^[0-9]+$ ]] || return 0
    printf '%s' "$u"; return 0
  fi
  printf '%s' "$total"
}

disk_used_bytes() {
  local name=$1 dir=${HS_DISK_USED_DIR:-/var/lib/hs/disk-used} key cache now ts used rota st
  key=$(lsblk -dnr -o SERIAL "/dev/$name" 2>/dev/null | tr -c 'A-Za-z0-9._-' '_' || true)
  [ -n "$key" ] || key=$name
  key="$key-$(lsblk -dnbr -o SIZE "/dev/$name" 2>/dev/null || true)"
  cache="$dir/$key"
  now=$(date +%s)
  if [ -r "$cache" ]; then
    IFS=$'\t' read -r ts used < "$cache" || true
    if [[ "$ts" =~ ^[0-9]+$ ]] && [ $((now - ts)) -lt 21600 ]; then printf '%s' "$used"; return 0; fi
  fi
  # a sleeping HDD is not woken: the old answer (or nothing)
  rota=$(lsblk -dnr -o ROTA "/dev/$name" 2>/dev/null || true)
  if [ "$rota" = 1 ] && command -v hdparm >/dev/null 2>&1; then
    st=$(hdparm -C "/dev/$name" 2>/dev/null | awk -F: '/drive state is/ { gsub(/[ \t]/, "", $2); print $2 }' || true)
    case "$st" in standby|sleeping) printf '%s' "${used:-}"; return 0 ;; esac
  fi
  used=$(_disk_used_read "$name" || true)
  if mkdir -p "$dir" 2>/dev/null; then printf '%s\t%s\n' "$now" "$used" > "$cache" 2>/dev/null || true; fi
  printf '%s' "$used"
}
