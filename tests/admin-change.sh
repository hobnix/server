#!/usr/bin/env bash
# hs sys admin plan|start (scripts/admin-change.sh): test push, pin MACs, upload cache, fan cleaning. Stand-ins for the scripts, a fake hwmon
# folder and a fake job runner: no root, no hardware.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en
unset HS_CALLER HS_GUIDED_TTY
T=$'\t'
CALLS=$WORK/calls; : > "$CALLS"
export HS_STATE_DIR=$WORK/state HS_SETTINGS_DIR=$WORK/settings; mkdir -p "$HS_STATE_DIR" "$HS_SETTINGS_DIR"
for n in health mac cache-mover fans; do printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n' "$n" "$CALLS" > "$WORK/$n-stub.sh"; done
export HS_HEALTH=$WORK/health-stub.sh HS_MAC=$WORK/mac-stub.sh HS_CACHE_MOVER=$WORK/cache-mover-stub.sh HS_FANS=$WORK/fans-stub.sh
# a stand-in for the job runner: the command is written down instead of started
mkdir -p "$WORK/lib"; cp "$SCRIPTS/lib/setting.sh" "$WORK/lib/"
printf 'hs_job() { shift 3; echo "JOB $*" >> "%s"; echo hs-job-test-1; }\n' "$CALLS" > "$WORK/lib/job.sh"
cp "$SCRIPTS/admin-change.sh" "$WORK/admin-change.sh"
run() { rc=0; out=$(timeout 20 bash "$WORK/admin-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }

echo "-- test push"
export HS_NOTIFY_FILE=$WORK/none
run plan test-push;  check_eq "no push address: refused" 1 "$rc"; has "notifyUrl" && pass "points at notifyUrl" || fail "$out"
echo "https://ntfy.sh/x" > "$WORK/notify-url"; export HS_NOTIFY_FILE=$WORK/notify-url
run plan test-push;  check_eq "plan: exit 0" 0 "$rc"
run start test-push; check_eq "start: exit 0" 0 "$rc"; has "^status${T}done" && pass "done" || fail "$out"
grep -qx "health test" "$CALLS" && pass "health.sh test ran" || fail "$(cat "$CALLS")"

echo "-- pin MACs"
: > "$CALLS"; run start pin-macs; check_eq "start: exit 0" 0 "$rc"
grep -qx "mac " "$CALLS" && pass "mac.sh ran for all instances" || fail "$(cat "$CALLS")"

echo "-- upload cache"
export HS_BULK_TYPE_FILE=$WORK/bulk-type HS_CACHE_DIR=$WORK/cache; mkdir -p "$HS_CACHE_DIR"
echo zfs > "$HS_BULK_TYPE_FILE"
run plan cache-mover; check_eq "zfs layout: refused" 1 "$rc"; has "snapraid" && pass "says snapraid" || fail "$out"
echo snapraid > "$HS_BULK_TYPE_FILE"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/mp-no"; printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/mp-yes"; chmod +x "$WORK/mp-no" "$WORK/mp-yes"
HS_MOUNTPOINT=$WORK/mp-no run plan cache-mover; check_eq "no cache mounted: refused" 1 "$rc"
export HS_MOUNTPOINT=$WORK/mp-yes
run plan cache-mover; check_eq "plan: exit 0" 0 "$rc"; has "^long${T}yes" && pass "a long job" || fail "$out"
: > "$CALLS"; run start cache-mover; check_eq "start: exit 0" 0 "$rc"; has "^status${T}started" && pass "a job was started" || fail "$out"
grep -q "JOB bash .*cache-mover-stub.sh --now" "$CALLS" && pass "cache-mover.sh --now ran as a job" || fail "$(cat "$CALLS")"

echo "-- fans"
export HS_HWMON_DIR=$WORK/hwmon; mkdir -p "$HS_HWMON_DIR/hwmon0"
run plan fans-clean; check_eq "no pwm channel: refused" 1 "$rc"
: > "$HS_HWMON_DIR/hwmon0/pwm1"
run plan fans-clean; check_eq "plan: exit 0" 0 "$rc"; has "for 8 seconds" && pass "the default is 8 seconds" || fail "$out"
run plan fans-clean --seconds 20; has "for 20 seconds" && pass "the seconds are used" || fail "$out"
run plan fans-clean --seconds 2;  check_eq "too short: refused" 1 "$rc"
run plan fans-clean --seconds 31; check_eq "too long: refused" 1 "$rc"
run plan fans-clean --seconds x;  check_eq "not a number: refused" 1 "$rc"
: > "$CALLS"; run start fans-clean --seconds 12; check_eq "start: exit 0" 0 "$rc"
grep -q "JOB bash .*fans-stub.sh clean 12" "$CALLS" && pass "fans.sh clean 12 ran as a job" || fail "$(cat "$CALLS")"

echo "-- bad calls"
run plan bogus;                  check_eq "unknown action: refused" 1 "$rc"
run plan test-push --seconds 3;  check_eq "--seconds only for the fans: refused" 1 "$rc"
run plan pin-macs --bogus;       check_eq "unknown option: refused" 1 "$rc"
finish
