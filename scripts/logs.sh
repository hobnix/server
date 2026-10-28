#!/usr/bin/env bash
# help: read the journal of this server: what the services wrote, filtered by unit, level and time (read only)
# help.de: das Journal dieses Servers lesen: was die Dienste geschrieben haben, nach Dienst, Stufe und Zeit gefiltert (nur lesen)
# args: units | show [--unit <key>] [--level err|warning|info] [--since 1h|today|boot] [--lines <N>]
# System command (hs sys logs units|show): for the interface (the Logs tab) and tests. Plain text, never asks, changes nothing.
#   units   key<TAB>label of what is worth choosing (all, the hs jobs, incus, samba, ssh, zfs, the kernel)
#   show    the last N lines (default 300, at most 2000) of the journal as `journalctl -o short-iso` prints them, oldest first
#             --unit   one of the keys of `units` (default all)
#             --level  err = errors and worse, warning = warnings and worse, info = everything (default info)
#             --since  1h = the last hour, today, boot = since the boot (default today)
# Test knob: HS_JOURNALCTL (stand-in for journalctl).
set -euo pipefail
journalctl=${HS_JOURNALCTL:-journalctl}

units() {
  printf 'all\tEverything\n'
  printf 'jobs\tThe hs jobs (backup, sync, health check ...)\n'
  printf 'incus\tIncus (the instances)\n'
  printf 'samba\tSamba (the shares)\n'
  printf 'ssh\tSSH logins\n'
  printf 'zfs\tZFS (pools, the event daemon)\n'
  printf 'kernel\tThe kernel (disks, network, drivers)\n'
}

show() {
  local unit=all level=info since=today lines=300 a=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --unit)  unit=${2:-}; shift 2 ;;
      --level) level=${2:-}; shift 2 ;;
      --since) since=${2:-}; shift 2 ;;
      --lines) lines=${2:-}; shift 2 ;;
      *) echo "unknown option $1" >&2; exit 1 ;;
    esac
  done
  [[ "$lines" =~ ^[0-9]+$ ]] || { echo "--lines is a number" >&2; exit 1; }
  [ "$lines" -le 2000 ] || lines=2000
  [ "$lines" -ge 1 ] || lines=1
  case "$unit" in
    all)    ;;
    jobs)   a+=(-u 'hs-*') ;;
    incus)  a+=(-u incus -u 'incus-*') ;;
    samba)  a+=(-u 'samba-*') ;;
    ssh)    a+=(-u sshd) ;;
    zfs)    a+=(-u 'zfs-*' -u zfs-zed) ;;
    kernel) a+=(-k) ;;
    *) echo "unknown unit '$unit' (see: hs sys logs units)" >&2; exit 1 ;;
  esac
  case "$level" in
    err)     a+=(-p err) ;;
    warning) a+=(-p warning) ;;
    info)    ;;
    *) echo "--level is err, warning or info" >&2; exit 1 ;;
  esac
  case "$since" in
    1h)    a+=(--since "1 hour ago") ;;
    today) a+=(--since today) ;;
    boot)  a+=(-b) ;;
    *) echo "--since is 1h, today or boot" >&2; exit 1 ;;
  esac
  "$journalctl" "${a[@]}" -n "$lines" --no-pager -o short-iso 2>/dev/null </dev/null | grep -v '^-- ' || true
}

case "${1:-}" in
  units) units ;;
  show)  shift; show "$@" ;;
  *) echo "usage: logs.sh units | show [--unit <key>] [--level err|warning|info] [--since 1h|today|boot] [--lines <N>]" >&2; exit 1 ;;
esac
