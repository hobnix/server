#!/usr/bin/env bash
# help: how long the reads of the interface take (every tab loads through these), slowest first
# help.de: wie lange die Lesezugriffe der Oberfläche dauern (jeder Reiter lädt damit), die langsamsten zuerst
# args: [--list] [--repeat <N>]
# Runs the read-only `hs sys ...` commands the tabs call at load time, one after the other, and prints seconds per command, slowest first.
# Needs root like the interface (the hs wrapper asks for it). Changes nothing: only reads; `sys system report` (writes a file) and every plan/start is left out.
#   --list         tab separated seconds<TAB>exit<TAB>command (for tools)
#   --repeat N     run each command N times and show the slowest of them (default 1: the first run is the one a person waits for)
# Test knob: HS_BIN (stand-in for the hs dispatcher).
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
hsbin=${HS_BIN:-$here/lib/hs.sh}
list=false repeat=1
while [ $# -gt 0 ]; do
  case "$1" in
    --list)   list=true; shift ;;
    --repeat) repeat=${2:-1}; shift 2 ;;
    *) say "usage: hs timing [--list] [--repeat <N>]"; exit 1 ;;
  esac
done
[[ "$repeat" =~ ^[1-9][0-9]*$ ]] || { say "usage: hs timing [--list] [--repeat <N>]"; exit 1; }

# the reads of the tabs (placeholder-free; the per-item ones such as `sys ct bindings <ct>` only run when an item is opened)
reads=(
  "status"
  "monitor disks"
  "pool info bulk"
  "pool info fast"
  "pool members bulk"
  "pool members fast"
  "pool disks"
  "shares overview"
  "shares principals"
  "shares deleted"
  "users list"
  "users groups"
  "ct list"
  "backup state"
  "backup overview"
  "backup snapshots"
  "jobs list"
  "jobs running"
  "logs units"
  "system doctor"
  "system cleanup"
  "system config"
)

now_ms() { echo $(( $(date +%s%N) / 1000000 )); }

rows=""
for c in "${reads[@]}"; do
  worst=0 rc=0
  for ((i = 0; i < repeat; i++)); do
    t0=$(now_ms); r=0
    # shellcheck disable=SC2086
    HS_CALLER=ui timeout 120 bash "$hsbin" sys $c >/dev/null 2>&1 </dev/null || r=$?
    t1=$(now_ms)
    [ $((t1 - t0)) -le "$worst" ] || worst=$((t1 - t0))
    [ "$r" -eq 0 ] || rc=$r
  done
  rows+=$(printf '%s\t%s\t%s' "$worst" "$rc" "$c")$'\n'
done
sorted=$(printf '%s' "$rows" | sort -t$'\t' -k1,1nr)

if $list; then
  printf '%s\n' "$sorted" | awk -F'\t' '{ printf "%d.%03d\t%s\t%s\n", $1 / 1000, $1 % 1000, $2, $3 }'
  exit 0
fi

total=$(printf '%s\n' "$sorted" | awk -F'\t' '{ s += $1 } END { print s + 0 }')
slow=$(printf '%s\n' "$sorted" | awk -F'\t' '$1 > 1000 { n++ } END { print n + 0 }')
failed=$(printf '%s\n' "$sorted" | awk -F'\t' '$2 != 0 { n++ } END { print n + 0 }')
if [ "$failed" -gt 0 ]; then status_line "Reads that failed" "$failed" warn; else status_line "Reads that failed" "None" ok; fi
if [ "$slow" -gt 0 ]; then status_line "Slower than 1 s" "$slow" warn; else status_line "Slower than 1 s" "None" ok; fi
{
  thead 'SECONDS' 'EXIT' 'COMMAND'
  printf '%s\n' "$sorted" | awk -F'\t' '{ printf "%d.%02d\t%s\t%s\n", $1 / 1000, ($1 % 1000) / 10, ($2 == 0 ? "ok" : $2), "hs sys " $3 }'
} | table
note "$(t 'All reads one after the other: %s s. The interface runs them in parallel and shows the visible tab first.' "$(awk -v ms="$total" 'BEGIN { printf "%.1f", ms / 1000 }')")"
