#!/usr/bin/env bash
# help: run the fans at full speed for a few seconds to blow dust out of the case (then back as they were)
# help.de: Lüfter einige Sekunden auf voller Drehzahl laufen lassen, um Staub aus dem Gehäuse zu blasen (danach wieder wie vorher)
# args: clean [seconds]
# clean: every fan channel of the board's fan controller (hwmon pwm1..) is set to manual at 100 %, held for
# <seconds> (default 8, 3 to 30), then put back exactly as it was (mode and value, also on Ctrl-C or kill).
# Needs the nct6775 driver (configuration.nix) and root. Refuses when the CPU is hotter than 75 °C.
# It blows loose surface dust only; dust caked on heatsinks still needs compressed air with the case open.
# Stand-ins for tests: HS_HWMON_DIR (default /sys/class/hwmon), HS_FANS_SLEEP (command instead of `sleep`),
# HS_FANS_MAX_TEMP (°C).
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
root=${HS_HWMON_DIR:-/sys/class/hwmon}
nap=${HS_FANS_SLEEP:-sleep}
max_temp=${HS_FANS_MAX_TEMP:-75}

usage() { say "usage: hs fans clean [seconds]"; exit "${1:-0}"; }
case "${1:-}" in clean) shift ;; -h|--help|"") usage ;; *) usage 1 ;; esac
secs=${1:-8}
case "$secs" in ''|*[!0-9]*) fail "seconds must be a number between 3 and 30" ;; esac
{ [ "$secs" -ge 3 ] && [ "$secs" -le 30 ]; } || fail "seconds must be a number between 3 and 30"
if [ -z "${HS_HWMON_DIR:-}" ] && [ "$(id -u)" != 0 ]; then fail "needs root (run it as: hs fans clean)"; fi

# the hwmon device that has pwm channels (the fan controller)
dir=""
for d in "$root"/hwmon*; do
  [ -e "$d/pwm1" ] && { dir=$d; break; }
done
[ -n "$dir" ] || fail "no fan controller found (is the nct6775 driver loaded? see hs fans in the docs)"

# refuse when the CPU is already hot
for d in "$root"/hwmon*; do
  [ "$(cat "$d/name" 2>/dev/null)" = coretemp ] || continue
  for f in "$d"/temp*_input; do
    [ -r "$f" ] || continue
    t=$(( $(cat "$f") / 1000 ))
    [ "$t" -lt "$max_temp" ] || fail "the CPU is at ${t} °C: not running the fans now, they are busy already"
  done
done

declare -A old_en old_val
chans=()
for p in "$dir"/pwm[0-9]; do
  [ -e "${p}_enable" ] || continue
  n=${p##*pwm}
  old_en[$n]=$(cat "${p}_enable"); old_val[$n]=$(cat "$p")
  chans+=("$n")
done
[ "${#chans[@]}" -gt 0 ] || fail "the fan controller has no pwm channels that can be set"

restored=""
restore() {
  [ -z "$restored" ] || return 0
  restored=1
  local n
  for n in "${chans[@]}"; do
    echo "${old_en[$n]}" > "$dir/pwm${n}_enable" 2>/dev/null || true
    [ "${old_en[$n]}" != 1 ] || echo "${old_val[$n]}" > "$dir/pwm$n" 2>/dev/null || true
  done
}
trap restore EXIT
trap 'exit 130' INT TERM HUP

step "$(t 'Fans at full speed for %s s' "$secs")"
set_ok=0
for n in "${chans[@]}"; do
  if echo 1 > "$dir/pwm${n}_enable" 2>/dev/null && echo 255 > "$dir/pwm$n" 2>/dev/null; then set_ok=$((set_ok + 1))
  else warn "$(t 'Fan channel %s cannot be set, left alone' "$n")"; fi
done
[ "$set_ok" -gt 0 ] || fail "no fan channel could be set"

$nap "$secs"

for n in "${chans[@]}"; do
  rpm=$(cat "$dir/fan${n}_input" 2>/dev/null || echo 0)
  [ "${rpm:-0}" -gt 0 ] || continue
  kv "$(t 'Fan %s' "$n")" "$rpm rpm"
done
restore
ok "Fans are back as they were"
