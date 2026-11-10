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
finish
