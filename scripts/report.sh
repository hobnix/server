#!/usr/bin/env bash
# help: collect what a helper needs to look at a problem into one text file (no passwords, no machine.toml)
# help.de: sammelt, was ein Helfer braucht, um ein Problem anzusehen, in einer Textdatei (keine Passwörter, keine machine.toml)
# args: [--out <file>]
set -uo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
state=${HS_STATE_DIR:-/var/lib/hs}
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) [ $# -ge 2 ] || { say "usage: hs report [--out <file>]"; exit 1; }; out=$2; shift 2 ;;
    *) say "usage: hs report [--out <file>]"; exit 1 ;;
  esac
done
[ -n "$out" ] || { mkdir -p "$state/reports"; out=$state/reports/report-$(date +%Y%m%d-%H%M%S).txt; }

section() { printf '\n===== %s =====\n' "$1"; }
run() {   # run <title> <command...>: the output, or a note that it failed
  section "$1"; shift
  "$@" 2>&1 || echo "(failed: $*)"
}
{
  echo "hs report $(date -Is) on $(hostname)"
  run "system" bash "$here/system.sh" info
  run "doctor" bash "$here/doctor.sh"
  run "health" bash "$here/health-check.sh" --dry-run
  run "jobs" bash "$here/jobs.sh" --list
  run "pools" bash "$here/manage-pool.sh" bulk --members
  run "disks (SMART verdicts)" bash "$here/disk-health.sh" --list
  run "backup" bash "$here/backup.sh" --state
  run "containers" bash "$here/status.sh"
  run "zpool" zpool status
  run "lsblk" lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS
  section "failed units"; systemctl --failed --no-pager 2>&1 | head -n 30
  section "recent hs messages"; journalctl -t hs-notify -n 30 --no-pager 2>&1
  section "registry"; bash "$here/lib/hs.sh" sys registry 2>&1 | head -n 5
} > "$out"
# secrets: tokens and passwords that a stray line might hold
sed -i -E 's/((token|password|passwd|secret|api[-_ ]?key)[^=:]*[=:][[:space:]]*).+/\1[removed]/I' "$out"
chmod 600 "$out"
ok "$(t 'Report written: %s' "$out")"
note "Look through it before you send it to someone."
