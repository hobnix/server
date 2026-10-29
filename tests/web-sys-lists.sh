#!/usr/bin/env bash
# hs sys expiry list: the machine-readable rows the web interface reads. No root needed.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=ui HS_STATE_DIR=$WORK/state HS_EXPIRY_TODAY=2026-10-11
mkdir -p "$HS_STATE_DIR"

echo "-- registry rows"
reg=$SCRIPTS/lib/registry.tsv
check "sys expiry list row" grep -q "^sys.sys expiry list.expiry.sh.--list." "$reg"

echo "-- expiry --list"
check_eq "no entry, no rows" "" "$(bash "$SCRIPTS/expiry.sh" --list)"
bash "$SCRIPTS/expiry.sh" add domain 2026-11-30 "renew at the registrar" >/dev/null
bash "$SCRIPTS/expiry.sh" add old 2026-10-01 >/dev/null
l=$(bash "$SCRIPTS/expiry.sh" --list)
check_eq "name, date, days, state, how" "$(printf 'domain\t2026-11-30\t50\tok\trenew at the registrar')" "$(sed -n 1p <<<"$l")"
check_eq "expired has negative days" "$(printf 'old\t2026-10-01\t-10\texpired\t')" "$(sed -n 2p <<<"$l")"

finish
