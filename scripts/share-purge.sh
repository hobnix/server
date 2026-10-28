#!/usr/bin/env bash
# help: remove a kept folder of a deleted share for good (<share>.deleted-<date>); the files are gone afterwards
# help.de: den aufbewahrten Ordner einer gelöschten Freigabe endgültig entfernen (<Freigabe>.deleted-<Datum>); die Dateien sind danach weg
# args: <share>.deleted-<date> [--dry-run]
# System-layer command behind `hs sys shares start <name> purge` (share-change.sh). It only ever touches folders called
# <name>.deleted-YYYYMMDD directly under /bulk/shares or /bulk/sensitive (what share-delete.sh leaves behind) and refuses a name that
# is still a Samba share. SnapRAID layout: the folder on every data disk is removed (rm -rf, under the bulk lock); ZFS: the dataset
# is destroyed (zfs destroy -r). --dry-run prints the commands, indented. Copies in old backup snapshots stay until they age out.
# Test knobs: HS_MNT_BULK, HS_BULK_TYPE_FILE, HS_ZFS, HS_NET, HS_LOCK, HS_BULK_POOL.
set -euo pipefail
name=${1:-}; dry=false
[ "${2:-}" != --dry-run ] || dry=true
if ! [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.deleted-[0-9]{8}$ ]]; then
  echo "usage: share-purge.sh <share>.deleted-<YYYYMMDD> [--dry-run]  (only the folders that deleting a share leaves behind)" >&2
  exit 1
fi
. "$(dirname "$0")/lib/bulkpath.sh"
mnt=${HS_MNT_BULK:-$(disks_root)}
net=${HS_NET:-net}
zfs=${HS_ZFS:-zfs}
pool=${HS_BULK_POOL:-bulk}
bulk_type=$(cat "${HS_BULK_TYPE_FILE:-/etc/hs/bulk-type}" 2>/dev/null || echo zfs)

if "$net" conf listshares 2>/dev/null | grep -qixF -- "$name"; then
  echo "'$name' is still a Samba share: delete the share first." >&2
  exit 1
fi

targets=()
if [ "$bulk_type" = snapraid ]; then
  for kind in shares sensitive; do
    for d in "$mnt"/data-*/"$kind/$name"; do
      [ -d "$d" ] && targets+=("$d")
    done
  done
else
  for kind in shares sensitive; do
    if "$zfs" list -H -o name "$pool/$kind/$name" >/dev/null 2>&1; then targets+=("$pool/$kind/$name"); fi
  done
fi
if [ ${#targets[@]} -eq 0 ]; then
  echo "There is no kept folder called '$name'." >&2
  exit 1
fi

if $dry; then
  for t in "${targets[@]}"; do
    if [ "$bulk_type" = snapraid ]; then printf '  rm -rf %s\n' "$t"; else printf '  zfs destroy -r %s\n' "$t"; fi
  done
  exit 0
fi

# nothing may write while the folders go: the same lock as parity sync, the cache mover and a rename
exec 9>"${HS_LOCK:-/run/hs-bulk.lock}"
flock -w 600 9 || { echo "Parity sync or cache mover is running, try again later." >&2; exit 1; }
for t in "${targets[@]}"; do
  if [ "$bulk_type" = snapraid ]; then rm -rf -- "$t"; else "$zfs" destroy -r "$t"; fi
  echo "removed $t"
done
echo "'$name' is gone for good."
