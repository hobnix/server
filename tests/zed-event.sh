#!/usr/bin/env bash
# scripts/zed-event.sh (hs sys zed event): a ZFS fault from ZED is written to the event log, harmless events are not. No root, no ZFS.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test HS_EVENT_NOROOT=1 HS_STATE_NO_COLLECT=1
wp() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
mkdir -p "$WORK/state"
export HS_STATE_DB; HS_STATE_DB=$(wp "$WORK/state")/state.db
zed() { env "$@" bash "$SCRIPTS/zed-event.sh"; }
ev() { python3 "$SCRIPTS/state-db.py" event-list 20; }

zed ZEVENT_CLASS=resource.fs.zfs.statechange ZEVENT_POOL=bulk ZEVENT_VDEV_STATE_STR=ONLINE
zed ZEVENT_CLASS=sysevent.fs.zfs.history_event ZEVENT_POOL=bulk
check_eq "harmless events write nothing" "" "$(ev)"
zed ZEVENT_CLASS=resource.fs.zfs.statechange ZEVENT_POOL=bulk ZEVENT_VDEV_STATE_STR=DEGRADED ZEVENT_VDEV_PATH=/dev/sdb1
zed ZEVENT_CLASS=resource.fs.zfs.statechange ZEVENT_POOL=bulk ZEVENT_VDEV_STATE_STR=FAULTED
zed ZEVENT_CLASS=ereport.fs.zfs.io_failure ZEVENT_POOL=fast
check_eq "three faults" "3" "$(ev | wc -l | tr -d ' ')"
check_eq "kinds and levels" "pool-fault warn,pool-fault error,pool-fault error" \
  "$(ev | awk -F'\t' '{printf "%s%s %s", (NR > 1 ? "," : ""), $4, $6}')"
check "kind is registered" grep -q '^storage.pool-fault	' "$SCRIPTS/lib/event-kinds.tsv"
finish
