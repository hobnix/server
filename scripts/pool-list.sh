#!/usr/bin/env bash
# help: the pools of this server with their state (read only)
# help.de: die Pools dieses Servers mit ihrem Zustand (nur lesend)
# args:
# System command (hs sys pool list), read only, tab separated, plain, never asks, never takes a lock, never translated. One line per pool,
# sorted by name; a new column is only ever appended; no pool = no output, exit 0:
#   <name>  <role: data|apps>  <kind: zfs|snapraid>  <state: online|degraded|missing|locked|unmounted>
# state: locked = encrypted storage not unlocked yet; missing = zfs pool unknown to zpool; degraded = zfs health is not ONLINE;
#        unmounted = the pool root is not a mount point; else online.
# Test knobs: HS_LOCKED_MARKER, HS_ZPOOL, and those of lib/pools.sh (HS_MACHINE_FILE, HS_BULK_TYPE_FILE, HS_POOLS_ROOT, HS_MOUNTPOINT).
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/pools.sh
. "$here/lib/pools.sh"

locked=${HS_LOCKED_MARKER:-/run/hs/storage-locked}
zpool=${HS_ZPOOL:-zpool}

pool_state() {   # pool_state <name> <kind>
  local health
  if [ -e "$locked" ]; then printf 'locked\n'; return; fi
  if [ "$2" = zfs ]; then
    if ! health=$("$zpool" list -H -o health "$1" 2>/dev/null); then printf 'missing\n'; return; fi
    health=${health%%$'\n'*}
    if [ "$health" != ONLINE ]; then printf 'degraded\n'; return; fi
  fi
  if pool_mounted "$1" 2>/dev/null; then printf 'online\n'; else printf 'unmounted\n'; fi
}

while IFS=$'\t' read -r name role kind; do
  [ -n "$name" ] || continue
  printf '%s\t%s\t%s\t%s\n' "$name" "$role" "$kind" "$(pool_state "$name" "$kind")"
done < <(pools_rows)
exit 0
