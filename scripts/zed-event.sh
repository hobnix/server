#!/usr/bin/env bash
# help: a ZFS event from ZED (the zedlet calls this): a pool or vdev fault goes to the event log and the disks group is refreshed
# help.de: ein ZFS-Ereignis von ZED (das Zedlet ruft das auf): ein Pool- oder Laufwerksfehler kommt ins Ereignisprotokoll, die Disks-Gruppe wird aufgefrischt
# args: (the event comes in the ZEVENT_* variables that ZED sets)
# Called by the zedlet /etc/zfs/zed.d/all-hobnix.sh (capabilities/storage/module.nix) for every ZFS event. Only a fault is written:
# a vdev that changed to FAULTED, DEGRADED, UNAVAIL, REMOVED or OFFLINE-by-error (class resource.fs.zfs.statechange), an io_failure or a
# data error (ereport.fs.zfs.io_failure, ereport.fs.zfs.data). It writes the event storage.pool-fault (subject: the pool) and refreshes
# the live data of the disks group so Health shows it at once, then starts hs-health-check without blocking so the push is not 15 minutes late. It never touches a pool or a disk and
# never fails (ZED must not stall). Test knobs: ZEVENT_CLASS, ZEVENT_POOL, ZEVENT_VDEV_PATH, ZEVENT_VDEV_STATE_STR, HS_EVENT_NOROOT, HS_STATE_DB.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/event.sh"
class=${ZEVENT_CLASS:-}
pool=${ZEVENT_POOL:--}
vdev=${ZEVENT_VDEV_PATH:-}
state=${ZEVENT_VDEV_STATE_STR:-}

case "$class" in
  resource.fs.zfs.statechange)
    case "$state" in
      FAULTED|DEGRADED|UNAVAIL|REMOVED) what="a device is $state" ;;
      *) exit 0 ;;
    esac ;;
  ereport.fs.zfs.io_failure) what="the pool stopped on an I/O failure" ;;
  ereport.fs.zfs.data) what="a data error" ;;
  *) exit 0 ;;
esac
[ -n "$vdev" ] && what="$what ($vdev)"

level=warn
case "$state$class" in *FAULTED*|*UNAVAIL*|*io_failure*) level=error ;; esac
event_emit storage.pool-fault "$pool" "ZFS pool $pool: $what" --level "$level" \
  --payload "{\"class\":\"$class\",\"vdev\":\"${vdev//\"/}\",\"state\":\"$state\"}"
bash "$here/live.sh" refresh monitor-disks disk-inventory >/dev/null 2>&1 || true
# The push: start the health check now (it dedupes, honours acks and uses every channel, so no second message comes 15 minutes later).
# --no-block: ZED does not wait; a failure here is ignored.
if command -v systemctl >/dev/null 2>&1; then
  systemctl start --no-block hs-health-check.service >/dev/null 2>&1 || true
fi
exit 0
