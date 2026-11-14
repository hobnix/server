#!/usr/bin/env bash
# scripts/health-check.sh (ZFS part): a pool that is not imported and failed zfs-import-* / zfs-scrub units are reported. Stubbed zpool and systemctl, no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_HEALTH_STATE="$WORK/h.state" HS_ACK_FILE="$WORK/ack" HS_RUN_DIR="$WORK/run" HS_TEMP_ROOT="$WORK/t"
mkdir -p "$WORK/bin" "$WORK/run"
cat > "$WORK/bin/zpool" <<'S'
#!/bin/sh
case "$*" in
  "list -H -o name") echo fast ;;
  "status -x fast") echo "pool 'fast' is healthy" ;;
esac
exit 0
S
cat > "$WORK/bin/systemctl" <<'S'
#!/bin/sh
case "$1" in
  list-unit-files) printf 'zfs-import-fast.service enabled\nzfs-import-bulk.service enabled\n' ;;
  list-units) case "$*" in *zfs-import*) printf 'zfs-scrub-fast.service loaded failed failed Scrub\n' ;; esac ;;
  is-failed) [ "$3" = zfs-scrub-fast.service ] ;;
esac
exit 0
S
chmod +x "$WORK/bin/zpool" "$WORK/bin/systemctl"
export PATH="$WORK/bin:$PATH"
out=$(bash "$SCRIPTS/health-check.sh" --keys 2>&1 || true)
check_eq "a known pool missing from zpool list" "1" "$(grep -c '^zfs:bulk:missing$' <<<"$out")"
check_eq "an imported pool is not reported" "0" "$(grep -c '^zfs:fast:missing$' <<<"$out")"
check_eq "a failed zfs-scrub unit is reported" "1" "$(grep -c '^unit:zfs-scrub-fast.service$' <<<"$out")"
echo "-- pool rows: tank (data) and ssd (apps)"
export HS_MACHINE_FILE=$WORK/machine.toml
printf 'pools = { tank = { role = "data", kind = "zfs" }, ssd = { role = "apps", kind = "zfs" } }
' > "$HS_MACHINE_FILE"
cat > "$WORK/bin/zpool" <<'S'
#!/bin/sh
case "$*" in
  "list -H -o name") echo ssd ;;
  "status -x ssd") echo "pool 'ssd' is healthy" ;;
esac
exit 0
S
cat > "$WORK/bin/systemctl" <<'S'
#!/bin/sh
case "$1" in
  list-unit-files) printf 'zfs-import-ssd.service enabled
zfs-import-tank.service enabled
' ;;
esac
exit 0
S
out=$(bash "$SCRIPTS/health-check.sh" --keys 2>&1 || true)
check_eq "tank not imported: zfs:tank:missing" "1" "$(grep -c '^zfs:tank:missing$' <<<"$out")"
check_eq "ssd is fine, nothing named bulk" "0" "$(grep -c '^zfs:ssd:\|^bulk:' <<<"$out")"
printf 'pools = {}
' > "$HS_MACHINE_FILE"
out=$(bash "$SCRIPTS/health-check.sh" --keys 2>&1 || true)
check_eq "no pool row: no bulk key, no crash" "0" "$(grep -c '^bulk:' <<<"$out")"
rm -f "$HS_MACHINE_FILE"
finish
