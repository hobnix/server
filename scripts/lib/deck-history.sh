#!/usr/bin/env bash
# The last 24 hours for the status document (scripts/deck-status.sh): one median per hour of CPU, memory, GPU and network, and how much of the hour
# the machine was up, so a display does not have to keep its own history. Sourced, not run. The proxyserver repo has a COPY of this file
# (modules/deck/deck-history.sh): change both.
#
# State, in $DH_DIR (default /var/lib/hs/deck-history):
#   last     time rx tx cpu_total cpu_idle uptime   the previous reading (rates and the CPU load are differences of two readings)
#   samples  time cpu% mem% gpu% rx_bps tx_bps boot  every reading of the current hour ("-" = unknown, boot = 1 when the uptime went down)
#   hours    hour cpu mem gpu rx tx up boot          one line per finished hour (hour = epoch / 3600, medians, up = share of the expected readings)
# NOTE (state database): the homeserver no longer uses this file, its history lives in state.db (scripts/state-db.py history-record|history). It stays
# here as the reference for the proxyserver's copy until that repo gets the database too.
# Readings are written only when the caller says so (HS_DECK_RECORD=1, the timer does): looking at the document by hand does not add one.

DH_EXPECTED=${DH_EXPECTED:-360}     # readings in a full hour: one every 10 seconds
DH_KEEP=${DH_KEEP:-72}              # finished hours kept on disk

# dh_record NOW RX TX CPU_TOTAL CPU_IDLE MEM_TOTAL MEM_AVAILABLE GPU_UTIL UPTIME   (any of them empty = unknown)
# Written so that it also runs under `set -e` (the proxyserver's script does): no list that ends in a failing test.
dh_record() {
  local now=$1 rx=$2 tx=$3 ct=$4 ci=$5 mt=$6 ma=$7 gpu=$8 up=$9 dir=${DH_DIR:-/var/lib/hs/deck-history}
  mkdir -p "$dir" 2>/dev/null || return 0
  local first
  if [ -s "$dir/samples" ]; then            # a new hour has begun: the readings of the old one become one line
    first=$(( $(head -n 1 "$dir/samples" | cut -d' ' -f1) / 3600 ))
    if [ "$first" -lt $((now / 3600)) ]; then dh_roll "$dir" "$first"; fi
  fi
  local pt="" prx=0 ptx=0 pct=0 pci=0 pup=0 cpu="-" mem="-" rxr="-" txr="-" boot=0 dt
  if [ -r "$dir/last" ]; then read -r pt prx ptx pct pci pup < "$dir/last" || true; fi
  if [ -n "$pt" ] && [ "$now" -gt "$pt" ]; then
    dt=$((now - pt))
    if [ -n "$rx" ] && [ "$rx" -ge "$prx" ]; then rxr=$(( (rx - prx) / dt )); fi
    if [ -n "$tx" ] && [ "$tx" -ge "$ptx" ]; then txr=$(( (tx - ptx) / dt )); fi
    if [ -n "$ct" ] && [ "$ct" -gt "$pct" ]; then
      cpu=$(awk -v t=$((ct - pct)) -v i=$((ci - pci)) 'BEGIN { printf "%d", 100 * (1 - i / t) + 0.5 }')
    fi
    if [ -n "$up" ] && [ "$up" -lt "$pup" ]; then boot=1; fi
  fi
  if [ -n "$mt" ] && [ "$mt" -gt 0 ]; then mem=$(awk -v t="$mt" -v a="$ma" 'BEGIN { printf "%d", 100 * (1 - a / t) + 0.5 }'); fi
  printf '%s %s %s %s %s %s %s\n' "$now" "$cpu" "$mem" "${gpu:--}" "$rxr" "$txr" "$boot" >> "$dir/samples"
  printf '%s %s %s %s %s %s\n' "$now" "${rx:-0}" "${tx:-0}" "${ct:-0}" "${ci:-0}" "${up:-0}" > "$dir/last.new"
  mv "$dir/last.new" "$dir/last"
}

# the median of a column of the samples file ("-" skipped); "-" when there is none
_dh_median() {
  awk -v c="$1" '$c != "-" { print $c }' "$2" | sort -n | awk '{ a[NR] = $1 } END { if (!NR) print "-"; else if (NR % 2) print a[(NR + 1) / 2]; else print (a[NR / 2] + a[NR / 2 + 1]) / 2 }'
}

# dh_roll DIR HOUR: the readings of that hour become a line of hours
dh_roll() {
  local dir=$1 hour=$2 n boot
  n=$(grep -c . "$dir/samples")
  boot=$(awk '$7 == 1 { f = 1 } END { print f + 0 }' "$dir/samples")
  printf '%s %s %s %s %s %s %s %s\n' "$hour" "$(_dh_median 2 "$dir/samples")" "$(_dh_median 3 "$dir/samples")" "$(_dh_median 4 "$dir/samples")" \
    "$(_dh_median 5 "$dir/samples")" "$(_dh_median 6 "$dir/samples")" "$(awk -v n="$n" -v e="$DH_EXPECTED" 'BEGIN { s = n / e; if (s > 1) s = 1; printf "%.2f", s }')" "$boot" >> "$dir/hours"
  tail -n "$DH_KEEP" "$dir/hours" > "$dir/hours.new"
  mv "$dir/hours.new" "$dir/hours"
  : > "$dir/samples"
}

# dh_json NOW: {"interval_s":3600,"hours":[24 entries, the oldest first, null where the hour was not recorded]}
dh_json() {
  local now=$1 dir=${DH_DIR:-/var/lib/hs/deck-history} file
  file="$dir/hours"
  if [ ! -r "$file" ]; then file=/dev/null; fi
  jq -n -c --argjson hour $((now / 3600)) --rawfile hours "$file" '
    def num: if . == "-" then null else tonumber end;
    ($hours | split("\n") | map(select(. != "") | split(" ")) | map({key: .[0], value: .}) | from_entries) as $m
    | {interval_s: 3600, hours: [range($hour - 24; $hour) | . as $h | ($m[$h | tostring]) as $r
        | if $r == null then null
          else {t: ($h * 3600), cpu: ($r[1] | num), mem: ($r[2] | num), gpu: ($r[3] | num), rx: ($r[4] | num), tx: ($r[5] | num),
                up: ($r[6] | tonumber), boot: ($r[7] == "1")} end]}'
}
