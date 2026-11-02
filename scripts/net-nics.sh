#!/usr/bin/env bash
# help: the physical network cards of this server as data: name, link, MAC, current
# help.de: die physischen Netzwerkkarten dieses Servers als Daten: Name, Verbindung, MAC, aktuell
# args: --list
# System command (hs sys net nics), read only, for the Network wizard of the web interface. One physical card per line, tab separated, no empty
# field (- = none): name, link (up = a cable is connected, down), MAC address or -, current (yes = the `nic` of machine.toml, else no). The current
# card comes first, the others are sorted by name. A card that machine.toml names and the server does not have is not listed.
# Test knobs: HS_SYS_NET (a fake /sys/class/net), HS_MACHINE_FILE.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/machine.sh"
. "$here/lib/nic.sh"

[ "${1:-}" = --list ] && [ $# -eq 1 ] || { echo "usage: net-nics.sh --list" >&2; exit 1; }

cur=$(machine_get nic 2>/dev/null || true)
rows=""
while IFS= read -r n; do
  [ -n "$n" ] || continue
  mac=$(cat "$(nic_net_dir)/$n/address" 2>/dev/null || true)
  [ -n "$mac" ] || mac=-
  is=no; first=1
  if [ "$n" = "$cur" ]; then is=yes; first=0; fi
  rows="$rows$first	$n	$(nic_link "$n")	$mac	$is"$'\n'
done < <(nic_list)
[ -z "$rows" ] || printf '%s' "$rows" | sort -t "$(printf '\t')" -k1,1n -k2,2 | cut -f2-
