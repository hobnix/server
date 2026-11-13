#!/usr/bin/env bash
# help: what the server finds on its disks: one line per whole disk with size, bus, model, what it holds and in which state (read only)
# help.de: was der Server auf seinen Platten findet: eine Zeile je ganze Platte mit Größe, Anschluss, Modell, Inhalt und Zustand (nur lesend)
# System command (hs sys storage discover), read only, tab separated, plain, never asks and never takes a lock. One line per whole
# disk, no header, no empty field (an empty value is written -); a new column is only ever appended:
#   disk  size  bus  model  kind  label  state
#   disk   name under /dev/disk/by-id          size   bytes
#   bus    sata|nvme|usb|sas|virtio|other      model  the model with _ for spaces
#   kind/label/state:
#     os       -                    system                    holds / or /boot, or the install stick
#     empty    -                    free                      no partition table, no signature
#     zfs      pool name or -       imported|importable|damaged   (damaged: the pool lists a missing device)
#     snapraid bulk-data-NN|bulk-parity-N  mounted|unmounted
#     backup   backup               protected
#     luks     -                    locked|open               encrypted, the contents are unknown
#     foreign  filesystems, comma separated, or -   has-data  anything else
# It only looks: lsblk, blkid, findmnt, readlink, zpool status and zpool import WITHOUT a pool name (a listing, never an import).
# Test knobs: HS_ZPOOL, HS_BYID, HS_SYSFS, HS_TEST_LOOP.
set -euo pipefail
here=$(dirname "$0")
# shellcheck source=lib/ui.sh
. "$here/lib/ui.sh"
# shellcheck source=lib/diskpath.sh
. "$here/lib/diskpath.sh"
[ $# -eq 0 ] || { fail "usage: hs sys storage discover (no arguments)"; exit 1; }

zpool=${HS_ZPOOL:-zpool}
byid=${HS_BYID:-/dev/disk/by-id}
tab=$'\t'

declare -A pool_of pool_src pool_key pool_bad
# pool_scan <source> <command...>: read the "pool / config" text of zpool and map every member that is a disk here to its pool
pool_scan() {
  local src=$1 out p m st id r
  shift
  out=$("$@" 2>/dev/null) || return 0
  while IFS="$tab" read -r p m st id; do
    # keyed by source, pool name and pool id: two pools may share a name
    case "$st" in UNAVAIL|FAULTED|REMOVED) pool_bad["$src|$p|$id"]=1 ;; esac
    case "$m" in /dev/disk/by-id/*) m="$byid/${m#/dev/disk/by-id/}" ;; /*) ;; *) m="$byid/$m" ;; esac
    r=$(readlink -f "$m" 2>/dev/null || true)
    r=${r##*/}
    r=$(sed -E 's/^((sd|vd|xvd|hd)[a-z]+)[0-9]+$/\1/; s/^((nvme[0-9]+n[0-9]+|mmcblk[0-9]+|loop[0-9]+))p[0-9]+$/\1/' <<<"$r")
    [ -n "$r" ] || continue
    [ -z "${pool_of[$r]:-}" ] || continue
    pool_of[$r]=$p; pool_src[$r]=$src; pool_key[$r]="$src|$p|$id"
  done < <(awk '
    /^[ \t]*pool:/ { pool = $2; cfg = 0; next }
    /^[ \t]*config:/ { cfg = 1; next }
    /^[ \t]*errors:/ { cfg = 0; next }
    cfg && NF >= 2 && $1 != "NAME" && $1 != pool && $1 !~ /^(mirror|raidz[123]?|draid[0-9a-z:]*|spares?|logs?|cache|special|dedup|replacing)(-[0-9]+)?$/ \
      && $2 ~ /^(ONLINE|DEGRADED|UNAVAIL|FAULTED|OFFLINE|REMOVED|AVAIL|INUSE)$/ { print pool "\t" $1 "\t" $2 }
  ' <<<"$out")
}
if command -v "$zpool" >/dev/null 2>&1; then
  pool_scan imported "$zpool" status -P
  pool_scan importable "$zpool" import -d "$byid"
fi

bus_of() {   # bus_of <name> <tran>
  case "$2" in sata|ata) echo sata; return ;; nvme|usb|sas) echo "$2"; return ;; esac
  case "$1" in nvme*) echo nvme ;; vd*) echo virtio ;; *) echo other ;; esac
}

while read -r name size type; do
  [ "$type" = disk ] || { [ -n "${HS_TEST_LOOP:-}" ] && [ "$type" = loop ]; } || continue
  [ "$size" -gt 0 ] 2>/dev/null || continue
  [[ "$name" == zd* ]] && continue
  second_path "$name" && continue
  id=$(stable_id "$name" || true)
  [ -n "$id" ] || continue
  dev=/dev/$name
  bus=$(bus_of "$name" "$(lsblk -dn -o TRAN "$dev" 2>/dev/null | awk 'NR == 1' | tr -d ' ' || true)")
  model=$(lsblk -dn -o MODEL "$dev" 2>/dev/null | awk 'NR == 1' | sed -E 's/^ +//; s/ +$//; s/ +/_/g' || true)
  [ -n "$model" ] || model=-
  fstypes=$(lsblk -nr -o FSTYPE "$dev" 2>/dev/null | grep -v '^$' || true)
  whole=$(blkid -p -o value -s TYPE "$dev" 2>/dev/null || true)
  [ -z "$whole" ] || fstypes=$(printf '%s\n%s\n' "$fstypes" "$whole" | grep -v '^$')
  labels=$(lsblk -nr -o LABEL "$dev" 2>/dev/null | grep -v '^$' || true)
  mounts=$(lsblk -nr -o MOUNTPOINT "$dev" 2>/dev/null | grep -v '^$' || true)
  types=$(lsblk -nr -o TYPE "$dev" 2>/dev/null || true)
  pttype=$(lsblk -dn -o PTTYPE "$dev" 2>/dev/null | tr -d ' ' || true)
  [ -n "$pttype" ] || pttype=$(blkid -p -o value -s PTTYPE "$dev" 2>/dev/null || true)

  kind=foreign label=- state=has-data
  if grep -qxE '/|/boot|/boot/efi|/iso|/nix/store' <<<"$mounts"; then
    kind=os state=system
  elif grep -qx zfs_member <<<"$fstypes" || [ -n "${pool_of[$name]:-}" ]; then
    kind=zfs
    if [ -n "${pool_of[$name]:-}" ]; then
      label=${pool_of[$name]}
      state=${pool_src[$name]}
      [ -z "${pool_bad[${pool_key[$name]}]:-}" ] || state=damaged
    else
      state=importable
    fi
  elif grep -qE '^bulk-(data|parity)-' <<<"$labels"; then
    kind=snapraid label=$(grep -E '^bulk-(data|parity)-' <<<"$labels" | awk 'NR == 1')
    if [ -n "$mounts" ]; then state=mounted; else state=unmounted; fi
  elif grep -qx backup <<<"$labels"; then
    kind=backup label=backup state=protected
  elif grep -qx crypto_LUKS <<<"$fstypes"; then
    kind=luks
    if grep -qx crypt <<<"$types"; then state=open; else state=locked; fi
  elif [ -z "$fstypes" ] && [ -z "$pttype" ] && [ "$(grep -c . <<<"$types")" -le 1 ]; then
    kind=empty state=free
  else
    label=$(sort -u <<<"$fstypes" | grep -v '^$' | paste -sd, || true)
    [ -n "$label" ] || label=-
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$size" "$bus" "$model" "$kind" "$label" "$state"
done < <(lsblk -dnb -o NAME,SIZE,TYPE 2>/dev/null)
