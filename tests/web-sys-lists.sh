#!/usr/bin/env bash
# hs sys expiry list / hs sys ext games list: the machine-readable rows the web interface reads. No root needed.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=ui HS_STATE_DIR=$WORK/state HS_EXPIRY_TODAY=2026-10-11
mkdir -p "$HS_STATE_DIR"

echo "-- registry rows"
reg=$SCRIPTS/lib/registry.tsv
check "sys expiry list row" grep -q "^sys.sys expiry list.expiry.sh.--list." "$reg"
check "sys ext games list row (the package games)" grep -q "^sys.sys ext games list.@/pc.sh.--list." "$ROOT/capabilities/games/commands.tsv"

echo "-- pc --list"
check_eq "no PC, no rows" "" "$(bash "$ROOT/capabilities/games/pc.sh" --list)"
bash "$ROOT/capabilities/games/pc.sh" add gaming AA:BB:CC:DD:EE:FF 10.10.95.30 >/dev/null
bash "$ROOT/capabilities/games/pc.sh" add laptop 11-22-33-44-55-66 >/dev/null
l=$(bash "$ROOT/capabilities/games/pc.sh" --list)
check_eq "name, mac, address" "$(printf 'gaming\taa:bb:cc:dd:ee:ff\t10.10.95.30')" "$(sed -n 1p <<<"$l")"
check_eq "no address is a dash" "$(printf 'laptop\t11:22:33:44:55:66\t-')" "$(sed -n 2p <<<"$l")"
check_eq "two rows, no header" 2 "$(wc -l <<<"$l" | tr -d ' ')"
check_out "the people's list is unchanged" "Address" bash "$ROOT/capabilities/games/pc.sh" list

echo "-- expiry --list"
check_eq "no entry, no rows" "" "$(bash "$SCRIPTS/expiry.sh" --list)"
bash "$SCRIPTS/expiry.sh" add domain 2026-11-30 "renew at the registrar" >/dev/null
bash "$SCRIPTS/expiry.sh" add old 2026-10-01 >/dev/null
l=$(bash "$SCRIPTS/expiry.sh" --list)
check_eq "name, date, days, state, how" "$(printf 'domain\t2026-11-30\t50\tok\trenew at the registrar')" "$(sed -n 1p <<<"$l")"
check_eq "expired has negative days" "$(printf 'old\t2026-10-01\t-10\texpired\t')" "$(sed -n 2p <<<"$l")"

finish
