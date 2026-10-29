#!/usr/bin/env bash
# help: start a SMART self-test inside every disk (short: minutes, long: hours); the schedule runs it weekly and monthly
# help.de: startet in jeder Platte einen SMART-Selbsttest (short: Minuten, long: Stunden); der Zeitplan macht das wöchentlich und monatlich
# args: short | long [--dry-run] | long --night
# The disks stay usable. Results: hs disk <disk> results; a failed test makes the health check complain
# (disk-health rates "last self-test failed" as BAD). The time of the last start is kept in
# /var/lib/hs/selftest.state, so the health check can tell when the schedule stopped.
# HS_DISK_HEALTH points tests at a stand-in, HS_STATE_DIR at another state directory.
set -uo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
dh=${HS_DISK_HEALTH:-$here/disk-health.sh}
state=${HS_STATE_DIR:-/var/lib/hs}/selftest.state

kind=${1:-}; dry=false; night=false
for a in "${@:2}"; do
  case "$a" in --dry-run) dry=true ;; --night) night=true ;; *) kind="" ;; esac
done
case "$kind" in short|long) ;; *) say "usage: hs disk selftest short|long [--dry-run]"; exit 1 ;; esac
$night && [ "$kind" != long ] && { say "usage: selftest.sh long --night"; exit 1; }

mapfile -t disks < <(bash "$dh" --list 2>/dev/null | cut -f1)
[ ${#disks[@]} -gt 0 ] && [ -n "${disks[0]}" ] || fail "No disk found (needs root)."
if $night; then
  # Staggered long tests: one disk per night, ordered by serial (the timer runs every night); the day number picks the disk,
  # so with N disks each gets a long test every N nights. A disk that cannot be tested (USB bridge, still busy with its last test)
  # is skipped with a note and the next one in serial order is tried; the unit never fails for that.
  mapfile -t disks < <(for d in "${disks[@]}"; do
    s=$(lsblk -dno SERIAL "/dev/$d" 2>/dev/null | awk 'NR == 1' || true)
    printf '%s\t%s\n' "${s:-$d}" "$d"
  done | LC_ALL=C sort | cut -f2)
  off=$(( ${HS_NOW:-$(date +%s)} / 86400 % ${#disks[@]} ))
  disks=("${disks[@]:off}" "${disks[@]:0:off}")
fi
started=0; failed=0
step "$(t 'SMART self-test (%s)' "$kind")"
for d in "${disks[@]}"; do
  if $dry; then note "$(t 'Would start a %s self-test in %s' "$kind" "$d")"; $night && break; continue; fi
  if bash "$dh" --test "$kind" "$d" >/dev/null 2>&1; then started=$((started + 1)); ok "$(t '%s: %s self-test started' "$d" "$kind")"; $night && break
  elif $night; then failed=$((failed + 1)); note "$(t '%s: skipped tonight (busy with its last test, or no self-test support)' "$d")"
  else failed=$((failed + 1)); warn "$(t '%s: could not start a self-test (busy, or the disk does not support it)' "$d")"; fi
done
$dry && exit 0
if [ "$started" -eq 0 ]; then
  $night && { note "No disk could be tested tonight."; exit 0; }
  fail "No self-test could be started."
fi
note "The disks do it by themselves; nothing else to do. Look at the results later: hs disk <disk> results"
mkdir -p "$(dirname "$state")"
tmp=$(grep -v "^$kind=" "$state" 2>/dev/null || true)
{ [ -z "$tmp" ] || echo "$tmp"; echo "$kind=$(date +%s)"; } > "$state.new" && mv "$state.new" "$state"
