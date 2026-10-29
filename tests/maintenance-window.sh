#!/usr/bin/env bash
# Spin-down rules (docs/Entwicklungsnotizen.md, "Maintenance window"): periodic SMART polling never wakes a disk, and
# the HDD jobs sit inside the 03:00-06:30 window. Greps the sources; needs no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

# only monitor.sh and disk-health.sh may call smartctl; the collectors go through them
bad=$(cd "$SCRIPTS" && grep -lE '(^|[^a-z_/.-])smartctl +-' state.sh state-db.py deck-status.sh overview-status.sh health-check.sh web-serve.py 2>/dev/null || true)
check_eq "the periodic collectors never call smartctl themselves" "" "$bad"
check "monitor.sh polls with smartctl -n standby" grep -q 'smartctl -n standby' "$SCRIPTS/monitor.sh"
check "disk-health list asks every disk with the standby flag" grep -q 'smart_json "/dev/\$name" standby' "$SCRIPTS/disk-health.sh"
check "smart_json turns on -n standby when asked" grep -q 'flags=(-n standby' "$SCRIPTS/disk-health.sh"

# no timer script lists/walks /bulk (find in cache-mover and sync-shares run inside the window or on the SSD)
bad=$(cd "$SCRIPTS" && grep -nE '\b(du|find|ls) +[^|;]*/bulk' health-check.sh monitor.sh deck-status.sh state.sh 2>/dev/null | grep -v '/mnt/bulk/cache' || true)   # the cache is on the SSD
check_eq "no health/monitor/deck script walks /bulk" "" "$bad"

# HDD jobs: start times between 03:00 and 06:59 (no job at an odd hour)
for pat in 'startAt = "Sat 03:10"' 'startAt = "\*-\*-\* 03:15"' 'interval = "Sun \*-\*-\* 05:00:00"' 'randomizedDelaySec = "0"' 'startAt = "04:00"' 'startAt = "\*-\*-\* 03:05:00"'; do
  check "the Nix config (configuration.nix or a capability module) has $pat" grep -qE "$pat" "$ROOT/configuration.nix" "$ROOT"/capabilities/*/module.nix
done
finish
