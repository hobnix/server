#!/usr/bin/env bash
# hs health-check: the entries that depend on files and mounts, with fake state.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
need_root
export HS_RUN_DIR=$WORK/run HS_BACKUP_STATE=$WORK/backup.state HS_HEALTH_STATE=$WORK/h.state HS_TEMP_ROOT=$WORK/t HS_PLAIN=1
mkdir -p "$WORK/run" "$WORK/t/old" "$WORK/t/new"
hc() { bash "$SCRIPTS/health-check.sh" --dry-run 2>&1 || true; }

echo "-- storage locked"
out=$(hc); if grep -qi "locked" <<<"$out"; then fail "no locked warning without the marker"; else pass "no locked warning without the marker"; fi
touch "$WORK/run/storage-locked"
check_out "locked storage is reported" "hs unlock" hc
rm -f "$WORK/run/storage-locked"

echo "-- backup"
now=$(date +%s)
printf 'last_ok=%s\nstatus=ok\nused_pct=40\n' "$now" > "$WORK/backup.state"
out=$(hc); if grep -qi "backup" <<<"$out"; then fail "a fresh backup is fine"; else pass "a fresh backup is fine"; fi
printf 'last_ok=%s\nstatus=failed\nused_pct=40\n' "$now" > "$WORK/backup.state"
check_out "a failed run is reported" "errors" hc
printf 'last_ok=%s\nstatus=ok\nused_pct=90\n' "$now" > "$WORK/backup.state"
check_out "a full backup disk is reported" "90% full" hc

echo "-- a temp disk left mounted"
mount -t tmpfs t "$WORK/t/old"; mount -t tmpfs t "$WORK/t/new"
echo $((now - 3 * 86400)) > "$WORK/run/temp-old.since"; echo "$now" > "$WORK/run/temp-new.since"
out=$(hc)
check_out "the old one is reported" "temp disk old" echo "$out"
if grep -q "temp disk new" <<<"$out"; then fail "the fresh one is not"; else pass "the fresh one is not"; fi
umount "$WORK/t/old" "$WORK/t/new"

echo "-- restore drills"
printf 'last_ok=%s\nstatus=ok\nused_pct=40\nfirst_ok=%s\n' "$now" "$((now - 10 * 86400))" > "$WORK/backup.state"
out=$(hc); if grep -qi "drill" <<<"$out"; then fail "a young backup needs no drill yet"; else pass "a young backup needs no drill yet"; fi
printf 'last_ok=%s\nstatus=ok\nused_pct=40\nfirst_ok=%s\n' "$now" "$((now - 60 * 86400))" > "$WORK/backup.state"
check_out "no drill after 45 days is reported" "no restore drill has succeeded" hc
printf 'last_ok=%s\nstatus=ok\nused_pct=40\nfirst_ok=%s\ndrill_ok=%s\n' "$now" "$((now - 60 * 86400))" "$((now - 50 * 86400))" > "$WORK/backup.state"
check_out "an old drill is reported" "restore drill is 50 days old" hc
printf 'last_ok=%s\nstatus=ok\nused_pct=40\nfirst_ok=%s\ndrill_ok=%s\n' "$now" "$((now - 60 * 86400))" "$((now - 5 * 86400))" > "$WORK/backup.state"
out=$(hc); if grep -qi "drill" <<<"$out"; then fail "a recent drill is fine"; else pass "a recent drill is fine"; fi
printf 'last_ok=%s\nstatus=ok\nused_pct=40\nfirst_ok=%s\ndrill_ok=%s\ndrill_ct_ok=%s\n' "$now" "$((now - 200 * 86400))" "$((now - 5 * 86400))" "$((now - 100 * 86400))" > "$WORK/backup.state"
check_out "an old container drill is reported" "container restore drill is 100 days old" hc
printf 'last_ok=%s\nstatus=ok\nused_pct=40\nfirst_ok=%s\ndrill_ok=%s\ndrill_ct_ok=%s\n' "$now" "$((now - 200 * 86400))" "$((now - 5 * 86400))" "$((now - 40 * 86400))" > "$WORK/backup.state"
out=$(hc); if grep -qi "container restore drill" <<<"$out"; then fail "a container drill of 40 days is fine"; else pass "a container drill of 40 days is fine"; fi
printf 'last_ok=%s\nstatus=ok\nused_pct=40\nfirst_ok=%s\ndrill_ok=%s\n' "$now" "$((now - 200 * 86400))" "$((now - 5 * 86400))" > "$WORK/backup.state"
out=$(hc); if grep -qi "container restore drill" <<<"$out"; then fail "no container drill ever is not reported"; else pass "no container drill ever is not reported"; fi

echo "-- disk self-tests"
cat > "$WORK/dh.sh" <<'FAKE'
#!/usr/bin/env bash
printf 'sda\t1T\tHDD\tIronWolf\tOK\t100\t\nsdb\t1T\tHDD\tWD Red\tBAD\t9000\tlast self-test failed\n'
FAKE
export HS_DISK_HEALTH=$WORK/dh.sh HS_SELFTEST_STATE=$WORK/selftest.state
check_out "a disk rated BAD is reported" "disk sdb \(WD Red\) is rated BAD: last self-test failed" hc
printf 'short=%s\nlong=%s\n' "$now" "$now" > "$WORK/selftest.state"
out=$(hc); if grep -qi "self-test for" <<<"$out"; then fail "fresh self-tests are fine"; else pass "fresh self-tests are fine"; fi
printf 'short=%s\nlong=%s\n' "$((now - 20 * 86400))" "$((now - 50 * 86400))" > "$WORK/selftest.state"
check_out "a stopped short schedule is reported" "no short disk self-test for 20 days" hc
check_out "a stopped long schedule is reported" "no long disk self-test for 50 days" hc
unset HS_DISK_HEALTH HS_SELFTEST_STATE

echo "-- expiry list and configuration drift (more in tests/expiry.sh and tests/update-rollback.sh)"
export HS_STATE_DIR=$WORK/hsstate HS_REPO=$WORK/norepo HS_EXPIRY_TODAY=2026-10-11
mkdir -p "$HS_STATE_DIR"
out=$(hc); if grep -q "runs out" <<<"$out"; then fail "no expiry list, no problem"; else pass "no expiry list, no problem"; fi
printf 'token\t2026-10-20\tnew token\ncert\t2030-01-01\t\n' > "$HS_STATE_DIR/expiry"
check_out "an entry 9 days away is reported" "token runs out on 2026-10-20 \(in 9 days\)" hc
out=$(hc); if grep -q "cert runs out" <<<"$out"; then fail "a far entry is fine"; else pass "a far entry is fine"; fi
unset HS_STATE_DIR HS_REPO HS_EXPIRY_TODAY

echo "-- scrubs"
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/zpool" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  list) echo tank ;;
  status) if [ "${2:-}" = -x ]; then echo "pool 'tank' is healthy"; else echo "  scan: $FAKE_SCAN"; fi ;;
  get) echo "${FAKE_CREATED:-0}" ;;
esac
FAKE
chmod +x "$WORK/fakebin/zpool"
old_path=$PATH; export PATH=$WORK/fakebin:$PATH
recent=$(date -d "2 days ago" "+%a %b %e %H:%M:%S %Y")
stale=$(date -d "40 days ago" "+%a %b %e %H:%M:%S %Y")
export FAKE_SCAN="scrub repaired 0B in 00:10:02 with 0 errors on $recent"
out=$(hc); if grep -qi "scrub" <<<"$out"; then fail "a recent clean scrub is fine"; else pass "a recent clean scrub is fine"; fi
export FAKE_SCAN="scrub repaired 4K in 00:10:02 with 3 errors on $recent"
check_out "a scrub with errors is reported" "found 3 error" hc
export FAKE_SCAN="scrub repaired 0B in 00:10:02 with 0 errors on $stale"
check_out "an old scrub is reported" "finished 40 days ago" hc
export FAKE_SCAN="none requested" FAKE_CREATED=$((now - 90 * 86400))
check_out "a pool that never scrubbed is reported" "never finished a scrub" hc
export PATH=$old_path; unset FAKE_SCAN FAKE_CREATED

finish
