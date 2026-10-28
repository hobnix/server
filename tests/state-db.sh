#!/usr/bin/env bash
# scripts/state-db.py + scripts/state.sh: the disk inventory, events, SMART rows, missing and worsening disks,
# the locked storage, forget, the health-check problems. Fake monitor.sh and lsblk, python3 stdlib only, no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
command -v python3 >/dev/null || { echo "python3 missing: skipped"; exit 0; }
# a path python can open (on the Windows workstation /tmp is a Git-bash path)
wp() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
if command -v cygpath >/dev/null 2>&1; then export HS_TEST_BASH=$(cygpath -m "$BASH"); fi   # python must start THIS bash, not WSL's
export HS_PLAIN=1 HS_LANG=en HS_CALLER=test HS_STATE_DIR=$(wp "$WORK/state") HS_LOCKED_MARKER=$(wp "$WORK/no-marker")
export HS_MONITOR=$WORK/monitor HS_LSBLK=$WORK/lsblk HS_STATE_SMART_EVERY=0
mkdir -p "$WORK/state"
MON=$WORK/mon.txt LS=$WORK/ls.txt
export MON LS
printf '#!/usr/bin/env bash\ncat "$MON"\n' > "$WORK/monitor"
printf '#!/usr/bin/env bash\ncat "$LS"\n' > "$WORK/lsblk"
chmod +x "$WORK/monitor" "$WORK/lsblk"
S="bash $SCRIPTS/state.sh"
# monitor: name bytes kind role temp health hours realloc pending crc rest free
mon() { printf '%s\t%s\tHDD\t%s\t%s\tOK\t100\t%s\t%s\t%s\tx\t-\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7"; }
step() { HS_NOW=$1 $S collect; }

echo "-- the first run seeds silently"
{ mon sda 250000000000 system 31 0 0 0; mon sdb 4000000000000 "bulk 01" 40 0 0 0; } > "$MON"
printf 'sda S1 Samsung\\x20SSD\\x20850\nsdb S2 ST4000VN006\n' > "$LS"
step 1000
check_eq "two disks, both ok" "S1 ok
S2 ok" "$($S disks | awk -F'\t' '{print $1, $5}' | sort)"
check_eq "model with spaces is decoded" "Samsung SSD 850" "$($S disks | awk -F'\t' '$1 == "S1" {print $2}')"
check_eq "pool of a bulk member" "bulk" "$($S disks | awk -F'\t' '$1 == "S2" {print $7}')"
check_eq "no event for disks that were always there" "" "$($S events)"

echo "-- a new disk"
mon sdc 2000000000000 fast 35 0 0 0 >> "$MON"
printf 'sdc S3 WD\\x20Red\n' >> "$LS"
step 2000
check_out "event new" "^2000	new	S3	" $S events

echo "-- a disk that goes away stays listed as missing"
{ mon sda 250000000000 system 31 0 0 0; mon sdc 2000000000000 fast 35 0 0 0; } > "$MON"
printf 'sda S1 Samsung\\x20SSD\\x20850\nsdc S3 WD\\x20Red\n' > "$LS"
step 3000
check_eq "S2 is missing, S1 ok" "S1 ok
S2 missing
S3 ok" "$($S disks | awk -F'\t' '{print $1, $5}' | sort)"
check_out "event missing" "	missing	S2	" $S events
check_out "health problem names the forget command" "^disk:S2:missing	.*hs disk S2 forget" $S problems
step 3100
check_eq "a second run adds no second event" "1" "$($S events | grep -c '	missing	S2	')"
check_out "forget refuses a disk that is there" "only a missing disk can be forgotten" $S forget S1 --yes

echo "-- it comes back"
{ mon sda 250000000000 system 31 0 0 0; mon sdb 4000000000000 "bulk 01" 40 0 0 0; mon sdc 2000000000000 fast 35 0 0 0; } > "$MON"
printf 'sda S1 Samsung\nsdb S2 ST4000VN006\nsdc S3 WD\n' > "$LS"
step 4000
check_out "event back" "	back	S2	" $S events
check_eq "no problems" "" "$(HS_NOW=4000 $S problems)"

echo "-- the source fails: nothing is marked missing"
: > "$MON"
step 5000
check_eq "still three disks ok" "3" "$($S disks | awk -F'\t' '$5 == "ok"' | grep -c .)"
check_eq "and no new event" "0" "$($S events | grep -c '	5000	')"

echo "-- locked storage: roles are kept, nothing is lost"
{ mon sda 250000000000 system 31 0 0 0; mon sdb 4000000000000 free 40 0 0 0; mon sdc 2000000000000 free 35 0 0 0; } > "$MON"
touch "$WORK/marker"
HS_LOCKED_MARKER=$(wp "$WORK/marker") HS_NOW=6000 $S collect
check_eq "role and pool of S2 are as before" "bulk 01	bulk" "$($S disks | awk -F'\t' '$1 == "S2" {print $6 "\t" $7}')"
rm -f "$WORK/marker"

echo "-- a disk that gets worse"
{ mon sda 250000000000 system 31 0 0 0; mon sdb 4000000000000 "bulk 01" 40 0 0 0; mon sdc 2000000000000 fast 35 0 0 0; } > "$MON"
step 7000
{ mon sda 250000000000 system 31 0 0 0; mon sdb 4000000000000 "bulk 01" 40 8 2 0; mon sdc 2000000000000 fast 35 0 0 0; } > "$MON"
step 8000
check_eq "S2 is flagged worse with a note" "1	reallocated 0 -> 8, pending 0 -> 2" "$($S disks | awk -F'\t' '$1 == "S2" {print $10 "\t" $11}')"
check_out "event worse" "	worse	S2	" $S events
check_out "problem worse" "^disk:S2:worse	" $S problems
check_eq "smart rows are stored over time" "true" "$([ "$($S smart S2 | grep -c .)" -ge 3 ] && echo true || echo false)"
check_eq "smart accepts the kernel name too" "true" "$([ "$($S smart sdb | grep -c .)" -ge 3 ] && echo true || echo false)"

echo "-- forget"
{ mon sda 250000000000 system 31 0 0 0; mon sdc 2000000000000 fast 35 0 0 0; } > "$MON"
step 9000
check_eq "forget needs --yes without a terminal" "1" "$($S forget S2 </dev/null >/dev/null 2>&1; echo $?)"
check_out "forget removes it" "Forgot S2" $S forget S2 --yes
check_eq "gone from the list" "" "$($S disks | awk -F'\t' '$1 == "S2"')"
check_out "and the event stays" "	forgotten	S2	" $S events
check_eq "unknown disk" "1" "$($S forget NOPE --yes >/dev/null 2>&1; echo $?)"

echo "-- a disk without a serial is followed by name and never missing"
mon sdd 100 free 20 0 0 0 >> "$MON"; printf 'sdd  \n' >> "$LS"
{ mon sda 250000000000 system 31 0 0 0; mon sdc 2000000000000 fast 35 0 0 0; mon sdd 100 free 20 0 0 0; } > "$MON"
printf 'sda S1 Samsung\nsdc S3 WD\nsdd\n' > "$LS"
step 10000
check_eq "state unknown" "unknown" "$($S disks | awk -F'\t' '$1 == "dev:sdd" {print $5}')"
printf 'sda S1 Samsung\nsdc S3 WD\n' > "$LS"; { mon sda 250000000000 system 31 0 0 0; mon sdc 2000000000000 fast 35 0 0 0; } > "$MON"
step 11000
check_eq "just gone, no missing entry" "" "$($S disks | awk -F'\t' '$1 == "dev:sdd"')"

echo "-- the collector stopped"
check_out "stale inventory is a problem" "^state:stale	" env HS_NOW=20000 $S problems
check_eq "deck-disks is not fresh any more (exit 1)" "1" "$(HS_NOW=20000 $S deck-disks >/dev/null; echo $?)"
check_eq "deck-disks right after a run" "sda	250000000000	HDD	system	31
sdc	2000000000000	HDD	fast	35" "$(HS_NOW=11050 $S deck-disks)"
check_eq "inventory json" '{"known":2,"missing":[],"worse":[]}' "$(HS_NOW=11050 $S inventory-json)"

echo "-- history: the same numbers the old text files gave (tests/deck-status.sh has the same scenario)"
export HS_STATE_DB=$(wp "$WORK/hist/state.db")
check_eq "nothing recorded: 24 empty hours" "24" "$($S history 1700000000 | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len([h for h in d["hours"] if h is None]))')"
t0=1700002800; rx=1000; ct=1000; ci=900; up=5000
for i in $(seq 0 17); do
  now=$((t0 + i * 600)); rx=$((rx + 600 * 1000)); busy=$((10 * (1 + i / 6))); ct=$((ct + 1000)); ci=$((ci + 1000 - busy * 10))
  up=$((up + 600)); [ "$i" = 14 ] && up=100
  $S history-record "$now" "$rx" "$rx" "$ct" "$ci" 16384000000 4096000000 7 "$up"
done
now=$((t0 + 3 * 3600 + 60))
$S history-record "$now" "$rx" "$rx" "$ct" "$ci" 16384000000 4096000000 7 "$up"       # the next hour's first reading rolls the third hour up
H=$($S history "$now")
hj() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(json.dumps(eval(sys.argv[2]), separators=(",", ":")))' "$H" "$1"; }
check_eq "shape: 24 entries and the interval" "[24,3600]" "$(hj '[len(d["hours"]), d["interval_s"]]')"
check_eq "three finished hours, the one before them is empty" "[false,true,true,true]" "$(hj '[h is not None for h in d["hours"][-4:]]' | sed 's/False/false/g;s/True/true/g')"
check_eq "median cpu per hour" "[10,20,30]" "$(hj '[h["cpu"] for h in d["hours"][-3:]]')"
check_eq "network rate (a second's worth of counter is 1000)" "[1000,1000,1000]" "$(hj '[h["rx"] for h in d["hours"][-3:]]')"
check_eq "memory percent" "[75,75,75]" "$(hj '[h["mem"] for h in d["hours"][-3:]]')"
check_eq "gpu median" "[7,7,7]" "$(hj '[h["gpu"] for h in d["hours"][-3:]]')"
check_eq "up = share of the expected readings" "[0.02,0.02,0.02]" "$(hj '[h["up"] for h in d["hours"][-3:]]')"
check_eq "the hour with the reboot says so" "[false,false,true]" "$(hj '[h["boot"] for h in d["hours"][-3:]]' | sed 's/False/false/g;s/True/true/g')"
check_eq "each hour is stamped with its start" "[1700002800,1700006400,1700010000]" "$(hj '[h["t"] for h in d["hours"][-3:]]')"

echo "-- history: the old files are migrated once"
export HS_STATE_DB=$(wp "$WORK/mig/state.db")
mkdir -p "$WORK/oldhist"
printf '472222 12 40 5 1000 2000 0.50 0\n472223 - 41 - 1500 2500 1.00 1\n' > "$WORK/oldhist/hours"
printf '1700006400 15 40 5 100 200 0\n' > "$WORK/oldhist/samples"
printf '1700006400 500 600 9000 8000 123\n' > "$WORK/oldhist/last"
now=1700007000
DH_DIR=$(wp "$WORK/oldhist") $S history-record "$now" 600 700 9100 8050 16384000000 4096000000 "" 723
H=$($S history "$now")
check_eq "old hours are there, the empty value stays null" "[[12,40,5,1000,2000,0.5,false],[null,41,null,1500,2500,1,true]]" \
  "$(hj '[[h["cpu"],h["mem"],h["gpu"],h["rx"],h["tx"],h["up"],h["boot"]] for h in d["hours"] if h]' | sed 's/False/false/g;s/True/true/g')"
check_eq "old files are renamed, not deleted" "yes" "$([ -e "$WORK/oldhist/hours.migrated" ] && [ ! -e "$WORK/oldhist/hours" ] && echo yes || echo no)"
printf '472221 1 1 1 1 1 1.00 0\n' > "$WORK/oldhist/hours"      # a second run does not import again
DH_DIR=$(wp "$WORK/oldhist") $S history-record 1700007100 700 800 9200 8100 16384000000 4096000000 "" 800
check_eq "migration happens once" "2" "$($S history "$now" | python3 -c 'import json,sys; print(sum(1 for h in json.load(sys.stdin)["hours"] if h))')"

echo "-- the endpoint: /disks and /events, serials masked, nothing else"
unset HS_STATE_DB
pj() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(eval(sys.argv[1]), separators=(",", ":")))' "$1"; }
check_eq "disks-json masks the serial" '["S1","S3"]' "$($S disks-json | pj '[x["id"] for x in d["disks"]]')"
mon sde 100 free 20 0 0 0 > /dev/null
printf 'sde SERIAL12345 Some\\x20Disk\n' >> "$LS"; { cat "$MON"; mon sde 100 free 20 0 0 0; } > "$MON.2"; mv "$MON.2" "$MON"
step 12000
check_eq "a long serial shows its last four characters only" '["...2345"]' "$($S disks-json | pj '[x["id"] for x in d["disks"] if x["dev"] == "sde"]')"
check_eq "and not in the event text either" '0' "$($S events-json | grep -c SERIAL12345)"
check_eq "the event text keeps the tail" '1' "$($S events-json | grep -c 'S/N ...2345')"
mkdir -p "$WORK/run"
$S disks-json > "$WORK/run/deck-disks.json"; $S events-json > "$WORK/run/deck-events.json"; echo '{"schema":1}' > "$WORK/run/deck.json"
port=$((20000 + RANDOM % 20000))
python3 "$SCRIPTS/deck-serve.py" "$port" "$(wp "$WORK/run/deck.json")" 2>"$WORK/srv.err" & srv=$!
sleep 1
get() { python3 - "$port" "$1" "${2:-GET}" <<'PY'
import sys, urllib.request, urllib.error
port, path, method = sys.argv[1:4]
try:
    r = urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{port}/{path}", method=method), timeout=3); print(r.status, r.read().decode()[:12])
except urllib.error.HTTPError as e:
    print(e.code)
PY
}
for _ in $(seq 1 30); do [ "$(get healthz 2>/dev/null)" = "200 ok" ] && break; sleep 0.3; done     # a slow start is not a failure
check_eq "/status.json" "200 {\"schema\":1}" "$(get status.json)"
check_eq "/disks" "200 {\"schema\":1," "$(get disks)"
check_eq "/events" "200 {\"schema\":1," "$(get events)"
check_eq "/healthz" "200 ok" "$(get healthz)"
check_eq "any other path is 404 (also the files next to it)" "404 404 404" "$(for p in deck-disks.json state.db ../etc/passwd; do get "$p" | tr -d '\r'; done | paste -sd" ")"
check_eq "POST is refused" "501" "$(get disks POST)"
kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null
[ ! -s "$WORK/srv.err" ] || head -5 "$WORK/srv.err" >&2

echo "-- readers on an empty state"
export HS_STATE_DB=$(wp "$WORK/none/state.db")
export HS_STATE_DB=$(wp "$WORK/none/state.db")   # no file there (the Windows Store python redirects writes under AppData, so a rm would not find the real one)
check_eq "no database: nothing, no error" "0" "$($S disks >/dev/null; echo $?)"
check_eq "inventory json is null" "null" "$($S inventory-json)"
finish
