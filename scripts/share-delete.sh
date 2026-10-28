#!/usr/bin/env bash
# help: take a share away without destroying its files: detach it from the instances, rename the folder to <share>.deleted-<date>, remove the Samba share
# help.de: eine Freigabe wegnehmen, ohne ihre Dateien zu zerstören: aus den Instanzen lösen, den Ordner in <Freigabe>.deleted-<Datum> umbenennen, die Samba-Freigabe entfernen
# args: <share> [--dry-run]
# System-layer command behind `hs sys shares start <share> delete` (share-change.sh). Nothing is erased: the folder stays on its disks
# (a dataset on ZFS) under the new name, which `hs share repair` never publishes again. Order: (1) the rename is checked with its own
# dry run (refused while the upload cache is on, a taken name ...), so a refusal changes nothing; (2) the instances that mount the share
# or a folder in it lose that device; (3) manage-shares.sh --rename (the folder on every disk, under the bulk lock); (4) the Samba share
# of the new name is removed. --dry-run prints these steps as indented commands. Test knobs: HS_MANAGE_SHARES, HS_INCUS, HS_NET, HS_DELETE_STAMP.
set -euo pipefail
here=$(dirname "$0")
manage=${HS_MANAGE_SHARES:-$here/manage-shares.sh}
incus=${HS_INCUS:-incus}
net=${HS_NET:-net}

share=${1:-}; dry=false
[ "${2:-}" != --dry-run ] || dry=true
[[ "$share" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "usage: share-delete.sh <share> [--dry-run]" >&2; exit 1; }
stamp=${HS_DELETE_STAMP:-$(date +%Y%m%d)}
new="$share.deleted-$stamp"

path=$("$net" conf getparm "$share" path 2>/dev/null || true)
case "$path" in
  /bulk/shares/*|/bulk/sensitive/*) ;;
  *) echo "'$share' is not a folder under /bulk/shares or /bulk/sensitive: it can't be deleted here." >&2; exit 1 ;;
esac

# (1) the rename decides first: nothing has changed when it refuses
rc=0; out=$(bash "$manage" "$share" --rename "$new" --dry-run </dev/null 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then printf '%s\n' "${out:-the rename of '$share' was refused without a message}" >&2; exit 1; fi

# (2) the devices of instances that mount the share or a folder inside it: instance<TAB>device
mapfile -t mounts < <("$incus" list -f json 2>/dev/null | jq -r --arg p "$path" '.[] | .name as $n | .devices // {} | to_entries[]
  | select(.value.type == "disk" and ((.value.source // "") == $p or ((.value.source // "") | startswith($p + "/"))))
  | [ $n, .key ] | @tsv' || true)

if $dry; then
  for m in "${mounts[@]}"; do
    [ -n "$m" ] || continue
    printf '  incus config device remove %s %s\n' "${m%%$'\t'*}" "${m#*$'\t'}"
  done
  printf '  hs share %s rename %s\n' "$share" "$new"
  printf '  net conf delshare %s\n' "$new"
  exit 0
fi

removed=()
for m in "${mounts[@]}"; do
  [ -n "$m" ] || continue
  ct=${m%%$'\t'*}; dev=${m#*$'\t'}
  "$incus" config device remove "$ct" "$dev"
  removed+=("$ct:$dev")
  echo "detached $dev from $ct"
done
if ! bash "$manage" "$share" --rename "$new"; then
  echo "The rename failed. The share is still published under its old name." >&2
  [ ${#removed[@]} -eq 0 ] || echo "These mounts were already detached: ${removed[*]} (add them again with: hs ct <instance> storage add)" >&2
  exit 1
fi
"$net" conf delshare "$new"
echo "'$share' is deleted. Its files are in $(dirname "$path")/$new until you remove that folder by hand."
