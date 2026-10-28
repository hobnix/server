#!/usr/bin/env bash
# help: (snapraid layout) mount the labelled bulk disks, merge them into /bulk, write the SnapRAID config
# help.de: (Bauart snapraid) hängt die beschrifteten bulk-Platten ein, fügt sie zu /bulk zusammen und schreibt die SnapRAID-Einstellungen
set -euo pipefail

# The array is described by filesystem labels on the disks themselves:
#   bulk-data-NN   -> /mnt/bulk/data-NN    (merged into /bulk)
#   bulk-parity-N  -> /mnt/bulk/parity-N   (SnapRAID parity)
# Nothing about the disks is stored in the NixOS config; `hs pool bulk`
# writes the labels, this script (at boot and after changes) does the rest.
. "$(dirname "$0")/lib/bulkpath.sh"
base=/mnt/bulk                 # the pool view (pool), the upload cache (cache)
dbase=$(disks_root)           # the disks: data-NN, parity-N
conf=/var/lib/snapraid/snapraid.conf
mkdir -p "$base" "$dbase" /bulk /var/lib/snapraid
if [ "$dbase" != "$base" ] && [ ! -e "$dbase/README" ]; then
  cat > "$dbase/README" <<'README'
These are the disks of the bulk array (hs pool bulk), mounted for the system. Do not copy or move files between a disk here and /bulk:
a disk in /bulk and /bulk itself show the SAME files, and a copy onto an existing path empties them.
Move folders between disks:   hs disk <member> move shares/<folder>
Empty a disk:                 hs pool bulk close <member> --drain
Work on a disk by hand:       hs disk <member> detach   (it then appears under /mnt/bulk), and hs disk <member> attach
README
fi

mapfile -t labels < <({ lsblk -nr -o LABEL; blkid -s LABEL -o value 2>/dev/null; } | grep -E '^bulk-(data-[0-9]+|parity-[0-9]+)$' | sort -u)
detdir=${HS_DETACHED_DIR:-/var/lib/hs/detached}      # hs sys disk start detach <member>: out of the merge, mounted for work by hand, until attach
recdir=${HS_RECOVER_DIR:-/var/lib/hs/recovering}   # hs sys disk start <member> recover: out of the pool, read-only, until recover-finish
want_dir() { local d; d=$(disk_dir "$1"); [ ! -e "$detdir/${1#bulk-}" ] || d=$(detached_dir "$1"); printf '%s\n' "$d"; }
for l in "${labels[@]}"; do
  dir=$(want_dir "$l")
  if [ -e "$recdir/${l#bulk-}" ]; then echo "bulk: ${l#bulk-} is out for a recovery, left alone"; continue; fi
  mkdir -p "$dir"
  mountpoint -q "$dir" || mount -o noatime "LABEL=$l" "$dir" || {
    # label seen but not mountable (disk failing, or a stale entry): go on with the rest
    echo "bulk: cannot mount $l"
    rmdir "$dir" 2>/dev/null || true
  }
done

# Remember every member ever seen. A disk that dies completely has no label
# any more; this list is how manage-pool and bulk-sync notice it is MISSING.
touch /var/lib/snapraid/members
for l in "${labels[@]}"; do
  grep -qx "$l" /var/lib/snapraid/members || echo "$l" >> /var/lib/snapraid/members
done

data=()
parity=()
for d in "$dbase"/data-*;   do mountpoint -q "$d" && data+=("$d");   done
for d in "$dbase"/parity-*; do mountpoint -q "$d" && parity+=("$d"); done
# detached disks (mounted under /mnt/bulk) stay in the SnapRAID config (data) but are not merged into /bulk (mdata)
for f in "$detdir"/*; do
  [ -f "$f" ] || continue
  dd=$(detached_dir "${f##*/}")
  if mountpoint -q "$dd" 2>/dev/null && [[ " ${data[*]-} " != *" $dd "* ]]; then data+=("$dd"); fi
done
mdata=()
for d in "${data[@]}"; do [ -e "$detdir/${d##*/}" ] || mdata+=("$d"); done

if [ ${#data[@]} -eq 0 ]; then
  echo "bulk: no data disks yet (add some with: hs pool bulk add)"
  exit 0
fi

# ── Merge the data disks ──
# /bulk is what everything uses. /mnt/bulk/pool is the same disks merged a
# second time: the layer below the upload caches (a cached share is mounted
# over its folder in /bulk, so the disks need another way in) and the place
# the cache mover writes to.
# mfs: a new file goes to the disk with the most free space; a disk with less
# free space than minfree gets no new files (override for tests).
minfree=${BULK_MINFREESPACE:-10G}
# Closed disks (hs pool bulk close): still in the merge, readable and writable for the files they
# hold, but mode NC = "no create": a new file never lands there. List: one member name per line.
closed_file=${HS_BULK_CLOSED:-/var/lib/hs/bulk-closed}
mode_of() { if grep -qx "${1##*/}" "$closed_file" 2>/dev/null; then echo NC; else echo RW; fi; }
bspec=()
for d in "${mdata[@]}"; do bspec+=("$d=$(mode_of "$d")"); done
branches=$(IFS=:; echo "${bspec[*]}")
for m in /bulk "$base/pool"; do
  mkdir -p "$m"
  if mountpoint -q "$m"; then
    # already merged: add branches that are new, without unmounting; switch the mode of the ones
    # whose closed state changed (only branches this mount still has: an emptied disk stays out)
    current=$(getfattr --only-values -n user.mergerfs.branches "$m/.mergerfs" 2>/dev/null || true)
    for d in "${mdata[@]}"; do
      [[ ":$current" == *":$d="* ]] || setfattr -n user.mergerfs.branches -v "+>$d=$(mode_of "$d")" "$m/.mergerfs"
    done
    # the disks moved: a disk that is still a branch at an OLD place is taken out now that its new place is in
    for d in "${mdata[@]}"; do
      for alt in "$base/${d##*/}" "/var/lib/hs/disks/${d##*/}"; do
        [ "$alt" != "$d" ] || continue
        [[ ":$current" == *":$alt="* ]] && setfattr -n user.mergerfs.branches -v "-$alt" "$m/.mergerfs" || true
      done
    done
    new=""
    for d in "${mdata[@]}"; do
      [[ ":$current" == *":$d="* ]] || continue
      [[ ":$current" == *":$d=$(mode_of "$d")"* ]] || new="changed"
    done
    if [ -n "$new" ]; then
      spec=""
      for d in "${mdata[@]}"; do
        [[ ":$current" == *":$d="* ]] || continue
        spec+="${spec:+:}$d=$(mode_of "$d")"
      done
      setfattr -n user.mergerfs.branches -v "$spec" "$m/.mergerfs"
    fi
  else
    name=bulk; [ "$m" = /bulk ] || name=bulk-pool
    mergerfs -o "cache.files=off,dropcacheonclose=true,category.create=mfs,moveonenospc=true,minfreespace=$minfree,allow_other,fsname=$name" \
      "$branches" "$m"
  fi
done

mkdir -p /bulk/shares /bulk/sensitive
chown adminuser:users /bulk/shares
chmod 2775 /bulk/shares

# ── Upload caches (hs share <share> cache) ──
# A share that has a folder on the SSD cache gets a small merge of its own
# mounted over its folder in /bulk: the cache folder first, the disks below.
# "ff" puts new files on the first layer that has room, so they land on the
# SSDs and fall through to the disks when the cache is full. `hs cache-mover`
# moves them down later. A marker file <share>.off means "being emptied":
# the cache layer then takes no new files.
cache=$base/cache
cminfree=${HS_CACHE_MINFREE:-20G}   # below this much free cache, uploads go straight to the disks
if ! mountpoint -q "$cache" && zfs list -H fast/hs-cache >/dev/null 2>&1; then
  zfs mount fast/hs-cache 2>/dev/null || true
fi
cached=0
if mountpoint -q "$cache"; then
  for c in "$cache"/shares/*/ "$cache"/sensitive/*/; do
    [ -d "$c" ] || continue
    rel=${c#"$cache"/}; rel=${rel%/}
    [ -d "$base/pool/$rel" ] || continue                 # the share itself is gone
    # same owner and rights as the share, or uploads would be refused
    chown --reference="$base/pool/$rel" "$cache/$rel"
    chmod "$(stat -c %a "$base/pool/$rel")" "$cache/$rel"
    mode=RW; [ ! -e "$cache/$rel.off" ] || mode=NC
    # 1M: how full the disks may get is decided by the merge below, not here
    spec="$cache/$rel=$mode,$cminfree:$base/pool/$rel=RW,1M"
    if mountpoint -q "/bulk/$rel"; then
      setfattr -n user.mergerfs.branches -v "$spec" "/bulk/$rel/.mergerfs"
    else
      mergerfs -o "cache.files=off,dropcacheonclose=true,category.create=ff,moveonenospc=true,allow_other,fsname=cache-${rel##*/}" \
        "$spec" "/bulk/$rel"
    fi
    cached=$((cached + 1))
  done
fi

# ── Old mount points of the disks (they moved: ): let go of them once no merge uses them any more ──
# (lazy: an open file keeps its mount until it is closed; the disk itself stays mounted at its new place)
for l in "${labels[@]}"; do
  n=${l#bulk-}; dir=$(want_dir "$l")
  [ ! -e "$recdir/$n" ] || continue
  for alt in "$base/$n" "/var/lib/hs/disks/$n"; do
    [ "$alt" != "$dir" ] || continue
    mountpoint -q "$alt" 2>/dev/null || continue
    mountpoint -q "$dir" 2>/dev/null || continue            # only when the new place is there
    still=""
    for m in /bulk "$base/pool"; do
      mountpoint -q "$m" 2>/dev/null || continue
      [[ ":$(getfattr --only-values -n user.mergerfs.branches "$m/.mergerfs" 2>/dev/null || true)" == *":$alt="* ]] && still=yes
    done
    if [ -n "$still" ]; then echo "bulk: $n is still a branch of a merge at $alt, left mounted there"; continue; fi
    echo "bulk: $n moved from $alt to $dir"
    umount -l "$alt" 2>/dev/null || true
    rmdir "$alt" 2>/dev/null || true
  done
done

# ── SnapRAID config, regenerated from what is mounted ──
{
  n=0
  for p in "${parity[@]}"; do
    n=$((n + 1))
    if [ $n -eq 1 ]; then echo "parity $p/snapraid.parity"; else echo "$n-parity $p/snapraid.$n-parity"; fi
  done
  echo "content /var/lib/snapraid/snapraid.content"
  for d in "${data[@]}"; do echo "content $d/snapraid.content"; done
  for d in "${data[@]}"; do echo "data ${d##*/} $d"; done
  # disks taken out by hs pool bulk remove: kept, pointing at an empty folder, until the
  # next sync has dropped them (bulk-sync.sh uses -E and then forgets the record)
  while read -r r; do
    [ -n "$r" ] || continue
    case " ${data[*]##*/} " in *" $r "*) continue ;; esac
    mkdir -p "/var/lib/hs/removed/$r"
    echo "data $r /var/lib/hs/removed/$r"
  done < <(cat /var/lib/hs/removals 2>/dev/null || true)
  echo "exclude lost+found/"
  echo "exclude *.unrecoverable"
  # SABnzbd/Radarr/Sonarr unpack here and the file grows for hours: SnapRAID would report "Unexpected size change"
  # (soft errors, exit 1, failure alarm). The finished file is hard-linked into the library and synced from there.
  echo "exclude _UNPACK_*/"
} > "$conf"

echo "bulk: ${#data[@]} data disk(s), ${#parity[@]} parity disk(s)$([ "$cached" -eq 0 ] || echo ", $cached share(s) with upload cache")"
[ ${#parity[@]} -gt 0 ] || echo "bulk: NO PARITY DISK, the data is not protected"
