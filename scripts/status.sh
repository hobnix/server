#!/usr/bin/env bash
# help: list containers with state, IPv4 and whether the MAC is pinned
# help.de: zeigt Container mit Zustand, IPv4 und ob die MAC festgenagelt ist
set -euo pipefail
. "$(dirname "$0")/lib/ui.sh"

rows=$(incus list -f json | jq -r --arg np "$(_tr 'not pinned')" '
  .[] | [
    .name,
    .status,
    # containers name the NIC eth0, VMs enp5s0
    (((.state.network // {}) | (.eth0 // .enp5s0 // {}) | .addresses // [])
       | map(select(.family == "inet")) | .[0].address // "-"),
    # once pinned, the MAC is on the device
    (.expanded_devices.eth0.hwaddr // $np)
  ] | @tsv')
total=$(grep -c . <<<"$rows" || true)
up=$(awk -F'	' 'toupper($2) == "RUNNING"' <<<"$rows" | grep -c . || true)
if [ "$total" -eq 0 ]; then status_line "Containers" "None" warn
elif [ "$up" -eq "$total" ]; then status_line "Containers" "$(t 'All %s running' "$total")" ok
else status_line "Containers" "$(t '%s of %s running' "$up" "$total")" warn; fi
{ thead 'Name' 'State' 'IPv4' 'MAC'; [ -z "$rows" ] || printf '%s
' "$rows"; } | table
