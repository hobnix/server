#!/usr/bin/env bash
# help: the processor and the board's sensors as plain lines: CPU model, cores, temperatures, fan speeds (read only, no root)
# help.de: der Prozessor und die Sensoren der Platine als schlichte Zeilen: CPU-Modell, Kerne, Temperaturen, Lüfterdrehzahlen (nur lesend, ohne root)
# args: [-]
# System command (hs sys hardware): key TAB value lines for the web interface. It reads /proc/cpuinfo and /sys/class/hwmon only (no `sensors`, no
# smartctl: the disks have their own read, the graphics card is in the status document). Anything that is missing is left out; the exit is 0.
#   cpu-model<TAB>text        e.g. Intel(R) Core(TM) i7-6700K CPU @ 4.00GHz
#   cpu-cores<TAB>N           physical cores        cpu-threads<TAB>N   logical processors
#   temp<TAB>name<TAB>deg C   one row per sensor: the CPU package/cores (coretemp, k10temp) and the board chips (nct*, it87, acpitz ...);
#                             nvme and drivetemp are the disks' and left out; a value outside 1..149 is a broken sensor and left out
#   fan<TAB>name<TAB>rpm      one row per fan header; 0 = nothing spins there (or nothing is plugged in)
# Test knobs: HS_HWMON_DIR (default /sys/class/hwmon), HS_CPUINFO (default /proc/cpuinfo).
set -uo pipefail
root=${HS_HWMON_DIR:-/sys/class/hwmon}
cpuinfo=${HS_CPUINFO:-/proc/cpuinfo}

clean() { tr -d '\t\r\n' | sed -e 's/^ *//' -e 's/ *$//' -e 's/  */ /g'; }

if [ -r "$cpuinfo" ]; then
  model=$(sed -n 's/^model name[[:space:]]*:[[:space:]]*//p' "$cpuinfo" | head -n 1 | clean)
  [ -z "$model" ] || printf 'cpu-model\t%s\n' "$model"
  threads=$(grep -c '^processor[[:space:]]*:' "$cpuinfo" || true)
  # physical cores = distinct (physical id, core id) pairs; some kernels (VMs, ARM) have no core id: then the "cpu cores" line, else the threads
  cores=$(awk -F: '/^physical id/ { p = $2 + 0 } /^core id/ { seen[p "/" ($2 + 0)] = 1 } END { n = 0; for (k in seen) n++; print n }' "$cpuinfo")
  if [ "${cores:-0}" -eq 0 ]; then cores=$(sed -n 's/^cpu cores[[:space:]]*:[[:space:]]*//p' "$cpuinfo" | head -n 1 | clean); fi
  [ -n "${cores:-}" ] && [ "${cores:-0}" -gt 0 ] 2>/dev/null || cores=$threads
  [ "${cores:-0}" -le 0 ] || printf 'cpu-cores\t%s\n' "$cores"
  [ "${threads:-0}" -le 0 ] || printf 'cpu-threads\t%s\n' "$threads"
fi

nice_name() {   # nice_name <chip> <label> <fallback like temp1>
  local chip=$1 label=$2 fb=$3
  case "$chip:$label" in
    coretemp:Package*) echo "CPU package" ;;
    coretemp:Core*)    echo "CPU ${label,}" ;;
    k10temp:Tctl|k10temp:Tdie) echo "CPU" ;;
    *:"") echo "$chip $fb" ;;
    *)    echo "$label" ;;
  esac
}

for d in "$root"/hwmon*; do
  [ -d "$d" ] || continue
  chip=$(cat "$d/name" 2>/dev/null | clean)
  case "$chip" in ""|nvme|drivetemp|nvidia|amdgpu|iwlwifi*) continue ;; esac
  for f in "$d"/temp[0-9]*_input; do
    [ -r "$f" ] || continue
    v=$(cat "$f" 2>/dev/null) || continue
    case "$v" in ''|*[!0-9-]*) continue ;; esac
    t=$(( v / 1000 ))
    { [ "$t" -ge 1 ] && [ "$t" -le 149 ]; } || continue
    b=${f%_input}; fb=$(basename "$b")
    label=$(cat "${b}_label" 2>/dev/null | clean)
    printf 'temp\t%s\t%s\n' "$(nice_name "$chip" "$label" "$fb")" "$t"
  done
  for f in "$d"/fan[0-9]*_input; do
    [ -r "$f" ] || continue
    v=$(cat "$f" 2>/dev/null) || continue
    case "$v" in ''|*[!0-9]*) continue ;; esac
    b=${f%_input}; fb=$(basename "$b")
    label=$(cat "${b}_label" 2>/dev/null | clean)
    printf 'fan\t%s\t%s\n' "${label:-$chip $fb}" "$v"
  done
done
exit 0
