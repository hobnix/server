#!/usr/bin/env bash
# scripts/pool-record.sh (hs pool record): the pools line from what exists; refusals change nothing; the typed word; pools.sh reads the result.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
T=$'\t'
B=$WORK/bin; mkdir -p "$B"
export HS_MACHINE_FILE=$WORK/machine.toml HS_BULK_TYPE_FILE=$WORK/bulk-type HS_STATE_DIR=$WORK/state HS_POOLS_ROOT=$WORK/root
export HS_ZPOOL=$B/zpool HS_INCUS=$B/incus HS_LSBLK=$B/lsblk HS_GUIDED_TTY=1
cat > "$B/zpool" <<'FAKE'
#!/usr/bin/env bash
cat "$(dirname "$0")/zpools" 2>/dev/null
FAKE
cat > "$B/incus" <<'FAKE'
#!/usr/bin/env bash
cat "$(dirname "$0")/source" 2>/dev/null
FAKE
cat > "$B/lsblk" <<'FAKE'
#!/usr/bin/env bash
cat "$(dirname "$0")/labels" 2>/dev/null
FAKE
chmod +x "$B/zpool" "$B/incus" "$B/lsblk"
R=$ROOT/scripts/pool-record.sh

reset() {
  printf 'language = "en"\n' > "$HS_MACHINE_FILE"
  rm -f "$HS_BULK_TYPE_FILE" "$B/zpools" "$B/source" "$B/labels"
}

echo "-- two zfs pools, one apps"
reset
printf 'tank\nssd\n' > "$B/zpools"; echo "ssd/incus" > "$B/source"
want='pools = { ssd = { role = "apps", kind = "zfs" }, tank = { role = "data", kind = "zfs" } }'
check_eq "dry run prints the line only" "$want" "$(bash "$R" --dry-run 2>&1)"
check_eq "--list the same" "$want" "$(bash "$R" --list 2>&1)"
check_eq "dry run changes nothing" 0 "$(grep -c '^pools' "$HS_MACHINE_FILE")"
check_eq "wrong typed word: refused" 1 "$(echo nope | bash "$R" >/dev/null 2>&1; echo $(( $? )))"
check_eq "wrong typed word: nothing written" 0 "$(grep -c '^pools' "$HS_MACHINE_FILE")"
check_eq "no terminal, no --yes: refused" 1 "$(HS_GUIDED_TTY= bash "$R" </dev/null >/dev/null 2>&1; echo $?)"
check_eq "no terminal, no --yes: nothing written" 0 "$(grep -c '^pools' "$HS_MACHINE_FILE")"
check_eq "typed word: written" 0 "$(echo pools | bash "$R" >/dev/null 2>&1; echo $?)"
check_eq "the line is in machine.toml" 1 "$(grep -cxF "$want" "$HS_MACHINE_FILE")"
check_eq "pools.sh reads the rows" "ssd${T}apps${T}zfs
tank${T}data${T}zfs" "$(bash -c '. "$1/scripts/lib/pools.sh"; pools_rows' _ "$ROOT")"
check_eq "language line stays" 1 "$(grep -c '^language' "$HS_MACHINE_FILE")"

echo "-- already set"
before=$(cat "$HS_MACHINE_FILE")
check_out "refuses with a note" "already has a pools line" bash "$R" --yes
check_eq "file unchanged" "$before" "$(cat "$HS_MACHINE_FILE")"

echo "-- snapraid and a zfs apps pool"
reset
printf 'ssd\n' > "$B/zpools"; echo "ssd/incus" > "$B/source"; echo snapraid > "$HS_BULK_TYPE_FILE"
snapname=$(bash -c '. "$1/scripts/lib/pools.sh"; pool_names data' _ "$ROOT")
want="pools = { $snapname = { role = \"data\", kind = \"snapraid\" }, ssd = { role = \"apps\", kind = \"zfs\" } }"
check_eq "line with the snapraid row" "$want" "$(bash "$R" --dry-run 2>&1)"
check_eq "--yes writes it" 0 "$(bash "$R" --yes >/dev/null 2>&1; echo $?)"
check_eq "written" 1 "$(grep -cxF "$want" "$HS_MACHINE_FILE")"

echo "-- snapraid known from the labels only"
reset
printf 'bulk-data-01\n' > "$B/labels"
check_eq "labels give the row" "pools = { $snapname = { role = \"data\", kind = \"snapraid\" } }" "$(bash "$R" --dry-run 2>&1)"

echo "-- a zfs pool with the name of the snapraid pool"
reset
echo snapraid > "$HS_BULK_TYPE_FILE"; printf '%s\n' "$snapname" > "$B/zpools"
before=$(cat "$HS_MACHINE_FILE")
check_eq "refuses" 1 "$(bash "$R" --yes >/dev/null 2>&1; echo $?)"
check_eq "file unchanged" "$before" "$(cat "$HS_MACHINE_FILE")"

echo "-- a bad name"
reset
printf 'tank\nBad-Pool\n' > "$B/zpools"
before=$(cat "$HS_MACHINE_FILE")
check_out "names the pool" "Bad-Pool" bash "$R" --yes
check_eq "refuses" 1 "$(bash "$R" --yes >/dev/null 2>&1; echo $?)"
check_eq "file unchanged" "$before" "$(cat "$HS_MACHINE_FILE")"

echo "-- nothing found"
reset
check_eq "no pool: nothing written" 0 "$(bash "$R" --yes >/dev/null 2>&1; grep -c '^pools' "$HS_MACHINE_FILE")"

finish
