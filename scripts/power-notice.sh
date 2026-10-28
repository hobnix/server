#!/usr/bin/env bash
# help: push messages for the power state: the server started (vault open), is going down (reboot or shutdown)
# help.de: Push-Nachrichten zum Betriebszustand: Server gestartet (Tresor offen), fährt herunter (Neustart oder Ausschalten)
# args: started | stopping
# started (hs-boot-notice.service, after the network is up): "started, vault open" at default priority. While the storage is locked
# it sends nothing: hs-unlock / hs-unlock-alarm already sent the urgent "unlock needed" message. stopping (ExecStop of
# hs-shutdown-notice.service, the network is still up): "rebooting" or "shutting down" at low priority.
# Push messages are never translated. HS_RUN_DIR / HS_LIST_JOBS are test knobs.
set -euo pipefail
here=$(dirname "$0")
host=$(hostname)
locked=${HS_RUN_DIR:-/run/hs}/storage-locked

case "${1:-}" in
  started)
    [ ! -e "$locked" ] || exit 0
    # a rebuild (hs update) restarts this unit too: only a real boot (up for less than 15 min) counts
    up=$(cut -d. -f1 "${HS_PROC_UPTIME:-/proc/uptime}" 2>/dev/null || echo 0)
    [ "${up:-0}" -lt "${HS_BOOT_WINDOW:-900}" ] || exit 0
    # the network is usually up (network-online), but a router that is still starting needs a moment
    for _ in $(seq 1 "${HS_NOTICE_TRIES:-12}"); do
      HS_NOTIFY_STRICT=1 bash "$here/notify.sh" --category start "$host: started" "The server is up and the vault is open." default && exit 0
      sleep "${HS_NOTICE_WAIT:-10}"
    done
    ;;
  stopping)
    jobs=$( ${HS_LIST_JOBS:-systemctl list-jobs --no-legend} 2>/dev/null || true)
    # a rebuild (hs update) stops and starts this unit too: without a reboot/poweroff job it is no shutdown, say nothing
    if grep -q 'reboot.target' <<<"$jobs"; then what="rebooting"
    elif grep -Eq '(poweroff|halt|kexec)\.target' <<<"$jobs"; then what="shutting down"
    else exit 0; fi
    bash "$here/notify.sh" --category stop "$host: $what" "The server is $what. If you did not do this, look at the console." low || true
    ;;
  *) echo "usage: power-notice.sh started|stopping" >&2; exit 1 ;;
esac
exit 0
