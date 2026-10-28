#!/usr/bin/env bash
# help: what the pools are doing right now: the bulk lock, the pause of the health check, the last scrub and the last parity sync (read only)
# help.de: was die Pools gerade tun: die Bulk-Sperre, die Pause des Health-Checks, der letzte Scrub und der letzte Paritäts-Sync (nur lesend)
# args: [bulk|fast]
# System command (hs sys pool state [<pool>]), read only, tab separated, plain, never asks and never takes the lock. Lines in this order;
# a new column is only ever appended:
#   lock    <free|busy|pool-change|unknown>  <text>      /run/hs-bulk.lock: busy = a parity sync, scrub, cache mover, share rename or
#                                                         disk move holds it; pool-change = hs pool bulk replace/remove (marker /run/hs-bulk.admin)
#   paused  <yes|no>                         <text>      the health check paused sync, scrub and cache mover (marker /run/hs-bulk.paused)
#   scrub   <pool>  <running|ok|errors|never|unknown>  <text>   ZFS: the "scan:" line of zpool status; SnapRAID (bulk): /var/lib/hs/scrub.state
#   sync    bulk    <running|ok|never|unknown>         <text>   SnapRAID only: the parity sync (the time of snapraid.content)
# Test knobs: HS_LOCK, HS_LOCK_ADMIN, HS_BULK_PAUSE, HS_BULK_TYPE_FILE, HS_ZPOOL, HS_SYSTEMCTL, HS_SCRUB_STATE, HS_SNAPRAID_CONTENT, HS_NOW.
set -uo pipefail
want=${1:-}
case "$want" in ""|bulk|fast) ;; *) echo "usage: pool-state.sh [bulk|fast]" >&2; exit 1 ;; esac

lock=${HS_LOCK:-/run/hs-bulk.lock}
admin=${HS_LOCK_ADMIN:-/run/hs-bulk.admin}
pause=${HS_BULK_PAUSE:-/run/hs-bulk.paused}
zpool=${HS_ZPOOL:-zpool}
systemctl=${HS_SYSTEMCTL:-systemctl}
scrub_state=${HS_SCRUB_STATE:-/var/lib/hs/scrub.state}
content=${HS_SNAPRAID_CONTENT:-/var/lib/snapraid/snapraid.content}
bulk_type=$(cat "${HS_BULK_TYPE_FILE:-/etc/hs/bulk-type}" 2>/dev/null || echo zfs)
now=${HS_NOW:-$(date +%s)}

when() { date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$1"; }
active() { "$systemctl" is-active --quiet "$1" 2>/dev/null; }

# ── the lock: tried without waiting and let go at once, so nothing is blocked by looking
if [ -e "$admin" ]; then
  printf 'lock\tpool-change\ta pool change (hs pool bulk) is running and owns the lock\n'
elif [ ! -e "$lock" ]; then
  printf 'lock\tfree\tnobody has used the lock since the start\n'
elif ! command -v flock >/dev/null 2>&1; then
  printf 'lock\tunknown\tflock is not installed here\n'
else
  if exec 8<"$lock" 2>/dev/null; then
    if flock -n 8; then printf 'lock\tfree\tnothing is running that changes the pool\n'
    else printf 'lock\tbusy\ta parity sync, scrub, cache mover, share rename or disk move holds the lock\n'; fi
    exec 8<&-
  else
    printf 'lock\tunknown\tthe lock file cannot be read\n'
  fi
fi
if [ -e "$pause" ]; then printf 'paused\tyes\tthe health check paused sync, scrub and cache mover (hs health resume lifts it)\n'
else printf 'paused\tno\t-\n'; fi

zfs_scrub() {   # zfs_scrub <pool>
  local p=$1 scan
  if ! command -v "$zpool" >/dev/null 2>&1 || ! "$zpool" list -H "$p" >/dev/null 2>&1; then
    printf 'scrub\t%s\tunknown\tthe pool is not there\n' "$p"; return
  fi
  # "scrub repaired 0B in 00:10:02 with 0 errors on Sun Oct  4 00:24:01 2026"
  scan=$("$zpool" status "$p" 2>/dev/null | sed -n 's/^ *scan: *//p' | head -n1 || true)
  if [[ "$scan" =~ with\ ([0-9]+)\ errors\ on\ (.+)$ ]]; then
    if [ "${BASH_REMATCH[1]}" -eq 0 ]; then printf 'scrub\t%s\tok\tfinished %s, no errors\n' "$p" "${BASH_REMATCH[2]}"
    else printf 'scrub\t%s\terrors\tfinished %s with %s error(s)\n' "$p" "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}"; fi
  elif [[ "$scan" == *"scrub in progress"* ]]; then
    printf 'scrub\t%s\trunning\t%s\n' "$p" "$(sed 's/^scrub in progress since //' <<<"$scan")"
  else
    printf 'scrub\t%s\tnever\tno scrub has finished yet\n' "$p"
  fi
}

snap_state() {
  local t
  if active hs-bulk-scrub.service; then printf 'scrub\tbulk\trunning\tthe check of the data is running\n'
  elif [ -s "$scrub_state" ] && t=$(cat "$scrub_state") && [[ "$t" =~ ^[0-9]+$ ]]; then
    printf 'scrub\tbulk\tok\tfinished %s (%s days ago)\n' "$(when "$t")" "$(( (now - t) / 86400 ))"
  else printf 'scrub\tbulk\tnever\tno scrub has finished yet\n'; fi
  if active hs-bulk-sync.service; then printf 'sync\tbulk\trunning\tthe parity sync is running\n'
  elif [ -e "$content" ]; then
    t=$(stat -c %Y "$content" 2>/dev/null || true)
    if [[ "$t" =~ ^[0-9]+$ ]]; then printf 'sync\tbulk\tok\tlast sync %s (%s days ago)\n' "$(when "$t")" "$(( (now - t) / 86400 ))"
    else printf 'sync\tbulk\tunknown\tthe time of the parity file cannot be read\n'; fi
  else printf 'sync\tbulk\tnever\tno parity sync has finished yet\n'; fi
}

for p in bulk fast; do
  [ -z "$want" ] || [ "$want" = "$p" ] || continue
  if [ "$p" = bulk ] && [ "$bulk_type" = snapraid ]; then snap_state; else zfs_scrub "$p"; fi
done
exit 0
