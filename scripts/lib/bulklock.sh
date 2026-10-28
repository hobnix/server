# shellcheck shell=bash
# The lock of everything that touches the parity or the disk layout of /bulk (snapraid layout):
# parity sync, cache mover, share rename, and pool changes (hs pool bulk replace/remove).
# Sourced, not run:   . "$(dirname "$0")/lib/bulklock.sh"
#
#   bulk_lock_job [seconds]    a timer or normal job: take the lock. A pool change owns it for
#                              hours: then skip quietly (exit 0, no failure message). Otherwise
#                              wait for the other holder (the cache mover), then give up (exit 1).
#   bulk_lock_admin [seconds]  a pool change: take the lock for the rest of the run and leave a
#                              marker, so the jobs above skip instead of failing.
#   bulk_paused_exit           the health check paused the sync, scrub and cache mover (setting
#                              autoMitigate): skip quietly (exit 0) while the marker exists. A pool change is never paused
#                              (it is the cure); HS_IGNORE_PAUSE=1 runs a job anyway. The marker is in /run, so a reboot lifts it
#                              (the health check sets it again when the cause is still there). Lift: hs health resume.
# Test knobs: HS_LOCK, HS_LOCK_ADMIN, HS_BULK_PAUSE.

bulk_lock=${HS_LOCK:-/run/hs-bulk.lock}
bulk_admin=${HS_LOCK_ADMIN:-/run/hs-bulk.admin}
bulk_pause=${HS_BULK_PAUSE:-/run/hs-bulk.paused}

bulk_paused_exit() {
  if [ -e "$bulk_pause" ] && [ -z "${HS_IGNORE_PAUSE:-}" ]; then
    echo "Paused by the health check because of a failing disk or pool (see: hs health). Nothing is done this time; lift the pause with: hs health resume"
    exit 0
  fi
}

bulk_lock_job() {
  bulk_paused_exit
  exec 9>"$bulk_lock"
  if flock -n 9; then return 0; fi
  if [ -e "$bulk_admin" ]; then
    echo "A pool change (hs pool bulk) is running: nothing is synced this time."
    exit 0
  fi
  flock -w "${1:-1800}" 9 || { echo "Another job (the cache mover?) still holds the lock after ${1:-1800} seconds. Not syncing."; exit 1; }
}

bulk_lock_admin() {
  exec 9>"$bulk_lock"
  flock -w "${1:-60}" 9 || { echo "A parity sync or the cache mover is running. Try again in a few minutes."; exit 1; }
  : > "$bulk_admin"
  trap 'rm -f "$bulk_admin"' EXIT
}
