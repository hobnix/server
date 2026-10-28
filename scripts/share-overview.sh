#!/usr/bin/env bash
# help: every share with size, disks, backup, upload cache and the instances that mount it; per share: who mounts it, snapshots
# help.de: alle Freigaben mit Größe, Platten, Backup, Upload-Cache und den Instanzen, die sie einhängen; je Freigabe: wer sie einhängt, Schnappschüsse
# args: [mounts <share> | history <share> | deleted]
# System command (hs sys shares overview|mounts|history), read only, tab separated (the Shares tab of the interface).
#   (no argument)    one line per share, the first six fields are those of manage-shares.sh --list:
#                      name  kind  path  cache  size_bytes  measured  backup  disks  mounted_in
#                      kind        shares | sensitive | other
#                      cache       on | off | emptying, "-" where there is none
#                      measured    when the sizes were measured (SnapRAID), empty on ZFS (always current)
#                      backup      on | off, "-" for other
#                      disks       SnapRAID: the data disks that hold the folder (data-01,data-02), ZFS: the pool name, "-" for other
#                      mounted_in  the instances that mount it, name(ro|rw), comma separated, "-" for none
#   mounts <share>   one line per instance device that mounts the share (or a folder inside it):
#                      instance  device  inside_path  ro|rw  source
#   history <share>  ZFS layout: the snapshots of the share, oldest first: name  created  auto|manual  used
#                    (SnapRAID: nothing, the backup is the history: hs share <share> restore)
#   deleted          the kept folders of deleted shares (share-delete.sh leaves <share>.deleted-<date>): name  kind  bytes  disks
# One `incus list -f json`, one backup.sh --shares, one manage-shares.sh --list, run side by side: about as fast as the slowest of the three.
# Test knobs: HS_MANAGE_SHARES, HS_BACKUP, HS_INCUS, HS_ZFS, HS_MNT_BULK, HS_BULK_TYPE_FILE, HS_BULK_POOL.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/bulkpath.sh"
mnt=${HS_MNT_BULK:-$(disks_root)}
bulk_type=$(cat "${HS_BULK_TYPE_FILE:-/etc/hs/bulk-type}" 2>/dev/null || echo zfs)

shares_list() { bash "${HS_MANAGE_SHARES:-$here/manage-shares.sh}" --list 2>/dev/null || true; }

# source<TAB>instance<TAB>device<TAB>inside<TAB>ro|rw, one line per disk device of every instance
devices() {
  ${HS_INCUS:-incus} list -f json 2>/dev/null | jq -r '.[] | .name as $n | .expanded_devices | to_entries[]
    | select(.value.type == "disk" and (.value.path // "") != "/" and (.value.pool // "") == "")
    | [ (.value.source // ""), $n, .key, .value.path, (if (.value.readonly // "false") == "true" then "ro" else "rw" end) ] | @tsv' || true
}

case "${1:-}" in
  mounts)
    share=${2:-}; [ -n "$share" ] || { echo "usage: share-overview.sh mounts <share>" >&2; exit 1; }
    path=$(shares_list | awk -F'\t' -v s="$share" '$1 == s { print $3 }')
    [ -n "$path" ] || exit 0
    devices | awk -F'\t' -v p="$path" '$1 == p || index($1, p "/") == 1 { print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $1 }'
    exit 0 ;;
  history)
    share=${2:-}; [ -n "$share" ] || { echo "usage: share-overview.sh history <share>" >&2; exit 1; }
    [ "$bulk_type" = zfs ] || exit 0
    zfs=${HS_ZFS:-zfs}; pool=${HS_BULK_POOL:-bulk}
    for kind in shares sensitive; do
      if "$zfs" list -H -o name "$pool/$kind/$share" >/dev/null 2>&1; then
        "$zfs" list -H -t snapshot -o name,creation,used -s creation -d 1 "$pool/$kind/$share" 2>/dev/null |
          awk -F'\t' '{ n = $1; sub(/^[^@]*@/, "", n); print n "\t" $2 "\t" (n ~ /^auto-/ ? "auto" : "manual") "\t" $3 }'
        break
      fi
    done
    exit 0 ;;
  deleted)
    # SnapRAID: a folder per data disk (the same name on several disks is one entry); ZFS: a dataset
    zfs=${HS_ZFS:-zfs}; pool=${HS_BULK_POOL:-bulk}
    for kind in shares sensitive; do
      if [ "$bulk_type" = snapraid ]; then
        declare -A bytes=() where=()
        for d in "$mnt"/data-*/"$kind"/*.deleted-*; do
          [ -d "$d" ] || continue
          n=${d##*/}
          bytes[$n]=$(( ${bytes[$n]:-0} + $(du -sb "$d" 2>/dev/null | cut -f1 || echo 0) ))
          disk=${d#"$mnt"/}; disk=${disk%%/*}
          where[$n]+="${where[$n]:+,}$disk"
        done
        for n in "${!bytes[@]}"; do printf '%s\t%s\t%s\t%s\n' "$n" "$kind" "${bytes[$n]}" "${where[$n]}"; done
        unset bytes where
      else
        "$zfs" list -H -p -o name,used -d 1 "$pool/$kind" 2>/dev/null |
          awk -F'\t' -v k="$kind" -v p="$pool" '{ n = $1; sub(/^.*\//, "", n); if (n ~ /\.deleted-/) print n "\t" k "\t" $2 "\t" p }'
      fi
    done | sort
    exit 0 ;;
  "") ;;
  *) echo "usage: share-overview.sh [mounts <share> | history <share> | deleted]" >&2; exit 1 ;;
esac

# the three sources are independent: they run side by side (1.8 s one after the other on the server)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
{ bash "${HS_BACKUP:-$here/backup.sh}" --shares 2>/dev/null || true; } >"$tmp/backup" &
devices >"$tmp/devices" &
shares_list >"$tmp/shares" &
wait

declare -A backup=()
while IFS=$'\t' read -r kind name flag; do
  [ "$kind" = share ] && backup[$name]=$flag
done <"$tmp/backup"

declare -A usedby=()
while IFS=$'\t' read -r source who _ _ mode; do
  [ -n "$source" ] || continue
  # a mount of a folder inside a share counts for the share: collapse /bulk/shares/media/tv to /bulk/shares/media
  key=$(awk -F/ '{ print "/" $2 "/" $3 "/" $4 }' <<<"$source")
  case "${usedby[$key]:-}" in *"$who($mode)"*) continue ;; esac
  usedby[$key]+="${usedby[$key]:+,}$who($mode)"
done <"$tmp/devices"

while IFS=$'\t' read -r name kind path cache size measured; do
  bk=- disks=- mounted=${usedby[$path]:--}
  if [ "$kind" != other ]; then
    bk=${backup[$name]:--}
    rel=${path#/bulk/}
    if [ "$bulk_type" = snapraid ]; then
      found=""
      for d in "$mnt"/data-*; do [ -d "$d/$rel" ] && found+="${found:+,}${d##*/}"; done
      disks=${found:--}
    else
      disks=${HS_BULK_POOL:-bulk}
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$kind" "$path" "${cache:--}" "${size:--}" "$measured" "$bk" "$disks" "$mounted"
done <"$tmp/shares"
