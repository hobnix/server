#!/usr/bin/env bash
# help: (snapraid layout) move uploaded files from the SSD cache to the data disks
# help.de: (Bauart snapraid) verschiebt hochgeladene Dateien vom SSD-Cache auf die Datenplatten
# args: [share] [--now] [--if-full] [--no-sync]
set -euo pipefail

# Runs before every parity sync (hs pool bulk sync calls it), and every 15 minutes
# with --if-full so a filling cache is emptied early. A file is moved only when
# nothing has touched it for a while and no program has it open, so an upload
# in progress is never cut in half.
here=$(dirname "$0")
. "$here/lib/ui.sh"
cache=/mnt/bulk/cache
pool=/mnt/bulk/pool
age=${HS_CACHE_AGE:-10}    # minutes without change before a file is moved
full=80                    # --if-full: act from this fill level (percent)

usage() {
  say "usage: hs cache-mover [share] [--now] [--if-full] [--no-sync]"
  printf '%s\n' "$(t '  --now       also move files changed within the last %s minutes (still not open ones)' "$age")"
  printf '%s\n' "$(t '  --if-full   do nothing unless the cache is at least %s %% full' "$full")"
  say "  --no-sync   don't update the parity afterwards"
  exit 1
}

only=""; now=false; if_full=false; sync=true
while [ $# -gt 0 ]; do
  case "$1" in
    --now)     now=true; shift ;;
    --if-full) if_full=true; shift ;;
    --no-sync) sync=false; shift ;;
    -*)        usage ;;
    *)         [ -z "$only" ] || usage; only="$1"; shift ;;
  esac
done

mountpoint -q "$cache" || exit 0     # no cache on this server
mountpoint -q "$pool" || fail "$(t 'The data disks are not mounted at %s (hs pool bulk).' "$pool")"

# One run at a time, and never while a parity sync is reading the disks.
# bulk-sync.sh holds the lock itself when it calls this script.
if [ -z "${HS_BULK_LOCKED:-}" ]; then
  . "$here/lib/bulklock.sh"
  bulk_paused_exit
  exec 9>/run/hs-bulk.lock
  flock -n 9 || { note "A sync or another mover run is in progress, skipping."; exit 0; }
  export HS_BULK_LOCKED=1
fi

if $if_full; then
  pct=$(df --output=pcent "$cache" | tail -n1 | tr -dc '0-9')
  [ "${pct:-0}" -ge "$full" ] || exit 0
  step "Moving the cache to the disks"
  note "$(t 'The cache is %s %% full, moving files to the disks.' "$pct")"
fi

moved_total=0
problems=0
for c in "$cache"/shares/*/ "$cache"/sensitive/*/; do
  [ -d "$c" ] || continue
  rel=${c#"$cache"/}; rel=${rel%/}
  [ -z "$only" ] || [ "${rel##*/}" = "$only" ] || continue
  src="$cache/$rel"; dst="$pool/$rel"
  [ -d "$dst" ] || { warn "$(t '%s: its folder on the disks is gone, leaving the cache alone' "${rel##*/}")"; problems=1; continue; }

  # what any program has open right now (the merge layer keeps a handle for
  # every file a client has open), as paths relative to the cache folder
  open=$(find /proc/[0-9]*/fd -lname "$src/*" -printf '%l\n' 2>/dev/null |
    sed -e 's/ (deleted)$//' -e "s|^$src/|./|" | sort -u || true)

  list=$(mktemp)
  agetest=(); $now || agetest=(-mmin "+$age" -cmin "+$age")
  (
    cd "$src"
    find . -mindepth 1 -type d -print0                              # folders, so they keep owner and rights
    find . \( -type f -o -type l \) "${agetest[@]}" -print0 |
      { if [ -n "$open" ]; then grep -zvxFf <(printf '%s\n' "$open") || true; else cat; fi; }
  ) > "$list"

  before=$(find "$src" \( -type f -o -type l \) | wc -l)
  if [ "$before" -gt 0 ]; then
    # -d with a file list: create the listed folders, don't descend on our own
    rsync -aHAX -d --from0 --files-from="$list" --remove-source-files $([ -t 1 ] && echo --info=progress2) "$src/" "$dst/" || {
      warn "$(t '%s: some files could not be moved (see above)' "${rel##*/}")"; problems=1; }
    find "$src" -mindepth 1 -type d -empty -delete
  fi
  rm -f "$list"
  after=$(find "$src" \( -type f -o -type l \) | wc -l)
  moved=$((before - after))
  moved_total=$((moved_total + moved))
  if [ "$before" -ne 0 ]; then
    if [ "$after" -eq 0 ]; then ok "$(t '%s: moved %s file(s), %s still in the cache' "${rel##*/}" "$moved" "$after")"
    else note "$(t '%s: moved %s file(s), %s still in the cache (open, or changed in the last %s minutes)' "${rel##*/}" "$moved" "$after" "$age")"; fi
  fi

  # a share that was switched off is finished once its cache folder is empty
  if [ -e "$src.off" ] && [ "$after" -eq 0 ]; then
    umount -l "/bulk/$rel" 2>/dev/null || true
    rmdir "$src" 2>/dev/null || true
    rm -f "$src.off"
    ok "$(t '%s: cache switched off' "${rel##*/}")"
  fi
done

# Files that just reached the disks have no parity yet: update it right away,
# unless the caller does that itself.
if [ "$moved_total" -gt 0 ] && $sync && [ -z "${HS_FROM_SYNC:-}" ]; then
  bash "$here/bulk-sync.sh" --no-mover
fi
exit "$problems"
