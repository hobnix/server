#!/usr/bin/env bash
# help: start a SMART self-test inside every disk (short: minutes, long: hours); the schedule runs it weekly and monthly
# help.de: startet in jeder Platte einen SMART-Selbsttest (short: Minuten, long: Stunden); der Zeitplan macht das wöchentlich und monatlich
# args: short | long [--dry-run]
# The disks stay usable. Results: hs disk <disk> results; a failed test makes the health check complain
# (disk-health rates "last self-test failed" as BAD). The time of the last start is kept in
# /var/lib/hs/selftest.state, so the health check can tell when the schedule stopped.
# HS_DISK_HEALTH points tests at a stand-in, HS_STATE_DIR at another state directory.
set -uo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
dh=${HS_DISK_HEALTH:-$here/disk-health.sh}
state=${HS_STATE_DIR:-/var/lib/hs}/selftest.state

kind=${1:-}; dry=false
[ "${2:-}" != --dry-run ] || dry=true
case "$kind" in short|long) ;; *) say "usage: hs disk selftest short|long [--dry-run]"; exit 1 ;; esac

mapfile -t disks < <(bash "$dh" --list 2>/dev/null | cut -f1)
[ ${#disks[@]} -gt 0 ] && [ -n "${disks[0]}" ] || fail "No disk found (needs root)."
started=0; failed=0
step "$(t 'SMART self-test (%s)' "$kind")"
for d in "${disks[@]}"; do
  if $dry; then note "$(t 'Would start a %s self-test in %s' "$kind" "$d")"; continue; fi
  if bash "$dh" --test "$kind" "$d" >/dev/null 2>&1; then started=$((started + 1)); ok "$(t '%s: %s self-test started' "$d" "$kind")"
  else failed=$((failed + 1)); warn "$(t '%s: could not start a self-test (busy, or the disk does not support it)' "$d")"; fi
done
$dry && exit 0
[ "$started" -gt 0 ] || fail "No self-test could be started."
note "The disks do it by themselves; nothing else to do. Look at the results later: hs disk <disk> results"
mkdir -p "$(dirname "$state")"
tmp=$(grep -v "^$kind=" "$state" 2>/dev/null || true)
{ [ -z "$tmp" ] || echo "$tmp"; echo "$kind=$(date +%s)"; } > "$state.new" && mv "$state.new" "$state"
