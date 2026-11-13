#!/usr/bin/env bash
# help: the network check as data: link, wireless, address, route, DNS and clock, each ok, warn or fail
# help.de: die Netzwerkprüfung als Daten: Verbindung, WLAN, Adresse, Route, DNS und Uhr, je ok, warn oder fail
# args: --list
# System command (hs sys net check), read only, for the Network step of the first-run wizard (issue #179). Six rows in a fixed order, tab separated, an empty
# field is -: item (link|wireless|address|route|dns|clock), state (ok|warn|fail), value, fix (a short sentence). Exit 1 when a row is fail (the rows are
# still printed). The same check runs in hs-install (lib/netcheck.sh).
# Test knobs: fake ip and getent on PATH, HS_SYS_NET, HS_NETCHECK_NOW, HS_NETCHECK_HOST.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/netcheck.sh"

[ "${1:-}" = --list ] && [ $# -eq 1 ] || { echo "usage: net-check.sh --list" >&2; exit 1; }
rows=$(netcheck_rows)
printf '%s\n' "$rows"
! printf '%s\n' "$rows" | awk -F'\t' '$2 == "fail" { f = 1 } END { exit !f }' || exit 1
