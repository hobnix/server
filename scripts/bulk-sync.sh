#!/usr/bin/env bash
# help: (snapraid layout) update the parity now, or check part of the data with --scrub
# help.de: (Bauart snapraid) aktualisiert die Parität jetzt, oder prüft mit --scrub einen Teil der Daten
# args: [--force] [--scrub] [--no-mover]
set -euo pipefail

here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/bulkpath.sh"
conf=${HS_SNAPRAID_CONF:-/var/lib/snapraid/snapraid.conf}
# A sync makes deletions permanent. Refuse when unusually many files vanished
# since the last sync (mistake, malware); --force runs it anyway.
max_removed=100

force=false
scrub=false
mover=true
while [ $# -gt 0 ]; do
  case "$1" in
    --force) force=true; shift ;;
    --scrub) scrub=true; shift ;;
    --no-mover) mover=false; shift ;;
    *) say "usage: hs pool bulk sync [--force] [--scrub] [--no-mover]"; exit 1 ;;
  esac
done

if [ "$(cat "${HS_BULK_TYPE_FILE:-/etc/hs/bulk-type}" 2>/dev/null || echo zfs)" != snapraid ]; then
  ok "This server uses ZFS for /bulk: parity is always current, nothing to sync."
  exit 0
fi
grep -q '^parity ' "$conf" 2>/dev/null || fail "No parity disk yet (hs pool bulk add --role parity)."

# One sync, scrub, mover run or pool change at a time (the mover calls this script with the lock
# held). While `hs pool bulk` replaces or removes a disk, a timer run is skipped, not failed.
if [ -z "${HS_BULK_LOCKED:-}" ]; then
  . "$here/lib/bulklock.sh"
  bulk_lock_job 1800
  export HS_BULK_LOCKED=1
fi

# A disk that was detached by hand is out of /bulk on purpose: no sync until it is attached again (the health check says so after 2 hours).
for f in "${HS_DETACHED_DIR:-/var/lib/hs/detached}"/*; do
  [ -f "$f" ] || continue
  warn "$(t '%s is detached. Not syncing until it is attached again (hs sys disk start attach %s).' "${f##*/}" "${f##*/}")"
  exit 0
done

# A disk that is out of the pool for a recovery (hs sys disk start <member> recover) is away on purpose too: skipped, not failed.
for f in "${HS_RECOVER_DIR:-/var/lib/hs/recovering}"/*; do
  [ -f "$f" ] || continue
  warn "$(t '%s is out of the pool for a recovery. Not syncing until it is given back (hs sys disk start %s recover-finish).' "${f##*/}" "${f##*/}")"
  exit 0
done

# A member that isn't mounted would look like "all its files were deleted".
# Syncing then would destroy the parity that can still restore it.
while read -r l; do
  [ -n "$l" ] || continue
  mountpoint -q "$(disk_dir "$l")" || {
    warn "$(t '%s is not mounted (disk failed or missing). Not syncing.' "${l#bulk-}")"
    note "Replace it with: hs pool bulk replace"
    exit 1
  }
done < <(cat /var/lib/snapraid/members 2>/dev/null || true)

if $scrub; then
  # 12% of the array, oldest-checked first: everything is re-read about every 2 months
  steps 1
  step "Scrub (a part of the data, the oldest checked first)"
  if SPIN_STREAM=1 SPIN_TAIL=3 spin "Checking the data (the lines below show where it is)" snapraid -c "$conf" scrub -p 12 -o 0; then
    tail -n 14 <<<"$spin_out" | trail
    # health-check.sh complains when no scrub has finished for two weeks
    mkdir -p "$(dirname "${HS_SCRUB_STATE:-/var/lib/hs/scrub.state}")" 2>/dev/null || true
    date +%s > "${HS_SCRUB_STATE:-/var/lib/hs/scrub.state}" 2>/dev/null || true
    ok "The check is done"
    exit 0
  fi
  fail "The check did not finish (see above)."
fi

# Uploads waiting in the SSD cache go to the disks first, so this sync covers them.
# A mover problem must not stop the parity update.
if $mover; then
  HS_FROM_SYNC=1 bash "$here/cache-mover.sh" || warn "The cache mover reported a problem (see above), syncing anyway."
fi

# disks taken out earlier (hs pool bulk remove) are dropped by this sync (-E: empty is intended)
removals=()
while read -r r; do [ -z "$r" ] || removals+=("$r"); done < <(cat /var/lib/hs/removals 2>/dev/null || true)
sync_args=()
[ ${#removals[@]} -eq 0 ] || { sync_args=(-E); force=true; note "$(t 'Dropping the removed disk(s) from the parity: %s (files that moved count as removed here)' "${removals[*]}")"; }

diff=$(snapraid -c "$conf" diff 2>&1) || true
removed=$(awk '$2 == "removed" { print $1 }' <<<"$diff" | tail -n1)
removed=${removed:-0}
if [ "$removed" -gt "$max_removed" ] && ! $force; then
  warn "$(t '%s files were removed since the last sync (limit %s).' "$removed" "$max_removed")"
  note "$(t 'Not syncing, so they can still be restored: snapraid -c %s fix -m' "$conf")"
  note "If the deletions are intended: hs pool bulk sync --force"
  exit 1
fi

# a sync can run for hours: spin shows SnapRAID's newest progress lines (percent, MB, speed, time left) while it
# runs, in a job or a log one line a minute; SnapRAID's own summary is printed afterwards
steps 1
step "Parity sync"
run_sync() { SPIN_STREAM=1 SPIN_TAIL=3 spin "Updating the parity (the lines below show where it is)" snapraid -c "$conf" sync "$@"; }
show_sync() { tail -n "${1:-14}" <<<"$spin_out" | trail; }
ok_sync=false
flags=()
for attempt in 1 2 3; do
  if run_sync ${flags[@]+"${flags[@]}"} "${sync_args[@]+"${sync_args[@]}"}"; then ok_sync=true; break; fi
  if grep -q "Unexpected data modification of a file without parity" <<<"$spin_out" && [[ " ${flags[*]-} " != *" --force-nocopy "* ]]; then
    # SnapRAID guessed that a file is a copy of another one (same name, size, timestamp: files that were
    # moved between disks, small marker files like Immich's .immich) and the content differed. No data is
    # at risk: the guess is switched off and the file gets its own parity.
    note "SnapRAID mistook a file for a copy of another one. Syncing again without that guess (--force-nocopy)."
    flags+=(--force-nocopy)
  elif grep -q "Too many disks have changed UUIDs" <<<"$spin_out" && [[ " ${flags[*]-} " != *" --force-uuid "* ]] && [ ${#removals[@]} -gt 0 ]; then
    # disks were reformatted (hs pool convert, a new parity disk): their UUIDs changed on purpose. SnapRAID's check is
    # there for wrong mount points; every member was found mounted above and the removals list says why they changed.
    note "$(t 'Disks were reformatted on purpose (%s): their UUIDs changed. Syncing again with --force-uuid.' "${removals[*]}")"
    flags+=(--force-uuid)
  else
    break
  fi
done
show_sync $($ok_sync && echo 14 || echo 40)
if $ok_sync; then
  ok "Parity is up to date"
  if [ ${#removals[@]} -gt 0 ]; then
    rm -f /var/lib/hs/removals
    for r in "${removals[@]}"; do rmdir "/var/lib/hs/removed/$r" 2>/dev/null || true; done
    bash "$here/bulk-mount.sh" >/dev/null 2>&1 || true   # config without the removed disks
  fi
else
  fail "The sync did not finish (see above)."
fi
