#!/usr/bin/env bash
# help: the storage pools of Incus with the free space of each, to choose where a new instance's disk lives
# help.de: die Speicherpools von Incus mit dem freien Platz je Pool, um zu wählen, wo die Platte einer neuen Instanz liegt
# args: (none)
# System command (hs sys ct pools): one line per Incus storage pool, tab separated, nothing else:
#   name, driver, kind, free bytes, total bytes, source
# kind: fast (the default pool, the SSD), bulk (a pool whose source folder is under /bulk or the disks root: the data disks), other.
# free and total are `-` when Incus cannot say (a pool that is not available); source is `-` for a pool without a source.
# Test knobs: HS_INCUS (stand-in for incus). Needs jq.
set -uo pipefail
incus=${HS_INCUS:-incus}
command -v jq >/dev/null 2>&1 || exit 0
list=$("$incus" query '/1.0/storage-pools?recursion=1' 2>/dev/null) || exit 0
bulk_root=${HS_MNT_BULK:-/bulk}
while IFS=$'\t' read -r name driver source; do
  [ -n "$name" ] || continue
  res=$("$incus" query "/1.0/storage-pools/$name/resources" 2>/dev/null) || res=
  total=$(jq -r '.space.total // empty' <<<"$res" 2>/dev/null) || total=
  used=$(jq -r '.space.used // empty' <<<"$res" 2>/dev/null) || used=
  free=-; [ -z "$total" ] || [ -z "$used" ] || free=$((total - used))
  kind=other
  case "$source" in "$bulk_root"/*|"${HS_DISKS_ROOT:-/mnt/bulk}"/*|/var/lib/hs/disks/*) kind=bulk ;; esac
  [ "$name" != default ] || kind=fast
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$driver" "$kind" "$free" "${total:--}" "${source:--}"
done < <(jq -r '.[] | [.name, .driver, (.config.source // "-")] | @tsv' <<<"$list" 2>/dev/null)
