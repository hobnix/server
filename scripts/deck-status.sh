#!/usr/bin/env bash
# help: one JSON document with the numbers a status display needs (Stream Deck, wall monitor, Home Assistant)
# help.de: ein JSON-Dokument mit den Zahlen für eine Statusanzeige (Stream Deck, Wandmonitor, Home Assistant)
# args: -
# System command (hs sys deck), read only, needs root for the disk and pool facts (hs-deck.service runs it as root every 10 s and writes
# /run/hs-deck/deck.json, which scripts/deck-serve.py hands out). No secrets: no names of users, shares, paths or addresses.
# Counters, not rates: net rx/tx bytes and cpu jiffies are totals since the boot, the client takes two readings and divides by the time between them.
# A source that cannot be read leaves its key out (null), so a client never shows an old value as a fresh one. The proxyserver sends the same
# shape with "kind": "proxyserver" (only the keys it has). schema 1.
# gpu: the first NVIDIA card from nvidia-smi (null without one). history: the last 24 hours, one median per hour (the state database, scripts/state-db.py; DH_DIR is only where the old text files are migrated from); the
# readings are kept only when HS_DECK_RECORD=1 (the timer sets it), so looking at the document by hand adds none.
# Test knobs: HS_PROC, HS_NET_DIR, HS_ZPOOL, HS_DF, HS_STATE_DIR, HS_LOCKED_MARKER, HS_OVERVIEW_STATUS, HS_MONITOR, HS_IP, HS_HOSTNAME, HS_NOW,
# HS_NVIDIA_SMI, DH_DIR (the history folder).
set -uo pipefail
here=$(dirname "$0")
state=${HS_STATE_DIR:-/var/lib/hs}
proc=${HS_PROC:-/proc}
netdir=${HS_NET_DIR:-/sys/class/net}
export HS_PLAIN=1 HS_LANG=en
DH_DIR=${DH_DIR:-$state/deck-history}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
bash "${HS_OVERVIEW_STATUS:-$here/overview-status.sh}" >"$tmp/status" 2>/dev/null </dev/null &
{ HS_STATE_DIR=$state bash "$here/state.sh" deck-disks >"$tmp/disks" 2>/dev/null </dev/null ||     # the disk lines come from the state database when its collector ran lately,
    bash "${HS_MONITOR:-$here/monitor.sh}" --disks >"$tmp/disks" 2>/dev/null </dev/null; } &     # else straight from the disks as before
${HS_ZPOOL:-zpool} list -Hp -o size,alloc,health fast >"$tmp/fast" 2>/dev/null </dev/null &
${HS_DF:-df} -B1 --output=size,used /bulk >"$tmp/bulk" 2>/dev/null </dev/null &
${HS_NVIDIA_SMI:-nvidia-smi} --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits >"$tmp/gpu" 2>/dev/null </dev/null &
wait

# --- the machine: /proc and the physical port of the default interface
iface=$(${HS_IP:-ip} route show default 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
# The default interface is the bridge br0, which sees the untagged LAN only; the VLAN bridges (br-<name>) hang off the same NIC as tagged
# sub-interfaces, so the traffic of the instances never crosses br0. The physical port under the bridge counts all of it.
if [ -n "$iface" ] && [ -d "$netdir/$iface/brif" ]; then
  for port in "$netdir/$iface"/brif/*; do
    if [ -e "$netdir/${port##*/}/device" ]; then iface=${port##*/}; break; fi
  done
fi
rx=; tx=
if [ -n "$iface" ] && [ -r "$netdir/$iface/statistics/rx_bytes" ]; then
  rx=$(cat "$netdir/$iface/statistics/rx_bytes"); tx=$(cat "$netdir/$iface/statistics/tx_bytes")
fi
cpu=$(awk '$1 == "cpu" { t = 0; for (i = 2; i <= NF; i++) t += $i; print t, $5 + $6; exit }' "$proc/stat" 2>/dev/null)
mem=$(awk '$1 == "MemTotal:" { t = $2 } $1 == "MemAvailable:" { a = $2 } END { if (t) print t * 1024, a * 1024 }' "$proc/meminfo" 2>/dev/null)
load=$(awk '{ print $1, $2, $3 }' "$proc/loadavg" 2>/dev/null)
up=$(awk '{ print int($1) }' "$proc/uptime" 2>/dev/null)

# --- problems: the keys the health check listed the last time they changed (the same count as the login message)
problems=
if [ -r "$state/health.state" ]; then problems=$(tail -n +2 "$state/health.state" | grep -c . || true); fi
locked=false
[ -e "${HS_LOCKED_MARKER:-/run/hs/storage-locked}" ] && locked=true

# --- the graphics card (first line only; the memory comes in MiB)
gpu=$(head -n 1 "$tmp/gpu" 2>/dev/null)
gpu_util=$(printf '%s' "$gpu" | awk -F', *' 'NF >= 5 && $2 ~ /^[0-9]+$/ { print $2 }')

# --- the last 24 hours: add this reading (when asked to), then read the hours back
now=${HS_NOW:-$(date +%s)}
if [ "${HS_DECK_RECORD:-}" = 1 ]; then
  HS_STATE_DIR=$state DH_DIR=$DH_DIR bash "$here/state.sh" history-record "$now" "$rx" "$tx" "$(printf '%s' "$cpu" | cut -d' ' -f1)" "$(printf '%s' "$cpu" | cut -d' ' -f2)" \
    "$(printf '%s' "$mem" | cut -d' ' -f1)" "$(printf '%s' "$mem" | cut -d' ' -f2)" "$gpu_util" "$up" >/dev/null 2>&1 || true
fi
history=$(HS_STATE_DIR=$state DH_DIR=$DH_DIR bash "$here/state.sh" history "$now" 2>/dev/null | head -n 1)

# --- the disk inventory of the state database: disks that are missing or getting worse (null without a database; additive key)
inventory=$(HS_STATE_DIR=$state bash "$here/state.sh" inventory-json 2>/dev/null | head -n 1)

# --- the capabilities that are on (additive key `capabilities`: a list of names; the web interface builds the pages of a remote node from it)
caps=$( (. "$here/lib/capability.sh"; capability_list) 2>/dev/null </dev/null | tr '\n' ' ' || true)

# --- pools
fast=$(head -n 1 "$tmp/fast")
bulk=$(tail -n 1 "$tmp/bulk")

jq -n \
  --arg host "${HS_HOSTNAME:-$(hostname)}" --argjson now "${HS_NOW:-$(date +%s)}" \
  --arg iface "$iface" --arg rx "$rx" --arg tx "$tx" \
  --arg cpu "$cpu" --arg mem "$mem" --arg load "$load" --arg up "$up" \
  --arg problems "$problems" --argjson locked "$locked" --arg gpu "$gpu" --argjson history "${history:-null}" --argjson inventory "${inventory:-null}" \
  --arg fast "$fast" --arg bulk "$bulk" --arg caps "$caps" \
  --rawfile status "$tmp/status" --rawfile disks "$tmp/disks" '
  def num: if . == null or . == "" or . == "-" then null else (tonumber? // null) end;
  def parts: split(" ") | map(select(. != ""));
  ($status | split("\n") | map(select(. != "") | split("\t"))) as $s
  | def fact($k): [$s[] | select(.[0] == $k)] | first;
  (fact("backup")) as $b | (fact("smart")) as $sm | (fact("instances")) as $in | (fact("hottest")) as $ho | (fact("encryption")) as $en
  | ($fast | split("\t")) as $f | ($bulk | parts) as $bk
  | {
      schema: 1, kind: "homeserver", host: $host, time: $now,
      uptime_s: ($up | num),
      load: (if $load == "" then null else ($load | parts | map(tonumber)) end),
      cpu: (if $cpu == "" then null else ($cpu | parts | {total: (.[0] | tonumber), idle: (.[1] | tonumber)}) end),
      mem: (if $mem == "" then null else ($mem | parts | {total: (.[0] | tonumber), available: (.[1] | tonumber)}) end),
      net: (if $rx == "" then null else {iface: $iface, rx_bytes: ($rx | tonumber), tx_bytes: ($tx | tonumber)} end),
      pools: {
        fast: (if ($f | length) == 3 then {size: ($f[0] | num), used: ($f[1] | num), health: $f[2]} else null end),
        bulk: (if ($bk | length) == 2 then {size: ($bk[0] | num), used: ($bk[1] | num)} else null end)
      },
      gpu: (($gpu | split(",") | map(sub("^ +"; "") | sub(" +$"; ""))) as $g
            | if ($g | length) >= 5 and ($g[1] | test("^[0-9]+$")) then
                {name: ($g[0] | sub("^NVIDIA (GeForce )?"; "")), util: ($g[1] | num), mem_used: (($g[2] | num) * 1048576),
                 mem_total: (($g[3] | num) * 1048576), temp: ($g[4] | num)}
              else null end),
      history: $history,
      inventory: $inventory,
      capabilities: ($caps | parts),
      locked: $locked,
      encryption: ($en[1]? // null),
      problems: ($problems | num),
      backup: (if $b then {status: $b[1], age_s: ($b[2] | num)} else null end),
      smart: (if $sm then {disks: ($sm[1] | num), findings: (($sm[2] // "") | split(",") | map(select(. != "")))} else null end),
      instances: (if $in then {running: ($in[1] | num), total: ($in[2] | num)} else null end),
      hottest: (if $ho then {disk: $ho[1], temp: ($ho[2] | num)} else null end),
      disks: [$disks | split("\n")[] | select(. != "") | split("\t") | {name: .[0], bytes: (.[1] | num), kind: .[2], role: .[3], temp: (.[4] | num)}]
    }'
