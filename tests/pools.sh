#!/usr/bin/env bash
# scripts/lib/pools.sh: the pool rows of machine.toml, the legacy fallback (no `pools` line), `pools = {}` (no pool), the name rule.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
T=$'\t'
export HS_MACHINE_FILE=$WORK/machine.toml HS_BULK_TYPE_FILE=$WORK/bulk-type HS_POOLS_ROOT=$WORK/root
mkdir -p "$HS_POOLS_ROOT"

# run <snippet>: a fresh shell each time (the rows are cached per process)
run() { bash -c '. "$1/scripts/lib/pools.sh"; shift; eval "$*"' _ "$ROOT" "$@"; }
# fails <snippet>: the snippet must exit non-zero
fails() { ! run "$@"; }

# 1. no machine.toml: legacy zfs
rm -f "$HS_MACHINE_FILE" "$HS_BULK_TYPE_FILE"
check_eq "no file: legacy rows" "bulk${T}data${T}zfs
fast${T}apps${T}zfs" "$(run pools_rows)"
check_eq "no file: source legacy" legacy "$(run pools_source)"

# 2. bulkType in machine.toml
printf 'bulkType = "snapraid"\n' >"$HS_MACHINE_FILE"
check_eq "bulkType snapraid" "bulk${T}data${T}snapraid
fast${T}apps${T}zfs" "$(run pools_rows)"
check_eq "bulkType: source legacy" legacy "$(run pools_source)"

# 3. no file, bulk-type file
rm -f "$HS_MACHINE_FILE"
printf 'snapraid\n' >"$HS_BULK_TYPE_FILE"
check_eq "bulk-type file snapraid" "bulk${T}data${T}snapraid" "$(run pools_rows | head -n1)"

# 4. three pools
rm -f "$HS_BULK_TYPE_FILE"
printf 'pools = { tank = { role = "data", kind = "zfs" }, ssd = { role = "apps", kind = "zfs" }, media = { role = "data", kind = "snapraid" } }\n' >"$HS_MACHINE_FILE"
check_eq "three rows sorted" "media${T}data${T}snapraid
ssd${T}apps${T}zfs
tank${T}data${T}zfs" "$(run pools_rows)"
check_eq "pool_default data" media "$(run 'pool_default data')"
check_eq "pool_default apps" ssd "$(run 'pool_default apps')"
check_eq "pool_kind tank" zfs "$(run 'pool_kind tank')"
check_eq "pool_role media" data "$(run 'pool_role media')"
check_eq "pool_names data" "media
tank" "$(run 'pool_names data')"
check "pool_exists tank" run 'pool_exists tank'
check "pool_exists bulk fails" fails 'pool_exists bulk'
check_eq "config: source config" config "$(run pools_source)"

# 5. pools = {}: no pool, not legacy
printf 'pools = {}\n' >"$HS_MACHINE_FILE"
check_eq "empty table: no rows" "" "$(run pools_rows)"
check_eq "empty table: no names" "" "$(run pool_names)"
check_eq "empty table: source config" config "$(run pools_source)"
check "empty table: pool_names exits 0" run pool_names
check "empty table: pool_default data fails" fails 'pool_default data'
check "empty table: pool_exists fast fails" fails 'pool_exists fast'

# 6. a row with an unknown role or kind is skipped
printf 'pools = { tank = { role = "data", kind = "zfs" }, odd = { role = "x", kind = "zfs" }, odd2 = { role = "data", kind = "ext4" }, odd3 = { role = "data" } }\n' >"$HS_MACHINE_FILE"
check_eq "bad rows skipped" "tank${T}data${T}zfs" "$(run pools_rows)"

# 7. root and mount point (stand-ins for mountpoint)
printf '#!/bin/sh\nexit 0\n' >"$WORK/mp-yes"; printf '#!/bin/sh\nexit 1\n' >"$WORK/mp-no"; chmod +x "$WORK/mp-yes" "$WORK/mp-no"
check_eq "pool_root" "$WORK/root/tank" "$(run 'pool_root tank')"
check "pool_mounted yes" env HS_MOUNTPOINT="$WORK/mp-yes" bash -c '. "$1/scripts/lib/pools.sh"; pool_mounted tank' _ "$ROOT"
check "pool_mounted no" env HS_MOUNTPOINT="$WORK/mp-no" bash -c '. "$1/scripts/lib/pools.sh"; ! pool_mounted tank' _ "$ROOT"

# 8. name rule
for n in tank a1 abcdefghijkl; do check "name ok: $n" run "pool_name_ok $n"; done
for n in Tank 1a mirror nix abcdefghijklm 'a/b' ''; do
  check "name refused: '$n'" fails "pool_name_ok '$n'"
done

# 9. every row has 3 fields, none empty
printf 'pools = { tank = { role = "data", kind = "zfs" }, ssd = { role = "apps", kind = "zfs" } }\n' >"$HS_MACHINE_FILE"
check_eq "rows have 3 non-empty fields" "" "$(run pools_rows | awk -F'\t' 'NF != 3 || $1 == "" || $2 == "" || $3 == ""')"

# 10. pools_add_row: needs a pools line, one line out, sorted, overwrites, clears the cache
rm -f "$HS_MACHINE_FILE"
check "add_row without a pools line fails (legacy)" fails 'pools_add_row tank data zfs'
printf 'bulkType = "zfs"\n' >"$HS_MACHINE_FILE"
check "add_row without a pools line fails (machine.toml without it)" fails 'pools_add_row tank data zfs'
printf 'pools = { fast = { role = "apps", kind = "zfs" } }\n' >"$HS_MACHINE_FILE"
check "add_row writes" run 'pools_add_row tank data zfs'
check_eq "rows sorted, new one in" "fast${T}apps${T}zfs
tank${T}data${T}zfs" "$(run pools_rows)"
check_eq "one pools line" "1" "$(grep -c '^pools' "$HS_MACHINE_FILE")"
check "add_row overwrites a row" run 'pools_add_row tank apps zfs'
check_eq "role changed, no duplicate" "tank${T}apps${T}zfs" "$(run pools_rows | grep tank)"
check_eq "the cache is cleared in the same process" "data" "$(run 'pools_add_row aaa data zfs; pool_role aaa')"
check "bad role refused" fails 'pools_add_row x1 other zfs'
check "bad kind refused" fails 'pools_add_row x1 data ext4'
check "bad name refused" fails 'pools_add_row Mirror data zfs'

finish
