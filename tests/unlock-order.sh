#!/usr/bin/env bash
# The order in which `hs unlock` starts the units: everything except Samba, then the instances (the domain controller is one), then it
# WAITS for the domain controller, and only then Samba. winbind started first made every user lookup (sudo too) wait for an RPC timeout.
# Fake systemctl and incus, a probe that succeeds on the third try. No root, no network.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test
BIN=$WORK/bin; mkdir -p "$BIN"; LOG=$WORK/order.log
cat > "$BIN/systemctl" <<'FAKE'
#!/usr/bin/env bash
echo "systemctl $*" >> "$LOG"
FAKE
cat > "$BIN/incus" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  info) [ "${NO_DC:-}" != 1 ] ;;
  list) echo '10.10.95.40 (enp5s0)' ;;
esac
FAKE
cat > "$BIN/probe" <<'FAKE'
#!/usr/bin/env bash
n=$(( $(cat "$WORK/probe.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$WORK/probe.n"
echo "probe $1 try $n" >> "$LOG"
[ "$n" -ge "${PROBE_OK_AT:-3}" ]
FAKE
chmod +x "$BIN"/*
export PATH="$BIN:$PATH" LOG WORK
export HS_UNLOCK_UNITS=$WORK/units HS_INCUS=$BIN/incus HS_DC_PROBE=$BIN/probe HS_DC_SLEEP=0 HS_DC_WAIT=10 HS_TEST_START_UNITS=1
echo "zfs-mount.service incus.service samba-smbd.service samba-winbindd.service" > "$HS_UNLOCK_UNITS"
run() { : > "$LOG"; rm -f "$WORK/probe.n"; bash "$SCRIPTS/unlock.sh" >/dev/null 2>&1; }
line() { grep -n "$1" "$LOG" | head -n1 | cut -d: -f1; }

echo "-- the order"
run
check "the log has the steps" test -s "$LOG"
check "incus starts before its instances" test "$(line 'start incus.service')" -lt "$(line 'start incus-startup')"
check "the instances start before the wait" test "$(line 'start incus-startup')" -lt "$(line 'probe')"
check "the wait ends before samba-smbd starts" test "$(grep -n 'try 3' "$LOG" | head -n1 | cut -d: -f1)" -lt "$(line 'start samba-smbd')"
check "samba-smbd and winbindd both start, after the wait" test "$(line 'start samba-winbindd')" -gt "$(line 'try 3')"
check "the probe was repeated until it answered" test "$(grep -c '^probe' "$LOG")" -eq 3
check "the probe got the address of the instance" grep -q 'probe 10.10.95.40' "$LOG"

echo "-- the domain controller never answers: Samba starts anyway"
export PROBE_OK_AT=99 HS_DC_WAIT=4
run
check "all four probes tried" test "$(grep -c '^probe' "$LOG")" -eq 4
check "samba still starts" grep -q 'start samba-winbindd' "$LOG"
unset PROBE_OK_AT; export HS_DC_WAIT=10

echo "-- no domain controller on this server: nothing to wait for"
NO_DC=1 run
check "no probe at all" test "$(grep -c '^probe' "$LOG")" -eq 0
check "samba starts" grep -q 'start samba-smbd' "$LOG"

echo "-- no domain (no winbindd unit): no wait"
echo "zfs-mount.service incus.service samba-smbd.service" > "$HS_UNLOCK_UNITS"
run
check "no probe" test "$(grep -c '^probe' "$LOG")" -eq 0
check "samba-smbd still starts last" test "$(line 'start samba-smbd')" -gt "$(line 'start incus-startup')"
finish
