#!/usr/bin/env bash
# help: bring a kept folder of a deleted share back as a share under its old name (<share>.deleted-<date> -> <share>); nothing is overwritten or removed
# help.de: einen aufbewahrten Ordner einer gelöschten Freigabe unter dem alten Namen wieder als Freigabe zurückholen (<Freigabe>.deleted-<Datum> -> <Freigabe>); nichts wird überschrieben oder entfernt
# args: <share>.deleted-<date> [--dry-run]
# System-layer command behind `hs sys shares start <name> undelete` (share-change.sh), the opposite of share-delete.sh. It mirrors how the
# delete kept the folder: SnapRAID layout = the folder on every data disk is renamed (mv), ZFS = the dataset is renamed (zfs rename), both
# under the bulk lock. It refuses when a Samba share, a folder or a dataset of the old name exists already (so nothing is merged or
# overwritten), and it never deletes. Then sync-shares.sh publishes the folder as a Samba share and hands the files to adminuser (what
# `hs share repair` does). The delete dropped the share's Samba settings and permissions, so the share starts closed (Domain Admins only);
# the mounts of instances are not put back. A backup switch the delete moved to the kept name is moved back.
# --dry-run prints the commands, indented. Test knobs: HS_MNT_BULK, HS_BULK_TYPE_FILE, HS_ZFS, HS_NET, HS_LOCK, HS_BULK_POOL, HS_SYNC_SHARES, HS_STATE_DIR.
set -euo pipefail
kept=${1:-}; dry=false
[ "${2:-}" != --dry-run ] || dry=true
if ! [[ "$kept" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.deleted-[0-9]{8}$ ]]; then
  echo "usage: share-undelete.sh <share>.deleted-<YYYYMMDD> [--dry-run]  (only the folders that deleting a share leaves behind)" >&2
  exit 1
fi
orig=${kept%.deleted-*}
here=$(dirname "$0")
. "$here/lib/bulkpath.sh"
mnt=${HS_MNT_BULK:-$(disks_root)}
net=${HS_NET:-net}
zfs=${HS_ZFS:-zfs}
pool=${HS_BULK_POOL:-bulk}
sync=${HS_SYNC_SHARES:-$here/sync-shares.sh}
state=${HS_STATE_DIR:-/var/lib/hs}
bulk_type=$(cat "${HS_BULK_TYPE_FILE:-/etc/hs/bulk-type}" 2>/dev/null || echo zfs)

[ "${#orig}" -le 80 ] || { echo "The name is too long." >&2; exit 1; }
case "${orig,,}" in shares|sensitive|global|homes|printers) echo "'$orig' is a reserved name." >&2; exit 1 ;; esac
listed=$("$net" conf listshares 2>/dev/null || true)   # read once: grep -q on a pipe would end the producer early (pipefail)
is_listed() { awk -v n="$1" 'tolower($0) == tolower(n) { f = 1 } END { exit !f }' <<<"$listed"; }
if is_listed "$kept"; then
  echo "'$kept' is still a Samba share: it is not a kept folder." >&2; exit 1
fi
if is_listed "$orig"; then
  echo "A share called '$orig' exists already: rename or delete it first, nothing is merged." >&2; exit 1
fi

# the kept folders (one per data disk, or the dataset) and the places the old name must be free
targets=() kinds=()
for kind in shares sensitive; do
  if [ "$bulk_type" = snapraid ]; then
    for d in "$mnt"/data-*/"$kind"/"$kept"; do
      [ -d "$d" ] || continue
      targets+=("$d"); kinds+=("$kind")
    done
    for d in "$mnt"/data-*/shares/"$orig" "$mnt"/data-*/sensitive/"$orig"; do
      [ ! -e "$d" ] || { echo "$(dirname "$d") has a '$orig' already (the kept folder would merge with it): nothing is changed." >&2; exit 1; }
    done
  else
    if "$zfs" list -H -o name "$pool/$kind/$kept" >/dev/null 2>&1; then targets+=("$pool/$kind/$kept"); kinds+=("$kind"); fi
    if "$zfs" list -H -o name "$pool/$kind/$orig" >/dev/null 2>&1; then
      echo "$pool/$kind/$orig exists already: nothing is changed." >&2; exit 1
    fi
  fi
done
if [ ${#targets[@]} -eq 0 ]; then
  echo "There is no kept folder called '$kept'." >&2
  exit 1
fi
if [ "$(printf '%s\n' "${kinds[@]}" | sort -u | wc -l)" -ne 1 ]; then
  echo "'$kept' exists under both shares and sensitive: restore is unclear, nothing is changed." >&2; exit 1
fi
kind=${kinds[0]}

if $dry; then
  for t in "${targets[@]}"; do
    if [ "$bulk_type" = snapraid ]; then printf '  mv %s %s\n' "$t" "$(dirname "$t")/$orig"; else printf '  zfs rename %s %s\n' "$t" "${t%/*}/$orig"; fi
  done
  printf '  hs share repair   (publish %s as a Samba share, Domain Admins only)\n' "$orig"
  exit 0
fi

# nothing may write while the folders move: the same lock as parity sync, the cache mover, a rename and the delete
exec 9>"${HS_LOCK:-/run/hs-bulk.lock}"
flock -w 600 9 || { echo "Parity sync or cache mover is running, try again later." >&2; exit 1; }

done_t=()
for t in "${targets[@]}"; do
  if [ "$bulk_type" = snapraid ]; then
    if mv -n -- "$t" "$(dirname "$t")/$orig" && [ ! -e "$t" ]; then done_t+=("$t")
    else
      echo "Could not rename $t; undoing the renames already made." >&2
      for u in "${done_t[@]}"; do mv -- "$(dirname "$u")/$orig" "$u" || echo "could not undo $u: rename it back by hand" >&2; done
      echo "The restore was not completed." >&2; exit 1
    fi
  else
    "$zfs" rename "$t" "${t%/*}/$orig"
  fi
  echo "renamed $t -> $orig"
done

# the delete moved a backup switch to the kept name: move it back
if [ -f "$state/backup-off" ] && grep -qxF -- "$kept" "$state/backup-off"; then
  awk -v o="$kept" -v n="$orig" '$0 == o { print n; next } { print }' "$state/backup-off" > "$state/backup-off.new" && mv "$state/backup-off.new" "$state/backup-off" || true
fi

# publish it again (Samba share, Domain Admins only; the files go to adminuser): the same step as `hs share repair`
if ! bash "$sync"; then
  echo "The folder is back as '$orig' but publishing it failed: run  hs share repair" >&2
  exit 1
fi
echo "'$orig' is back as a $kind share. Set who may use it (it starts closed) and mount it into instances again if it was."
