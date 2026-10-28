#!/usr/bin/env bash
# help: look at the disks of an old server before adopting them (Unraid move): filesystem, encryption, health, size; changes nothing
# help.de: sieht sich die Platten eines alten Servers an, bevor sie übernommen werden (Umzug von Unraid): Dateisystem, Verschlüsselung, Zustand, Größe; ändert nichts
# args: [--parity <disk>] [--dry-run]
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"

usage() {
  say "usage: hs migrate check [--parity <disk>]"
  say "  Reads every disk that is not part of this server: filesystem (xfs/ext4/btrfs can be adopted),"
  say "  encryption (LUKS: needs the passphrase), whether it can be read, how much is on it, and its"
  say "  SMART verdict. Changes nothing (plain filesystems are only looked into read-only, without"
  say "  replaying a log)."
  say "  --parity    the disk that becomes the parity disk (name in /dev/disk/by-id); it is compared"
  say "              with the largest data disk"
  exit 1
}

parity=""
while [ $# -gt 0 ]; do
  case "$1" in
    --parity)  [ $# -ge 2 ] || usage; parity=$2; shift 2 ;;
    --dry-run) shift ;;                  # reads only: accepted for symmetry with the other commands
    -h|--help) usage ;;
    *) usage ;;
  esac
done

# verdicts by kernel name, from hs disk list (name size kind model verdict hours note)
declare -A verdict note
while IFS=$'\t' read -r n _ _ _ v _ w; do
  [ -n "$n" ] || continue
  verdict[$n]=$v; note[$n]=$w
done < <(bash "$here/disk-health.sh" --list 2>/dev/null || true)

human() { numfmt --to=si --suffix=B --format='%.1f' "$1"; }

inspect_fs() {   # inspect_fs <device> <fstype>: used bytes, or "unreadable"
  local dev=$1 fs=$2 tmp opts=ro used
  case "$fs" in xfs) opts=ro,norecovery ;; ext4) opts=ro,noload ;; esac
  tmp=$(mktemp -d)
  if mount -t "$fs" -o "$opts" "$dev" "$tmp" 2>/dev/null; then
    used=$(df -B1 --output=used "$tmp" | tail -n1 | tr -d ' ')
    umount "$tmp"; rmdir "$tmp"
    echo "$used"
  else
    rmdir "$tmp"
    echo unreadable
  fi
}

step "Disks that are not part of this server"
rows=()
problems=0
adoptable=0
max_data=0
total_used=0
# ADOPT_LISTING: encrypted disks are listed too
while IFS=$'\t' read -r id size _ _; do
  [ -n "$id" ] || continue
  dev="/dev/disk/by-id/$id"
  kname=$(basename "$(readlink -f "$dev")")
  fs="-"; part=""
  while read -r p; do
    t=$(blkid -p -o value -s TYPE "$p" 2>/dev/null || true)
    case "$t" in xfs|ext4|btrfs|crypto_LUKS|ntfs|exfat|vfat) fs=$t; part=$p ;; esac
  done < <(lsblk -nr -o PATH "$dev")
  what=""; used="-"
  case "$fs" in
    xfs|ext4|btrfs)
      used=$(inspect_fs "$part" "$fs")
      if [ "$used" = unreadable ]; then what="$(t 'NOT READABLE: not shut down cleanly? Stop the old server properly, or repair it (%s)' "$([ "$fs" = xfs ] && echo xfs_repair || echo fsck)")"; problems=$((problems + 1))
      else what="$(t 'can be adopted')"; adoptable=$((adoptable + 1)); total_used=$((total_used + used)); used=$(human "$used")
        [ "$size" -le "$max_data" ] || max_data=$size
      fi ;;
    crypto_LUKS) what="$(t 'encrypted: adopting asks for the passphrase (hs unlock)')"; adoptable=$((adoptable + 1))
        [ "$size" -le "$max_data" ] || max_data=$size ;;
    ntfs|exfat|vfat) what="$(t '%s: copy it with hs disk temp, it cannot be adopted' "$fs")"; problems=$((problems + 1)) ;;
    *) what="$(t 'no filesystem found')" ;;
  esac
  v=${verdict[$kname]:-unknown}
  case "$v" in BAD) problems=$((problems + 1)); what="$what; $(t 'SMART says BAD: %s' "${note[$kname]:-}")" ;;
                WATCH) what="$what; $(t 'SMART: %s' "${note[$kname]:-watch it}")" ;; esac
  rows+=("$id"$'\t'"$(human "$size")"$'\t'"$fs"$'\t'"$used"$'\t'"$v"$'\t'"$what")
done < <(ADOPT_LISTING=1 bash "$here/manage-pool.sh" --list-disks 2>/dev/null || true)

if [ ${#rows[@]} -eq 0 ]; then
  warn "No other disk found. Plug the old disks in first (the system disk and this server's own disks are not listed)."
  exit 0
fi
{ thead 'disk' 'size' 'filesystem' 'used' 'smart' 'verdict'; printf '%s\n' "${rows[@]}"; } | table

step "Summary"
if [ "$problems" -eq 0 ]; then status_line "Problems" "None" ok; else status_line "Problems" "$(t '%s disk(s), see the last column' "$problems")" warn; fi
ok "$(t '%s disk(s) can be adopted, holding about %s of readable data' "$adoptable" "$(human "$total_used")")"
if [ -n "$parity" ]; then
  psize=$(blockdev --getsize64 "/dev/disk/by-id/$parity" 2>/dev/null || echo 0)
  if [ "$psize" -eq 0 ]; then warn "$(t "No disk '%s' in /dev/disk/by-id" "$parity")"
  elif [ "$psize" -lt "$max_data" ]; then warn "$(t 'The parity disk (%s) is smaller than the largest data disk (%s): not possible' "$(human "$psize")" "$(human "$max_data")")"
  else ok "$(t 'The parity disk (%s) is at least as large as the largest data disk (%s)' "$(human "$psize")" "$(human "$max_data")")"
       note "Disks that are almost full need some room: a parity disk of exactly the same size is tight."
  fi
else
  note "$(t 'The parity disk must be at least as large as the largest data disk (%s). Check one with: hs migrate check --parity <disk>' "$(human "$max_data")")"
fi
note "Next: hs pool bulk add --role adopt --dry-run"
