#!/usr/bin/env bash
# help: small server chores without asking anything: a test push message, pin the MACs, move the upload cache, clean the fans (plan, then start)
# help.de: kleine Wartungsaufgaben ohne Rückfragen: eine Test-Push-Nachricht, MAC-Adressen festnageln, den Upload-Cache leeren, Lüfter reinigen (plan, dann start)
# args: plan|start test-push | pin-macs | cache-mover | fans-clean [--seconds N]
# System command (hs sys admin plan|start): for the interface and tests. It never asks and prints plain key<TAB>value lines like dns-change.sh.
# The work is health.sh's, mac.sh's, cache-mover.sh's and fans.sh's (no logic is repeated here).
#   test-push    send a test message to the push address (health.sh test); refused while no address is set (hs config set notifyUrl ...). Answers done.
#   pin-macs     pin the current MAC address of every instance (mac.sh; harmless, it only writes what is there already). Answers done.
#   cache-mover  (snapraid layout) move the uploaded files from the SSD cache to the data disks now (cache-mover.sh --now), as a background job;
#                refused where there is no cache
#   fans-clean   run the fans at full speed for N seconds (3 to 30, default 8) to blow dust out of the case, then back as they were
#                (fans.sh clean N), as a background job; refused where no fan controller is found
# plan: exit 0 = allowed, 1 = refused. Output: status ok|refused, reason<TAB><text>, heading|step|note|warn|command<TAB><line>, long<TAB>yes|no.
# start: the same checks, then the work (done) or a background job (started + unit).
# Test knobs: HS_HEALTH, HS_MAC, HS_CACHE_MOVER, HS_FANS (stand-ins for the scripts), HS_NOTIFY_FILE, HS_CACHE_DIR, HS_MOUNTPOINT, HS_HWMON_DIR.
set -euo pipefail
here=$(dirname "$0")

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

verb=${1:-}; action=${2:-}
case "$verb" in plan|start) ;; *) echo "usage: admin-change.sh plan|start test-push|pin-macs|cache-mover|fans-clean [--seconds N]" >&2; exit 1 ;; esac
case "$action" in test-push|pin-macs|cache-mover|fans-clean) ;; *) refuse "unknown action (test-push, pin-macs, cache-mover or fans-clean)" ;; esac
shift 2 || true
secs=8
while [ $# -gt 0 ]; do
  case "$1" in
    --seconds) [ "$action" = fans-clean ] || refuse "--seconds is for fans-clean"; [ $# -ge 2 ] || refuse "--seconds needs a value"; secs=$2; shift 2 ;;
    *) refuse "unknown option $1" ;;
  esac
done

export HS_PLAIN=1 HS_LANG=en HS_CALLER=${HS_CALLER:-ui}
unset HS_GUIDED_TTY
. "$here/lib/setting.sh"

job() {   # job <slug> <description> <command...>
  . "$here/lib/job.sh"
  local unit
  unit=$(hs_job "$1" "$2" -- "${@:3}") || refuse "the job could not be started"
  printf 'status\tstarted\nunit\t%s\n' "$unit"
}

case "$action" in
  test-push)
    nf=${HS_NOTIFY_FILE:-${HS_STATE_DIR:-/var/lib/hs}/notify-url}
    if [ ! -s "$nf" ] && [ -z "$(setting_get notifyUrl 2>/dev/null || true)" ]; then
      refuse "There is no push address yet: set one first (hs config set notifyUrl https://ntfy.sh/<a random topic>)."
    fi
    if [ "$verb" = start ]; then
      bash "${HS_HEALTH:-$here/health.sh}" test </dev/null >/dev/null 2>&1 || refuse "the test message could not be sent (look at hs health)"
      printf 'status\tdone\n'
      exit 0
    fi
    printf 'status\tok\nheading\tsend a test push message\n'
    printf 'step\tsend "test" to the push address of this server; it also goes to the journal\n'
    printf 'note\tIf nothing arrives on your phone, the address or the app is wrong; the health check would not reach you either.\n'
    printf 'command\ths health test\nlong\tno\n' ;;
  pin-macs)
    if [ "$verb" = start ]; then
      bash "${HS_MAC:-$here/mac.sh}" </dev/null >/dev/null 2>&1 || refuse "the MAC addresses could not be pinned"
      printf 'status\tdone\n'
      exit 0
    fi
    printf 'status\tok\nheading\tpin the MAC address of every instance\n'
    printf 'step\twrite the MAC an instance has now as its own, so it keeps it (and its fixed address at the router)\n'
    printf 'note\tHarmless and safe to repeat; the nightly job does the same for new instances.\n'
    printf 'command\ths mac\nlong\tno\n' ;;
  cache-mover)
    bt=$(cat "${HS_BULK_TYPE_FILE:-/etc/hs/bulk-type}" 2>/dev/null || echo zfs)
    [ "$bt" = snapraid ] || refuse "There is no upload cache: it exists only on the snapraid layout."
    ${HS_MOUNTPOINT:-mountpoint} -q "${HS_CACHE_DIR:-/mnt/bulk/cache}" 2>/dev/null || refuse "There is no upload cache on this server (nothing mounted at /mnt/bulk/cache)."
    if [ "$verb" = start ]; then job cache-mover "hs cache-mover --now" bash "${HS_CACHE_MOVER:-$here/cache-mover.sh}" --now; exit 0; fi
    printf 'status\tok\nheading\tmove the upload cache to the data disks now\n'
    printf 'step\tmove the files of the SSD cache to the data disks, also those changed in the last minutes (not open ones)\n'
    printf 'step\tthen update the parity\n'
    printf 'note\tIt runs before every parity sync anyway; do it by hand to empty a filling cache. Refused while a sync or a pool change holds the lock.\n'
    printf 'command\ths cache-mover --now\nlong\tyes\n' ;;
  fans-clean)
    [[ "$secs" =~ ^[0-9]{1,2}$ ]] && [ "$secs" -ge 3 ] && [ "$secs" -le 30 ] || refuse "seconds must be a number between 3 and 30"
    found=false
    for d in "${HS_HWMON_DIR:-/sys/class/hwmon}"/hwmon*; do [ -e "$d/pwm1" ] && found=true; done
    $found || refuse "No fan controller found (is the nct6775 driver loaded? see the Hardware page)."
    if [ "$verb" = start ]; then job fans-clean "hs fans clean $secs" bash "${HS_FANS:-$here/fans.sh}" clean "$secs"; exit 0; fi
    printf 'status\tok\nheading\trun the fans at full speed for %s seconds\n' "$secs"
    printf 'step\tset every fan to 100 %% for %s seconds, then back exactly as it was\n' "$secs"
    printf 'warn\tThe fans get loud for a moment. It is refused when the CPU is hotter than 75 degrees.\n'
    printf 'note\tIt blows loose surface dust out only; caked dust on a heatsink needs compressed air with the case open.\n'
    printf 'command\ths fans clean %s\nlong\tyes\n' "$secs" ;;
esac
exit 0
