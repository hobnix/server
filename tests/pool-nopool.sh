#!/usr/bin/env bash
# A server whose pool rows have no pool of the needed role: hs doctor and hs motd say so, hs share add and the upload cache refuse.
# A server without a `pools` line has the legacy rows and sees none of it. Fake zfs/incus/net on PATH: no root, no ZFS.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 TZ=UTC HS_BULK=$WORK/bulk HS_FAST=$WORK/fast HS_STATE_DIR=$WORK/state HS_LOGIN_MESSAGE=$WORK/login HS_LOCKED_MARKER=$WORK/locked
unset HS_CALLER HS_GUIDED_TTY
BIN=$WORK/bin; D=$WORK/scripts; mkdir -p "$BIN" "$D/lib" "$HS_BULK/shares" "$HS_STATE_DIR"
cp "$SCRIPTS"/*.sh "$SCRIPTS"/machine-toml.py "$D/" 2>/dev/null; cp "$SCRIPTS"/lib/*.sh "$D/lib/"
for c in zfs incus net chown chmod mountpoint; do printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/$c"; done
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/chown"; cp "$BIN/chown" "$BIN/chmod"
cat > "$BIN/df" <<'FAKE'
#!/usr/bin/env bash
printf 'Use%%\n 40%%\n'
FAKE
printf '#!/usr/bin/env bash\nprintf "No problems found.\n\n"\n' > "$D/health-check.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$D/sync-shares.sh"
chmod +x "$BIN"/* "$D"/*.sh
export PATH=$BIN:$PATH
echo snapraid > "$WORK/bulk-type"; export HS_BULK_TYPE_FILE=$WORK/bulk-type
export HS_POOLS_ROOT=$WORK/root

printf 'pools = {}\n' > "$WORK/none.toml"
printf 'pools = { tank = { role = "data", kind = "zfs" } }\n' > "$WORK/noapps.toml"
printf 'pools = { tank = { role = "apps", kind = "zfs" } }\n' > "$WORK/nodata.toml"
export HS_MACHINE_FILE=$WORK/none.toml

echo "-- no pool at all"
check_out "doctor: the storage note" "Storage: no pool" bash "$D/doctor.sh"
check_out "doctor: what is missing" "a pool for shares, redundancy, encryption of data" bash "$D/doctor.sh"
check_out "doctor: the command" "hs storage discover, then: hs pool <name> add" bash "$D/doctor.sh"
check_eq "doctor: exit status stays 0" "0" "$(bash "$D/doctor.sh" >/dev/null 2>&1; echo $?)"
check_out "motd: one note line" "No storage pool yet: apps on the system disk, no shares\. hs storage discover" bash "$D/motd.sh"
check_out "share add refuses" "Shares need a pool, and this server has none\. Add one: hs pool <name> add" bash "$D/create-share.sh" photos
check_out "share add --fast refuses with the same message" "Shares need a pool" bash "$D/create-share.sh" photos --fast
check_eq "share add exits 1" "1" "$(bash "$D/create-share.sh" photos >/dev/null 2>&1; echo $?)"
[ ! -e "$HS_BULK/shares/photos" ] && pass "nothing was created" || fail "nothing was created"
check_out "cache on names both" "this server has neither" bash "$D/share-cache.sh" photos on

echo "-- a data pool, no SSD pool"
export HS_MACHINE_FILE=$WORK/noapps.toml
check_out "doctor: no SSD pool" "No SSD pool: apps run on the system disk \(no redundancy\)" bash "$D/doctor.sh"
if bash "$D/doctor.sh" 2>&1 | grep -q "Storage: no pool"; then fail "doctor: not the no-pool block"; else pass "doctor: not the no-pool block"; fi
check_eq "doctor: exit status stays 0" "0" "$(bash "$D/doctor.sh" >/dev/null 2>&1; echo $?)"
if bash "$D/motd.sh" 2>&1 | grep -q "No storage pool yet"; then fail "motd: quiet"; else pass "motd: quiet"; fi
check_out "share add --fast refuses, names the data pool" "There is no SSD pool \(role apps\)\. Leave out --fast to put the share on tank\." bash "$D/create-share.sh" photos --fast
check_out "cache on: no SSD pool" "this server has no SSD pool" bash "$D/share-cache.sh" photos on

echo "-- an SSD pool, no data pool"
export HS_MACHINE_FILE=$WORK/nodata.toml
check_out "doctor: no no-SSD note" "Storage: Unlocked" bash "$D/doctor.sh"
check_out "share add refuses" "Shares need a pool" bash "$D/create-share.sh" photos
check_out "cache on: no SnapRAID pool" "this server has no SnapRAID pool" bash "$D/share-cache.sh" photos on

echo "-- legacy (no machine file): nothing new"
export HS_MACHINE_FILE=$WORK/absent.toml
for s in doctor motd; do
  if bash "$D/$s.sh" 2>&1 | grep -qE "no pool|No SSD pool|No storage pool"; then fail "$s: silent for the legacy rows"; else pass "$s: silent for the legacy rows"; fi
done
if bash "$D/create-share.sh" photos 2>&1 | grep -qE "Shares need a pool|no SSD pool"; then fail "share add: no refusal"; else pass "share add: no refusal"; fi
if bash "$D/create-share.sh" photos2 --fast 2>&1 | grep -qE "Shares need a pool|no SSD pool"; then fail "share add --fast: no refusal"; else pass "share add --fast: no refusal"; fi
if bash "$D/share-cache.sh" photos on 2>&1 | grep -q "upload cache needs"; then fail "cache on: no refusal"; else pass "cache on: no refusal"; fi

finish
