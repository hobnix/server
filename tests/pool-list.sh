#!/usr/bin/env bash
# scripts/pool-list.sh (hs sys pool list): name, role, kind, state per pool; read only. Fake zpool and mountpoint: no root, no ZFS.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
T=$'\t'
export HS_PLAIN=1 HS_LANG=en HS_MACHINE_FILE=$WORK/machine.toml HS_BULK_TYPE_FILE=$WORK/bulk-type HS_POOLS_ROOT=$WORK/root
export HS_LOCKED_MARKER=$WORK/locked HS_ZPOOL=$WORK/zpool HS_MOUNTPOINT=$WORK/mountpoint
mkdir -p "$HS_POOLS_ROOT"
# zpool list -H -o health <name>: the health is the content of $WORK/health-<name>; no file = no such pool
cat > "$WORK/zpool" <<'FAKE'
#!/usr/bin/env bash
f="$WORK/health-${!#}"
[ -e "$f" ] && cat "$f"
FAKE
# mountpoint -q <dir>: a mount point when <dir>.mounted exists
cat > "$WORK/mountpoint" <<'FAKE'
#!/usr/bin/env bash
[ -e "$2.mounted" ]
FAKE
chmod +x "$WORK/zpool" "$WORK/mountpoint"
export WORK
S="bash $SCRIPTS/pool-list.sh"
mounted() { for p in "$@"; do : > "$HS_POOLS_ROOT/$p.mounted"; done; }

echo "-- legacy: no machine file"
rm -f "$HS_MACHINE_FILE" "$HS_BULK_TYPE_FILE"
echo ONLINE > "$WORK/health-bulk"; echo DEGRADED > "$WORK/health-fast"
mounted bulk fast
check_eq "legacy: bulk online, fast degraded" "bulk${T}data${T}zfs${T}online
fast${T}apps${T}zfs${T}degraded" "$($S)"
rm -f "$WORK/health-fast"
check_eq "legacy: fast missing" "fast${T}apps${T}zfs${T}missing" "$($S | grep '^fast')"

echo "-- pools = {}"
printf 'pools = {}\n' > "$HS_MACHINE_FILE"
check_eq "no pool: no output" "" "$($S)"
check "no pool: exit 0" $S

echo "-- tank and ssd"
printf 'pools = { tank = { role = "data", kind = "zfs" }, ssd = { role = "apps", kind = "zfs" }, snap = { role = "data", kind = "snapraid" } }\n' > "$HS_MACHINE_FILE"
rm -f "$HS_POOLS_ROOT"/*.mounted "$WORK"/health-*
echo ONLINE > "$WORK/health-tank"; echo DEGRADED > "$WORK/health-ssd"
mounted tank ssd
check_eq "online, degraded, snapraid unmounted" "snap${T}data${T}snapraid${T}unmounted
ssd${T}apps${T}zfs${T}degraded
tank${T}data${T}zfs${T}online" "$($S)"
mounted snap
check_eq "snapraid mounted: online" "snap${T}data${T}snapraid${T}online" "$($S | grep '^snap')"
rm -f "$WORK/health-ssd"
check_eq "zpool does not know ssd: missing" "ssd${T}apps${T}zfs${T}missing" "$($S | grep '^ssd')"
echo ONLINE > "$WORK/health-ssd"; rm -f "$HS_POOLS_ROOT/tank.mounted"
check_eq "online but not mounted: unmounted" "tank${T}data${T}zfs${T}unmounted" "$($S | grep '^tank')"
mounted tank

echo "-- locked"
: > "$HS_LOCKED_MARKER"
check_eq "locked marker: every pool locked" "locked" "$($S | cut -f4 | sort -u)"
rm -f "$HS_LOCKED_MARKER"

echo "-- shape"
bad=$($S | awk -F'\t' 'NF != 4 || $1 == "" || $2 == "" || $3 == "" || $4 == ""' | wc -l | tr -d ' ')
check_eq "every line has 4 non-empty fields" 0 "$bad"
