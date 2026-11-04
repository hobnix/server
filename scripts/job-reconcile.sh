#!/usr/bin/env bash
# help: at boot, mark jobs whose unit is gone as interrupted (job record, ADR 0004) and push one message about them; never re-runs a job
# help.de: markiert beim Start Aufgaben, deren Unit weg ist, als unterbrochen (Jobprotokoll, ADR 0004) und schickt eine Nachricht; startet nie etwas neu
# args: none
# Run by hs-job-reconcile.service. Always exits 0 so the boot is never held up.
# Test knobs: HS_JOBS_DIR, HS_SYSTEMCTL, HS_UPTIME_FILE (job-record.py), HS_JOB_NOTIFY (a program that stands in for notify.sh).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/ui.sh"

out=$(python3 "$here/job-record.py" reconcile) || warn "Some job records could not be checked"
[ -n "$out" ] || exit 0

count=0; list=""
while IFS=$'\t' read -r _ _ desc; do
  [ -n "${desc:-}" ] || continue
  count=$((count + 1))
  if [ "$count" -le 5 ]; then list="${list:+$list, }$desc"; fi
done <<<"$out"
[ "$count" -gt 0 ] || exit 0
[ "$count" -le 5 ] || list="$list and $((count - 5)) more"

title="$(hostname): $count job(s) interrupted"
msg="These jobs did not finish because the server restarted or their unit stopped: $list. They were not started again."
if [ -n "${HS_JOB_NOTIFY:-}" ]; then
  "$HS_JOB_NOTIFY" --category problem "$title" "$msg" high || true
else
  bash "$here/notify.sh" --category problem "$title" "$msg" high || warn "The push message could not be sent"
fi
exit 0
