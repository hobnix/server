#!/usr/bin/env bash
# hs sys disk plan|start (scripts/disk-change.sh): self-tests of a disk. A fake disk-health.sh stands in: no root, no smartctl.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en
unset HS_CALLER HS_GUIDED_TTY
cat > "$WORK/health" <<'FAKE'
#!/usr/bin/env bash
# disks: sda (idle), sdb (a test is running), sdc (refuses to start), sdd (in use)
printf '%s\n' "$*" >> "$(dirname "$0")/health-calls"
case "$1" in
  --test)
    kind=$2 disk=$3
    case "$disk" in
      sda|sdb|sdc|sdd|ata-WDC_WD40EFRX_WD-1234) ;;
      *) echo "No disk '$disk'. See the list: hs disk list"; exit 1 ;;
    esac
    if [ "${4:-}" = "--dry-run" ]; then
      [ "$disk" != sdd ] || echo "/dev/sdd is in use: the self-test runs inside the disk and does not change data, but it slows the disk while it runs."
      echo "Would run: smartctl -t $kind /dev/$disk"; exit 0
    fi
    if [ "$disk" = sdc ]; then echo "The self-test did not start (one may be running already)."; exit 1; fi
    echo "Started the $kind self-test on /dev/$disk." ;;
  --results)
    echo "Self-tests of /dev/$2"
    [ "$2" != sdb ] || echo "A test is running: Self-test routine in progress"
    echo "Short offline Completed without error at 21400 h" ;;
esac
FAKE
chmod +x "$WORK/health"
export HS_DISK_HEALTH=$WORK/health
run() { rc=0; out=$(timeout 20 bash "$SCRIPTS/disk-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }
T=$'\t'

echo "-- plan"
run plan test sda short
check_eq "short test: exit 0" 0 "$rc"
has "^status${T}ok$" && has "^heading${T}short self-test of sda$" && has "^command${T}smartctl -t short /dev/sda$" && has "^long${T}no$" && pass "short: status, heading, command, short" || fail "short: $out"
run plan test sda long
has "^long${T}yes$" && has "^note${T}A long test reads the whole surface" && pass "long: hours, says so" || fail "long: $out"
run plan test ata-WDC_WD40EFRX_WD-1234 short
check_eq "a by-id name is fine" 0 "$rc"
run plan test sdd short
has "^note${T}/dev/sdd is in use" && pass "a disk in use is noted" || fail "in use: $out"
check_eq "a disk in use is allowed" 0 "$rc"

echo "-- refusals"
run plan test sdb short
check_eq "a disk that is testing already" 1 "$rc"
has "^status${T}refused$" && has "^reason${T}A self-test is running in sdb already" && pass "says why" || fail "running: $out"
run plan test sdz short
check_eq "an unknown disk" 1 "$rc"
has "^reason${T}No disk 'sdz'" && pass "the reason of disk-health.sh" || fail "unknown: $out"
run plan test sda medium
check_eq "only short or long" 1 "$rc"
run plan test ../sda short
check_eq "no path tricks" 1 "$rc"
run plan test /dev/sda short
check_eq "no path" 1 "$rc"
run plan test --help short
check_eq "no option as a disk" 1 "$rc"
run plan test sda short extra
check_eq "no extra word" 1 "$rc"
run plan format sda short
check_eq "an unknown action" 1 "$rc"

echo "-- start"
rm -f "$WORK/health-calls"
run start test sda long
check_eq "start: exit 0" 0 "$rc"
check_eq "start is done at once" "status${T}done" "$out"
grep -qx -- "--test long sda" "$WORK/health-calls" && pass "disk-health.sh --test long sda was called" || fail "calls: $(cat "$WORK/health-calls")"
rm -f "$WORK/health-calls"
run start test sdb short
check_eq "start on a testing disk is refused" 1 "$rc"
grep -qx -- "--test short sdb" "$WORK/health-calls" && fail "the test was started anyway" || pass "nothing was started"
run start test sdc short
check_eq "a failing start is refused" 1 "$rc"
has "^reason${T}The self-test did not start" && pass "with the reason" || fail "sdc: $out"
run start test sdz short
check_eq "start on an unknown disk" 1 "$rc"

finish
