#!/usr/bin/env bash
# hs disk list|<disk> health|test|results and hs sys disk-health list (scripts/disk-health.sh), with fake smartctl and lsblk
# on PATH and canned SMART JSON. Needs jq (always there in CI), no root (HS_DISK_HEALTH_NOROOT).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_DISK_HEALTH_NOROOT=1
BIN=$WORK/bin; SMART=$WORK/smart; mkdir -p "$BIN" "$SMART"
export SMARTDIR=$SMART CALLS=$WORK/calls; : > "$CALLS"

if ! command -v jq >/dev/null 2>&1; then skip "jq is not installed: disk health tests not run"; finish; exit $?; fi

# one JSON per disk name; the attribute table is the ATA one: id 5 reallocated, 197 pending, 199 CRC
attrs() { printf '{"ata_smart_attributes":{"table":[{"id":5,"raw":{"value":%s}},{"id":197,"raw":{"value":%s}},{"id":198,"raw":{"value":0}},{"id":199,"raw":{"value":0}}]}' "$1" "$2"; }
tests_ok='"ata_smart_data":{"self_test":{"polling_minutes":{"short":2,"extended":300}}},"ata_smart_self_test_log":{"standard":{"table":[{"type":{"string":"Short offline"},"status":{"string":"Completed without error","passed":true},"lifetime_hours":900},{"type":{"string":"Extended offline"},"status":{"string":"Completed without error","passed":true},"lifetime_hours":500}]}}'
{ attrs 0 0; printf ',"smart_status":{"passed":true},"model_name":"WDC WD40EFRX","serial_number":"S1","firmware_version":"80.00","user_capacity":{"bytes":4000000000000},"rotation_rate":5400,"power_on_time":{"hours":1000},"power_cycle_count":12,"temperature":{"current":35},%s}\n' "$tests_ok"; } > "$SMART/sda.json"
{ attrs 5 0; printf ',"smart_status":{"passed":true},"model_name":"Samsung SSD 850","rotation_rate":0,"power_on_time":{"hours":20000},"temperature":{"current":30}}\n'; } > "$SMART/sdb.json"
{ attrs 0 8; printf ',"smart_status":{"passed":true},"model_name":"Seagate IronWolf","power_on_time":{"hours":9000},"temperature":{"current":40}}\n'; } > "$SMART/sdc.json"
echo '{"smartctl":{"messages":[{"string":"Device is in STANDBY mode, exit(2)"}]},"model_name":"Sleepy"}' > "$SMART/sdd.json"
echo '{}' > "$SMART/sde.json"
cp "$SMART/sdc.json" "$SMART/bad.json"; cp "$SMART/sdb.json" "$SMART/watch.json"; cp "$SMART/sda.json" "$SMART/good.json"
{ attrs 0 0; printf ',"smart_status":{"passed":true},"model_name":"Old","power_on_time":{"hours":1000},"ata_smart_self_test_log":{"standard":{"table":[{"type":{"string":"Short offline"},"status":{"string":"Completed: read failure","passed":false},"lifetime_hours":900}]}}}\n'; } > "$SMART/failed-test.json"

cat > "$BIN/smartctl" <<'FAKE'
#!/usr/bin/env bash
if [ "$1" = -t ]; then
  echo "smartctl $*" >> "$CALLS"
  [ -z "${SMART_T_FAIL:-}" ] || { echo "=== START OF OFFLINE IMMEDIATE AND SELF-TEST SECTION ==="; echo "Self-test already in progress"; exit 1; }
  exit 0
fi
dev=${*: -1}
f=${SMART_FILE:-$SMARTDIR/$(basename "$dev").json}
[ ! -f "$f" ] || cat "$f"
FAKE
cat > "$BIN/lsblk" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "-dnb -o NAME,SIZE,ROTA") printf 'sda 4000000000000 1\nsdb 250000000000 0\nsdc 4000000000000 1\nsdd 2000000000000 1\nsde 32000000000 0\nloop0 1000 0\nzd0 5000 0\n' ;;
  *PKNAME*) ;;
  *TYPE*) echo disk ;;
  *MOUNTPOINT*) ;;
esac
FAKE
cat > "$BIN/hdparm" <<'FAKE'
#!/usr/bin/env bash
case "${*: -1}" in
  /dev/sda) printf '
/dev/sda:
 drive state is:  active/idle
' ;;
  /dev/sdc) printf '
/dev/sdc:
 drive state is:  standby
' ;;
  *) echo "$*" >> "$CALLS.hdparm" ;;
esac
FAKE
chmod +x "$BIN"/*
export PATH=$BIN:$PATH
D="bash $SCRIPTS/disk-health.sh"

echo "-- --list (the interface and hs sys disk-health list)"
out=$($D --list)
check_eq "loop and zfs devices are skipped" "5" "$(wc -l <<<"$out" | tr -d ' ')"
check_eq "a healthy HDD: OK, no note" $'sda\t4000000000000\tHDD\tWDC WD40EFRX\tOK\t1000\t-\tspinning' "$(grep '^sda' <<<"$out")"
check_out "reallocated sectors on an SSD: WATCH" $'^sdb\t250000000000\tSSD\tSamsung SSD 850\tWATCH\t20000\t5 reallocated' echo "$out"
check_out "pending sectors: BAD" $'^sdc\t.*\tBAD\t9000\t8 pending sector' echo "$out"
check_out "a sleeping disk is not woken: asleep" $'^sdd\t.*\tasleep\t' echo "$out"
check_out "no SMART data: unknown" $'^sde\t.*\tunknown\t' echo "$out"
check_out "a sleeping HDD is told by hdparm -C: power asleep" $'^sdc	.*	asleep$' echo "$out"
check_eq "SSDs get no power state and hdparm is not asked for them" "-" "$(grep '^sdb' <<<"$out" | awk -F'	' '{print $8}')"
check_eq "every line has 8 tab separated fields" "" "$(awk -F'	' 'NF != 8 { print NR": "NF }' <<<"$out")"

echo "-- the table for a person (hs disk list)"
out=$($D)
check_out "a header and the sizes" "[Dd]isk +[Ss]ize +[Tt]ype +[Mm]odel +[Vv]erdict" echo "$out"
check_out "sizes are human readable" "sda +4.0TB +HDD" echo "$out"
check_out "a pointer to the details" "hs disk <disk> health" echo "$out"

echo "-- one disk (hs disk <disk> health)"
out=$(SMART_FILE=$SMART/good.json $D /dev/null)
check_out "the model is the headline" "WDC WD40EFRX" echo "$out"
check_out "age, temperature and counters" "Reallocated sectors +0" echo "$out"
check_out "the last self-tests are listed" "Short offline Completed without error" echo "$out"
check_out "a clean disk: verdict OK" "Verdict: OK" echo "$out"
out=$(SMART_FILE=$SMART/watch.json $D /dev/null 2>&1 || true)
check_out "a worn disk: watch note and verdict WATCH" "Verdict: WATCH" echo "$out"
check_out "and the reason is named" "5 reallocated sector" echo "$out"
check_out "no self-test yet is said" "No self-test has been run yet" echo "$out"
out=$(SMART_FILE=$SMART/bad.json $D /dev/null 2>&1 || true)
check_out "a failing disk: verdict BAD" "Verdict: BAD" echo "$out"
check_eq "BAD is a non-zero exit" "1" "$(SMART_FILE=$SMART/bad.json $D /dev/null >/dev/null 2>&1; echo $?)"
check_eq "a failed self-test makes it BAD too" "BAD" "$(SMART_FILE=$SMART/failed-test.json $D /dev/null 2>&1 | grep -o 'Verdict: [A-Z]*' | cut -d' ' -f2)"
check_out "a disk without SMART data is explained" "gives no SMART data" env SMART_FILE=$SMART/sde.json $D /dev/null
check_out "an unknown disk name" "No disk 'nonexistent'" $D nonexistent
check_out "unknown option prints the usage" "usage: hs disk list" $D --bogus

echo "-- self-test (hs disk <disk> test short|long)"
check_eq "--dry-run only shows the command" "Would run: smartctl -t short /dev/null" "$($D --test short /dev/null --dry-run)"
: > "$CALLS"
out=$(SMART_FILE=$SMART/good.json $D --test short /dev/null 2>&1)
check_eq "the test is started inside the disk" "smartctl -t short /dev/null" "$(cat "$CALLS")"
check_out "with the time the disk gives" "Started the short self-test on /dev/null \(about 2 minutes\)" echo "$out"
check_out "and where to look later" "hs disk null results" echo "$out"
check_out "long uses the extended time" "about 300 minutes" env SMART_FILE=$SMART/good.json $D --test long /dev/null
check_out "a refused start says so" "did not start" env SMART_FILE=$SMART/good.json SMART_T_FAIL=1 $D --test short /dev/null
check_out "only short and long exist" "usage" $D --test weekly /dev/null
check_out "test needs a disk" "usage" $D --test short

echo "-- results (hs disk <disk> results)"
out=$(SMART_FILE=$SMART/good.json $D --results /dev/null)
check_out "the log has the newest first" "Short offline Completed without error at 900 h" echo "$out"
check_out "and the older ones" "Extended offline" echo "$out"
check_out "no log: none yet" "none yet" env SMART_FILE=$SMART/watch.json $D --results /dev/null
check_out "results need a disk" "usage" $D --results

echo "-- through the registry"
fake=$WORK/reg; mkdir -p "$fake/lib"
cp "$SCRIPTS"/lib/hs.sh "$SCRIPTS"/lib/capability.sh "$SCRIPTS"/lib/registry-load.sh "$SCRIPTS"/lib/ui.sh "$SCRIPTS"/lib/i18n.sh "$SCRIPTS"/lib/setting.sh "$SCRIPTS"/lib/job.sh "$SCRIPTS"/lib/diskpath.sh "$SCRIPTS/lib/registry.tsv" "$fake/lib/"; cp -r "$SCRIPTS"/lib/i18n "$fake/lib/"
cp "$SCRIPTS/disk-health.sh" "$fake/"
F="env HS_CALLER=t HS_COMPLETE_DIR=$WORK/complete bash $fake/lib/hs.sh"
check_eq "hs sys disk-health list" "$($D --list)" "$($F sys disk-health list)"
check_out "hs disk list" "[Dd]isk +[Ss]ize +[Tt]ype" $F disk list
check_out "hs disk <disk> health" "Verdict: OK" env SMART_FILE=$SMART/good.json $F disk /dev/null health
check_out "hs disk <disk> test short" "Started the short self-test" env SMART_FILE=$SMART/good.json $F disk /dev/null test short
check_out "hs disk <disk> results" "Self-tests of /dev/null" env SMART_FILE=$SMART/good.json $F disk /dev/null results
finish
