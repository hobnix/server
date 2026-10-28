#!/usr/bin/env bash
# scripts/deck-status.sh (hs sys deck) and scripts/deck-serve.py: the status document for displays. Fake /proc, /sys/class/net, zpool, df,
# overview-status, monitor and ip: no root, no disks. Needs jq (the server has it); the server part needs python3.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en HS_STATE_DIR=$WORK/state HS_LOCKED_MARKER=$WORK/no-marker
unset HS_CALLER HS_GUIDED_TTY
command -v jq >/dev/null || { echo "jq missing: skipped"; exit 0; }
mkdir -p "$WORK/state" "$WORK/proc" "$WORK/net/br0/statistics" "$WORK/net/br0/brif" "$WORK/net/enp1s0/statistics" "$WORK/net/enp1s0/device"
ln -s ../../enp1s0 "$WORK/net/br0/brif/enp1s0"

printf 'cpu  100 0 50 800 50 0 0 0 0 0\ncpu0 1 2 3 4 5 6 7 8 9 10\n' > "$WORK/proc/stat"
printf 'MemTotal:       16000000 kB\nMemFree: 1 kB\nMemAvailable:    4000000 kB\n' > "$WORK/proc/meminfo"
printf '0.50 0.75 1.00 1/200 999\n' > "$WORK/proc/loadavg"
printf '90061.12 1000.00\n' > "$WORK/proc/uptime"
printf '5\n' > "$WORK/net/br0/statistics/rx_bytes"; printf '6\n' > "$WORK/net/br0/statistics/tx_bytes"
printf '1000\n' > "$WORK/net/enp1s0/statistics/rx_bytes"; printf '2000\n' > "$WORK/net/enp1s0/statistics/tx_bytes"
printf 'time=1\nbackup-stale\nzfs-degraded\n' > "$WORK/state/health.state"

cat > "$WORK/ip" <<'FAKE'
#!/usr/bin/env bash
echo "default via 10.10.10.1 dev br0 proto dhcp src 10.10.10.95 metric 1024"
FAKE
cat > "$WORK/zpool" <<'FAKE'
#!/usr/bin/env bash
printf '1999989506048\t500000000000\tONLINE\n'
FAKE
cat > "$WORK/df" <<'FAKE'
#!/usr/bin/env bash
printf '       1B-blocks            Used\n 7999999999999   3000000000000\n'
FAKE
cat > "$WORK/status" <<'FAKE'
#!/usr/bin/env bash
printf 'backup\tok\t7200\nencryption\topen\nsmart\t3\tsdb WATCH,sdc BAD\ninstances\t2\t3\nhottest\tsdb\t44\n'
FAKE
cat > "$WORK/monitor" <<'FAKE'
#!/usr/bin/env bash
printf 'sda\t250\tSSD\tsystem\t31\nsdc\t4000\tHDD\tbulk\t-\n'
FAKE
cat > "$WORK/nvidia-smi" <<'FAKE'
#!/usr/bin/env bash
echo "NVIDIA GeForce RTX 4060, 7, 1024, 8188, 43"
FAKE
chmod +x "$WORK/ip" "$WORK/zpool" "$WORK/df" "$WORK/status" "$WORK/monitor"
export HS_PROC=$WORK/proc HS_NET_DIR=$WORK/net HS_IP=$WORK/ip HS_ZPOOL=$WORK/zpool HS_DF=$WORK/df
export HS_NVIDIA_SMI=$WORK/nvidia-smi DH_DIR=$WORK/history HS_OVERVIEW_STATUS=$WORK/status HS_MONITOR=$WORK/monitor HS_HOSTNAME=homeserver HS_NOW=1700000000
D="bash $SCRIPTS/deck-status.sh"

j() { $D | jq -c "$1"; }
echo "-- the document"
check_eq "valid JSON, schema 1, kind and host" '[1,"homeserver","homeserver",1700000000]' "$(j '[.schema,.kind,.host,.time]')"
check_eq "uptime and load" '[90061,[0.5,0.75,1]]' "$(j '[.uptime_s,(.load|map(.*1))]')"
check_eq "cpu counters (total, idle + iowait)" '{"total":1000,"idle":850}' "$(j '.cpu')"
check_eq "memory in bytes" '{"total":16384000000,"available":4096000000}' "$(j '.mem')"
check_eq "network counters: the physical port under the default bridge (it counts the VLANs too)" '{"iface":"enp1s0","rx_bytes":1000,"tx_bytes":2000}' "$(j '.net')"
check_eq "fast pool (ZFS)" '{"size":1999989506048,"used":500000000000,"health":"ONLINE"}' "$(j '.pools.fast')"
check_eq "bulk pool (df of /bulk)" '{"size":7999999999999,"used":3000000000000}' "$(j '.pools.bulk')"
check_eq "problems come from health.state" '2' "$(j '.problems')"
check_eq "backup and encryption" '[{"status":"ok","age_s":7200},"open",false]' "$(j '[.backup,.encryption,.locked]')"
check_eq "disk health findings" '{"disks":3,"findings":["sdb WATCH","sdc BAD"]}' "$(j '.smart')"
check_eq "instances and the hottest disk" '[{"running":2,"total":3},{"disk":"sdb","temp":44}]' "$(j '[.instances,.hottest]')"
check_eq "disks, an unreadable temperature is null" '[31,null]' "$(j '[.disks[].temp]')"

echo "-- the capabilities that are on (additive key; the web interface builds a remote node's pages from them)"
printf 'storage
incus
' > "$WORK/caps"
check_eq "capabilities: the names that are on" '["incus","storage"]' "$(HS_CAPABILITIES_FILE=$WORK/caps HS_CAPABILITIES_TSV=/dev/null $D | jq -c '.capabilities | sort')"
check_eq "no capability file: an empty list, never missing" '[]' "$(HS_CAPABILITIES_FILE=$WORK/none HS_CAPABILITIES_TSV=/dev/null $D | jq -c '.capabilities')"

echo "-- the graphics card"
check_eq "gpu: name without the brand, percent, bytes, temperature" '{"name":"RTX 4060","util":7,"mem_used":1073741824,"mem_total":8585740288,"temp":43}' "$(j '.gpu')"
printf '#!/usr/bin/env bash\nexit 9\n' > "$WORK/nvidia-smi.none"; chmod +x "$WORK/nvidia-smi.none"
check_eq "no card, no gpu key content" 'null' "$(HS_NVIDIA_SMI=$WORK/nvidia-smi.none $D | jq -c '.gpu')"
check_eq "a command that is not there is the same" 'null' "$(HS_NVIDIA_SMI=$WORK/not-there $D | jq -c '.gpu')"

echo "-- the last 24 hours"
check_eq "nothing recorded: 24 empty hours" '[24,24,3600]' "$(j '[(.history.hours|length),([.history.hours[]|select(.==null)]|length),.history.interval_s]')"
check_eq "looking at the document adds no reading" 'no' "$([ -e "$WORK/history/samples" ] && echo yes || echo no)"
# three hours of readings, one every 10 minutes: cpu busy 10 / 20 / 30 percent, counters grow 1000 bytes a second, a reboot in the third hour
t0=1700002800   # a full hour boundary
rx=1000; ct=1000; ci=900; up=5000
for i in $(seq 0 17); do
  now=$((t0 + i * 600))
  rx=$((rx + 600 * 1000)); busy=$((10 * (1 + i / 6))); ct=$((ct + 1000)); ci=$((ci + 1000 - busy * 10))
  up=$((up + 600)); [ "$i" = 14 ] && up=100
  printf 'cpu  %s 0 0 %s 0 0 0 0 0 0\n' "$((ct - ci))" "$ci" > "$WORK/proc/stat"
  printf '%s\n' "$up.00 1.00" > "$WORK/proc/uptime"
  printf '%s\n' "$rx" > "$WORK/net/enp1s0/statistics/rx_bytes"
  HS_DECK_RECORD=1 HS_NOW=$now $D > /dev/null
done
now=$((t0 + 3 * 3600 + 60))
HS_DECK_RECORD=1 HS_NOW=$now $D > /dev/null          # the first reading of the next hour rolls the third hour up
doc=$(HS_NOW=$now $D)
echo "$doc" | jq -c '.history.hours[-4:]' > "$WORK/last4"
check_eq "three finished hours are there, the one before them is empty" '[false,true,true,true]' "$(echo "$doc" | jq -c '[.history.hours[-4:][]|(. != null)]')"
check_eq "the median of cpu per hour" '[10,20,30]' "$(echo "$doc" | jq -c '[.history.hours[-3:][].cpu]')"
check_eq "network rate: a second's worth of counter is 1000" '[1000,1000,1000]' "$(echo "$doc" | jq -c '[.history.hours[-3:][].rx]')"
check_eq "memory percent is the same every hour (75)" '[75,75,75]' "$(echo "$doc" | jq -c '[.history.hours[-3:][].mem]')"
check_eq "the gpu median" '[7,7,7]' "$(echo "$doc" | jq -c '[.history.hours[-3:][].gpu]')"
check_eq "up is the share of the readings that were there (6 of 360)" '[0.02,0.02,0.02]' "$(echo "$doc" | jq -c '[.history.hours[-3:][].up]')"
check_eq "the hour with the reboot says so" '[false,false,true]' "$(echo "$doc" | jq -c '[.history.hours[-3:][].boot]')"
check_eq "each hour is stamped with its start" '[1700002800,1700006400,1700010000]' "$(echo "$doc" | jq -c '[.history.hours[-3:][].t]')"

echo "-- sources that fail leave their key null; a locked boot shows"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/zpool"; printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/df"; : > "$WORK/state/health.state"; rm -f "$WORK/state/health.state"
touch "$WORK/marker"
check_eq "no pools, no problems count, locked" '[null,null,null,true]' "$(HS_LOCKED_MARKER=$WORK/marker $D | jq -c '[.pools.fast,.pools.bulk,.problems,.locked]')"
check_eq "no secrets: no key outside the known list" '[]' "$($D | jq -c 'keys - ["schema","kind","host","time","uptime_s","load","cpu","mem","net","pools","locked","encryption","problems","backup","smart","instances","hottest","disks","gpu","history","inventory","capabilities"]')"
echo "-- the disk inventory (state database)"
check_eq "no database: inventory is null" 'null' "$(j '.inventory')"
if command -v python3 >/dev/null; then
  printf 'sda\t250\tSSD\tsystem\t77\tOK\t1\t0\t0\t0\tx\t-\n' > "$WORK/mon.txt"
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$WORK/mon.txt" > "$WORK/mon"; printf '#!/usr/bin/env bash\necho "sda S1 M"\n' > "$WORK/lsb"
  HS_MONITOR=$WORK/mon HS_LSBLK=$WORK/lsb HS_NOW=1699999990 bash "$SCRIPTS/state.sh" collect
  check_eq "a known disk: counted, none missing" '{"known":1,"missing":[],"worse":[]}' "$(j '.inventory')"
  check_eq "the disks come from the database while its reading is fresh (77; the fake monitor says 31)" '[{"name":"sda","bytes":250,"kind":"SSD","role":"system","temp":77}]' "$(j '.disks')"
  check_eq "an old reading is not used: back to the disks themselves" '[31,null]' "$(HS_NOW=1700009999 $D | jq -c '[.disks[].temp]')"
fi

echo "-- the registry row"
check_out "hs sys deck runs it" '"schema": 1' env HS_CALLER=test bash "$SCRIPTS/lib/hs.sh" sys deck

echo "-- the endpoint hands out that file and nothing else"
if command -v python3 >/dev/null; then
  $D > "$WORK/deck.json"
  port=$((20000 + RANDOM % 20000))
  python3 "$SCRIPTS/deck-serve.py" "$port" "$WORK/deck.json" & srv=$!
  sleep 1
  get() { python3 - "$port" "$1" "${2:-GET}" <<'PY'
import sys, urllib.request, urllib.error
port, path, method = sys.argv[1:4]
req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", method=method)
try:
    r = urllib.request.urlopen(req, timeout=3); print(r.status, r.read().decode()[:60].strip().replace("\n", " "))
except urllib.error.HTTPError as e:
    print(e.code)
PY
  }
  check_eq "/status.json is the document" "200" "$(get /status.json | cut -d' ' -f1)"
  check_eq "/healthz" "200 ok" "$(get /healthz)"
  check_eq "another path is 404" "404" "$(get /etc/passwd)"
  check_eq "POST is refused" "501" "$(get /status.json POST)"
  touch -d '10 minutes ago' "$WORK/deck.json"
  check_eq "an old document is 503, not shown as fresh" "503" "$(get /status.json)"
  kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null
else
  echo "python3 missing: endpoint skipped"
fi
finish
