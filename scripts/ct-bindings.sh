#!/usr/bin/env bash
# help: the storage of an instance and what is behind each binding: pool, disks, size, backup, upload cache, who else mounts it
# help.de: der Speicher einer Instanz und was hinter jeder Einbindung steckt: Pool, Platten, Größe, Backup, Upload-Cache, wer sie noch einhängt
# args: <instance>
# System command (hs sys ct bindings <ct>), read only, tab separated, one line per binding (the Instances view of the interface):
#   binding  kind  pool  source  inside  mode  cache  backup  share  used_bytes  disks  also_used_by
#   kind        shares | sensitive | fast | other (as manage-ct.sh --storage says)
#   pool        bulk (shares, sensitive), fast (volumes), "-" otherwise
#   source      the host folder, or "volume <name>"
#   mode        read | write
#   cache       the upload cache of the share: on | off | emptying, "-" where there is none (manage-ct.sh --storage)
#   backup      is the share in the nightly backup: on | off, "-" for a volume (backup.sh --shares)
#   share       the Samba share the folder belongs to, "-" for a volume
#   used_bytes  from /var/lib/hs/share-sizes (measured nightly), "-" when not measured
#   disks       where the folder lives on the SnapRAID layout (data-01,data-02), the pool name on ZFS, "-" for a volume
#   also_used_by  the other instances that mount the same folder, name(ro|rw), comma separated, "-" for none
# Test knobs: HS_STATE_DIR, HS_MNT_BULK, HS_INCUS, HS_MANAGE_CT, HS_BACKUP, HS_BULK_TYPE_FILE.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/bulkpath.sh"
ct=${1:-}
[ -n "$ct" ] || { echo "usage: ct-bindings.sh <instance>" >&2; exit 1; }
state=${HS_STATE_DIR:-/var/lib/hs}
mnt=${HS_MNT_BULK:-$(disks_root)}
bulk_type=$(cat "${HS_BULK_TYPE_FILE:-/etc/hs/bulk-type}" 2>/dev/null || echo zfs)

rows=$(bash "${HS_MANAGE_CT:-$here/manage-ct.sh}" "$ct" --storage 2>/dev/null || true)
[ -n "$rows" ] || exit 0

# which shares are in the backup
declare -A backup=()
while IFS=$'\t' read -r kind name flag; do
  [ "$kind" = share ] && backup[$name]=$flag
done < <(bash "${HS_BACKUP:-$here/backup.sh}" --shares 2>/dev/null || true)

# measured sizes
declare -A size=()
if [ -f "$state/share-sizes" ]; then
  while IFS=$'\t' read -r path bytes; do size[$path]=$bytes; done < "$state/share-sizes"
fi

# the other instances that mount the same thing: one incus call for everybody
declare -A usedby=()
while IFS=$'\t' read -r who source ro; do
  [ "$who" != "$ct" ] || continue
  usedby[$source]+="${usedby[$source]:+,}$who($([ "$ro" = true ] && echo ro || echo rw))"
done < <(${HS_INCUS:-incus} list -f json 2>/dev/null | jq -r '.[] | .name as $n | .expanded_devices | to_entries[]
    | select(.value.type == "disk" and (.value.path // "") != "/")
    | [ $n, (if (.value.pool // "") != "" then "volume " + .value.source else (.value.source // "") end), (.value.readonly // "false") ] | @tsv' || true)

while IFS=$'\t' read -r dev kind source path access cache; do
  pool=- share=- used=- disks=- bk=-
  case "$kind" in
    shares|sensitive)
      pool=bulk
      rel=${source#/bulk/}                 # shares/media or sensitive/immich/sub
      share=${rel#*/}; share=${share%%/*}
      bk=${backup[$share]:--}
      used=${size[$source]:--}
      if [ "$bulk_type" = snapraid ]; then
        found=""
        for d in "$mnt"/data-*; do
          [ -d "$d/$rel" ] && found+="${found:+,}${d##*/}"
        done
        disks=${found:--}
      else
        disks=bulk
      fi ;;
    fast) pool=fast ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$dev" "$kind" "$pool" "$source" "$path" "$access" "${cache:--}" "$bk" "$share" "$used" "$disks" "${usedby[$source]:--}"
done <<<"$rows"
