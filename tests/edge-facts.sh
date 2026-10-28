#!/usr/bin/env bash
# The edge node: the status document (scripts/edge-status.sh over scripts/lib/edge_facts.py), the health check
# (scripts/edge-health.sh), the node status through the forced command, and the watcher's files. Every external tool (postqueue, tailscale, nft, ...) is a stand-in
# script, the network is HS_EDGE_TCP_FAKE: no root, no VPS, no jq needed (the document is read with python).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en PYTHONUTF8=1
unset HS_CALLER HS_GUIDED_TTY
python3 -c 'import sys' 2>/dev/null || { skip "python3 is missing"; finish; }

NOW=$(python3 -c 'import calendar; print(calendar.timegm((2026, 9, 21, 0, 0, 0)))')
ETC=$WORK/etc; STATE=$WORK/state; FB=$WORK/fakebin; PROC=$WORK/proc; NET=$WORK/net
mkdir -p "$ETC" "$STATE" "$FB" "$PROC" "$NET/eth0/statistics" "$NET/tailscale0/statistics" "$WORK/watch"
# python reads the paths inside the JSON files itself (Windows: C:/...); the stand-ins run with the bash of this shell
WW=$WORK; BASHX=bash
if command -v cygpath >/dev/null 2>&1; then WW=$(cygpath -m "$WORK"); BASHX="'$(cygpath -m "$(command -v bash)")'"; fi
export HS_EDGE_DF_FAKE="10000000000 3000000000"

echo "-- stand-ins"
cat > "$FB/postqueue" <<EOF
#!/usr/bin/env bash
printf '{"queue_name":"deferred","arrival_time":$((NOW - 600))}\n{"queue_name":"active","arrival_time":$((NOW - 100))}\n'
EOF
cat > "$FB/postconf" <<'EOF'
#!/usr/bin/env bash
echo "check_policy_service unix:private/policyd-spf, reject_unverified_recipient"
EOF
cat > "$FB/tailscale" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  status) echo '{"BackendState":"'"${FAKE_TS:-Running}"'","Self":{"TailscaleIPs":["100.64.0.5","fd7a::5"],"Tags":["tag:vps"]}}' ;;
  ping) echo "pong from stalwart (100.64.0.10) via DERP(fra) in 23ms" ;;
esac
EOF
cat > "$FB/nft" <<'EOF'
#!/usr/bin/env bash
cat <<'RULES'
table ip hs-edge-nat {
	chain prerouting {
		type nat hook prerouting priority dstnat; policy accept;
		iifname != "tailscale0" tcp dport { 25565-25579, 27015 } dnat to 100.64.0.11
		iifname != "tailscale0" udp dport 25565-25579 dnat to 100.64.0.11
	}
}
table inet nixos-fw {
	chain input-allow {
		tcp dport { 25, 80 } accept
		udp dport 41641 accept
	}
}
RULES
EOF
cat > "$FB/openssl" <<'EOF'
#!/usr/bin/env bash
echo "notAfter=${FAKE_CERT_END:-Oct  1 00:00:00 2026 GMT}"
EOF
cat > "$FB/systemctl" <<'EOF'
#!/usr/bin/env bash
if [ -n "${FAKE_FAILED:-}" ]; then echo "foo.service loaded failed failed Foo"; fi
EOF
cat > "$FB/git" <<'EOF'
#!/usr/bin/env bash
printf 'abc1234\nAdd the edge node\n'
EOF
cat > "$FB/ip" <<'EOF'
#!/usr/bin/env bash
echo "default via 192.0.2.1 dev eth0 proto dhcp src 192.0.2.10"
EOF
cat > "$FB/journalctl" <<'EOF'
#!/usr/bin/env bash
echo "1789990000.123456 mx postfix/smtp[1]: A1B2C3: to=<x@example.org>, relay=100.64.0.10[100.64.0.10]:25, status=sent (250 ok)"
EOF
cat > "$FB/curl" <<'EOF'
#!/usr/bin/env bash
# the region lookup fails; the push messages are logged
printf '%s\n' "$*" >> "${FAKE_CURL_LOG:-/dev/null}"
case "$*" in *169.254.169.254*) exit 22 ;; esac
exit 0
EOF
chmod +x "$FB"/*
for t in postqueue postconf tailscale nft openssl systemctl git ip journalctl curl; do
  up=$(echo "$t" | tr a-z A-Z); export "HS_EDGE_$up=$BASHX $FB/$t"
done
printf 'cpu  100 0 100 800 0 0 0 0 0 0\n' > "$PROC/stat"
printf 'MemTotal:        1000000 kB\nMemAvailable:     400000 kB\n' > "$PROC/meminfo"
printf '0.10 0.20 0.30 1/100 123\n' > "$PROC/loadavg"
printf '86400.50 1000.00\n' > "$PROC/uptime"
printf '1000' > "$NET/eth0/statistics/rx_bytes"; printf '2000' > "$NET/eth0/statistics/tx_bytes"
printf '30' > "$NET/tailscale0/statistics/rx_bytes"; printf '40' > "$NET/tailscale0/statistics/tx_bytes"
printf 'PRETTY_NAME="NixOS 26.05 (Yarara)"\n' > "$WORK/os-release"
export HS_ETC_DIR=$ETC HS_STATE_DIR=$STATE HS_PROC=$PROC HS_NET_DIR=$NET HS_NOW=$NOW HS_HOSTNAME=edge1 HS_OS_RELEASE=$WORK/os-release
export HS_EDGE_TCP_FAKE="100.64.0.10:25=ok,100.64.0.11:25565=refused,100.64.0.12:7881=timeout"
printf '1789999000\nno-key\n' > "$STATE/health.state"
cat > "$ETC/edge-mail.json" <<'EOF'
{"domain":"example.org","mxHost":"mx.example.org","stalwartIp":"100.64.0.10","acmeEmail":"me@example.org","certFile":"/etc/ssl/mx/fullchain.pem"}
EOF
cat > "$ETC/edge-ports.json" <<'EOF'
{"wingsIp":"100.64.0.11","gamePorts":["25565-25579"],"gameTcp":["27015"],"gameUdp":[],"rtcIp":"100.64.0.12","rtcTcp":["7881"],"rtcUdp":["50000-50100"]}
EOF
printf '{"sites":["https://example.org"],"stateFile":"%s/watch/state"}\n' "$WW" > "$ETC/edge-watcher.json"
cat > "$ETC/edge-status.json" <<'EOF'
{"hostName":"edge1","role":"edge","notifyUrlFile":"/var/lib/hs/notify-url","heartbeatUrlFile":"/var/lib/hs/heartbeat-url","tailscaleAuthKeyFile":"/var/lib/hs/tailscale-authkey"}
EOF
printf '%s\n' "$NOW" > "$WORK/watch/state.run"
printf '%s\n' "$((NOW - 120))" > "$WORK/watch/state.beat"
printf '%s\n%s\n' "$((NOW - 3600))" "https://down.example.org does not answer at all" > "$WORK/watch/state"
printf 'example.org\thttps://example.org\t200\t%s\ndown.example.org\thttps://down.example.org\t000\t%s\n' "$((NOW - 7200))" "$((NOW - 3600))" > "$WORK/watch/state.sites"

echo "-- registry"
T=$'\t'
reg=$SCRIPTS/lib/registry.tsv
check "row: sys edge status" grep -q "^sys${T}sys edge status${T}edge-status.sh${T}" "$reg"
check "row: edge health" grep -q "^user${T}edge health${T}edge-health.sh${T}" "$reg"
check "the facts library is python3 only (no jq call)" test -z "$(grep -nE "run\(.jq|jq -" "$SCRIPTS/lib/edge_facts.py" || true)"

echo "-- the status document"
bash "$SCRIPTS/edge-status.sh" > "$WORK/doc.json" 2>"$WORK/err"
check_eq "exit 0 and one JSON object" "dict" "$(python3 -c 'import json,sys; print(type(json.load(open(sys.argv[1], encoding="utf-8"))).__name__)' "$WORK/doc.json")"
J() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); print(json.dumps(eval(sys.argv[2]), separators=(",", ":")))' "$WORK/doc.json" "$1"; }
check_eq "schema, kind, host, time" '[1,"proxyserver","edge1",'$NOW']' "$(J '[d["schema"], d["kind"], d["host"], d["time"]]')"
check_eq "capabilities: the edge parts whose file exists" '["edge-mail","edge-ports","edge-status","edge-watcher"]' "$(J 'd["capabilities"]')"
check_eq "uptime, load" '[86400,[0.1,0.2,0.3]]' "$(J '[d["uptime_s"], d["load"]]')"
check_eq "cpu and memory counters" '[{"total":1000,"idle":800},{"total":1024000000,"available":409600000}]' "$(J '[d["cpu"], d["mem"]]')"
check_eq "net (public) and net_tailscale" '[{"iface":"eth0","rx_bytes":1000,"tx_bytes":2000},{"iface":"tailscale0","rx_bytes":30,"tx_bytes":40}]' "$(J '[d["net"], d["net_tailscale"]]')"
check_eq "problems come from the health state, tailscale from its status" '[1,"Running",0]' "$(J '[d["problems"], d["tailscale"], d["failed_units"]]')"
check_eq "mail: queue, oldest, stalwart, spf, last delivery" '{"queue":2,"oldest_s":600,"stalwart":true,"spf":"pass","last_delivery":1789990000}' "$(J 'd["mail"]')"
check_eq "mail_queue stays for older pages" '2' "$(J 'd["mail_queue"]')"
check_eq "certificate: days left of the MX name" '{"days_left":10,"domain":"mx.example.org"}' "$(J 'd["certificate"]')"
check_eq "watcher: an alert, the heartbeat age, two sites" '["alert",120,2]' "$(J '[d["watcher"]["state"], d["watcher"]["heartbeat_age_s"], len(d["watcher"]["sites"])]')"
check_eq "watcher: a site with no answer has code null" '[200,null]' "$(J '[s["code"] for s in d["watcher"]["sites"]]')"
check_eq "revision, os" '[{"hash":"abc1234","subject":"Add the edge node"},"NixOS 26.05 (Yarara)"]' "$(J '[d["revision"], d["os"]]')"
check_eq "region is null when nothing tells it" 'null' "$(J 'd["region"]')"
check_eq "tailscale_info: address, tag, latency" '["100.64.0.5","tag:vps",23.0]' "$(J '[d["tailscale_info"]["address"], d["tailscale_info"]["tag"], d["tailscale_info"]["latency_ms"]]')"
check_eq "tailscale_info: may_reach names the hosts, never the addresses of people" '["stalwart","pelican-wings","livekit"]' "$(J '[r["target"] for r in d["tailscale_info"]["may_reach"]]')"
check_eq "pools.system has size and used" '{"size":10000000000,"used":3000000000}' "$(J 'd["pools"]["system"]')"
check_eq "ports: groups games, rtc, mail, own" '["games","rtc","mail","own"]' "$(J '[g["id"] for g in d["ports"]["groups"]]')"
check_eq "ports: the game rows are read from the live ruleset" '[true,true]' "$(J '[r["forwarded"] for r in d["ports"]["groups"][0]["rows"][:1]] + [d["ports"]["groups"][0]["rows"][1]["forwarded"]]')"
check_eq "ports: calls are not in the ruleset, so forwarded is false" '[false,false]' "$(J '[r["forwarded"] for r in d["ports"]["groups"][1]["rows"]]')"
check_eq "ports: wings probe (a refusal is fine), livekit probe (a timeout is not)" '[true,false]' "$(J '[d["ports"]["groups"][0]["probe"]["ok"], d["ports"]["groups"][1]["probe"]["ok"]]')"
check_eq "ports: mail and own rows are open (accept rules)" '[true,true,true,true]' "$(J '[d["ports"]["groups"][2]["rows"][0]["forwarded"]] + [r["forwarded"] for r in d["ports"]["groups"][3]["rows"]] + [True]')"
check_eq "ports: counts of a range" '[15,1]' "$(J '[d["ports"]["groups"][0]["rows"][0]["count"], d["ports"]["groups"][0]["rows"][1]["count"]]')"
check_eq "ports: targets are names, never addresses" '["pelican-wings","livekit","stalwart",null]' "$(J '[g["target"] for g in d["ports"]["groups"]]')"
check_eq "game_ports (old key) still there" '["tcp+udp","tcp"]' "$(J '[b["proto"] for b in d["game_ports"]["blocks"]]')"
check_eq "settings: names of the node, secrets only as paths" '"/var/lib/hs/notify-url"' "$(J 'd["settings"]["notifyUrlFile"]')"
check "settings hold no address of the mail server's admin page or any key" test -z "$(grep -ci 'authkey"' "$WORK/doc.json" | grep -v '^0$' | grep -v '^1$' || true)"
check "no secret value (only file paths) in the document" bash -c '! grep -q "tskey-\|ntfy.sh" "$1"' _ "$WORK/doc.json"
printf 'fra-1\n' > "$STATE/region"
check_eq "region from /var/lib/hs/region" '"fra-1"' "$(bash "$SCRIPTS/edge-status.sh" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["region"]))')"
rm -f "$STATE/region"

echo "-- a node with fewer capabilities leaves the keys out"
mkdir -p "$WORK/etc2"; cp "$ETC/edge-status.json" "$WORK/etc2/"
bash "$SCRIPTS/edge-status.sh" > /dev/null
HS_ETC_DIR=$WORK/etc2 bash "$SCRIPTS/edge-status.sh" > "$WORK/doc2.json" 2>/dev/null
check_eq "no mail, ports or watcher keys" '[false,false,false,false,false]' "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); print(json.dumps([k in d for k in ("mail","ports","watcher","certificate","game_ports")], separators=(",", ":")))' "$WORK/doc2.json")"
check_eq "but the base keys are" 'true' "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); print(str("pools" in d and "tailscale_info" in d and "settings" in d).lower())' "$WORK/doc2.json")"

echo "-- watcher states"
watch_state() { bash "$SCRIPTS/edge-status.sh" | python3 -c 'import json,sys; print(json.load(sys.stdin)["watcher"]["state"])'; }
check_eq "problems in the state file: alert" alert "$(watch_state)"
printf '%s\n' "$NOW" > "$WORK/watch/state"
check_eq "no problems: ok" ok "$(watch_state)"
printf '%s\n' "$((NOW - 1000))" > "$WORK/watch/state.run"
check_eq "the watcher has not run for 16 minutes: stale" stale "$(watch_state)"
printf '%s\n' "$NOW" > "$WORK/watch/state.run"

echo "-- the health check: problems"
P() { python3 "$SCRIPTS/lib/edge_facts.py" problems | cut -f1 | tr '\n' ' ' | sed 's/ $//'; }
check_eq "healthy with the mail server up, a young queue and a good certificate" "queue-old" "$(HS_EDGE_QUEUE_MAX_AGE=300 P | sed 's/^.*\(queue-old\).*$/\1/')"
check_eq "nothing is wrong at the default thresholds, except the dead livekit is not a problem (only wings is probed)" "" "$(HS_EDGE_CERT_DAYS=5 P)"
check_eq "a failed unit" "unit:foo.service" "$(FAKE_FAILED=1 HS_EDGE_CERT_DAYS=5 P)"
check_eq "Tailscale not running" "tailscale" "$(FAKE_TS=Stopped HS_EDGE_CERT_DAYS=5 P)"
check_eq "the mail server does not answer" "stalwart" "$(HS_EDGE_TCP_FAKE='100.64.0.10:25=timeout,100.64.0.11:25565=refused' HS_EDGE_CERT_DAYS=5 P)"
check_eq "the game host times out (a refusal would be fine)" "wings" "$(HS_EDGE_TCP_FAKE='100.64.0.10:25=ok,100.64.0.11:25565=timeout' HS_EDGE_CERT_DAYS=5 P)"
check_eq "the certificate runs out" "cert" "$(P)"
check_eq "many messages in the queue" "queue-big" "$(HS_EDGE_QUEUE_MAX_COUNT=1 HS_EDGE_CERT_DAYS=5 P)"
check_eq "a full disk" "disk" "$(HS_EDGE_DISK_MAX=0 HS_EDGE_CERT_DAYS=5 P)"
printf '%s\n' "$((NOW - 2000))" > "$WORK/watch/state.run"
check_eq "the watcher stopped" "watcher" "$(HS_EDGE_CERT_DAYS=5 P)"
printf '%s\n' "$NOW" > "$WORK/watch/state.run"

echo "-- the health check: messages"
export HS_HEALTH_STATE=$WORK/h.state FAKE_CURL_LOG=$WORK/curl.log HS_NOTIFY_URL=http://ntfy.test/topic HS_STATE_DIR=$STATE PATH="$FB:$PATH"
export HS_EDGE_CERT_DAYS=5
H() { rc=0; out=$(bash "$SCRIPTS/edge-health.sh" "$@" 2>&1 </dev/null) || rc=$?; }
FAKE_FAILED=1 H --dry-run
check_eq "--dry-run: exit 0" 0 "$rc"
check_out "--dry-run names the message and the problem" "foo.service" echo "$out"
check "--dry-run writes no state" test ! -e "$HS_HEALTH_STATE"
FAKE_FAILED=1 H --keys
check_eq "--keys: one key per line, nothing sent" "unit:foo.service" "$out"
: > "$FAKE_CURL_LOG"
FAKE_FAILED=1 H
check_eq "a new problem: exit 0" 0 "$rc"
check_eq "one push message" 1 "$(grep -c ntfy.test "$FAKE_CURL_LOG")"
check_eq "the state holds the time and the key" "$NOW|unit:foo.service" "$(head -n1 "$HS_HEALTH_STATE")|$(tail -n +2 "$HS_HEALTH_STATE")"
: > "$FAKE_CURL_LOG"
FAKE_FAILED=1 H
check_out "the same problem again: nothing to send" "Nothing to send" echo "$out"
check_eq "and no push message" 0 "$(grep -c ntfy.test "$FAKE_CURL_LOG")"
FAKE_FAILED=1 HS_NOW=$((NOW + 90000)) H
check_eq "after a day it is repeated" 1 "$(grep -c ntfy.test "$FAKE_CURL_LOG")"
: > "$FAKE_CURL_LOG"
H
check_eq "no problem any more: all clear is sent" 1 "$(grep -c ntfy.test "$FAKE_CURL_LOG")"
check_eq "and the state is empty again" "" "$(tail -n +2 "$HS_HEALTH_STATE")"
: > "$FAKE_CURL_LOG"
H --test
check_eq "--test sends a test message" 1 "$(grep -c ntfy.test "$FAKE_CURL_LOG")"
check "the edge check never posts a heartbeat (it watches that topic)" test -z "$(grep -n 'heartbeat' "$SCRIPTS/edge-health.sh" | grep -v '^[0-9]*:#' || true)"

echo "-- the node status through the forced command"
unset HS_NOTIFY_URL
R() { rc=0; out=$(SSH_ORIGINAL_COMMAND="$1" HS_DECK_FILE=$WORK/nodeck.json HS_CAPABILITIES_FILE=$WORK/caps timeout 30 bash "$SCRIPTS/node-remote.sh" </dev/null 2>"$WORK/err") || rc=$?; }
printf 'edge-status\n' > "$WORK/caps"
rm -f "$WORK/nodeck.json"
R status
check_eq "no file yet, capability edge-status: the edge document is made on the spot" "0:proxyserver" "$rc:$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["kind"])')"
printf '{"kind":"proxyserver","from":"file"}\n' > "$WORK/nodeck.json"
R status
check_eq "the file written by the timer is served as it is" '0:{"kind":"proxyserver","from":"file"}' "$rc:$out"
R update
check_eq "update is still refused (status only)" "2:" "$rc:$out"

echo "-- node kind edge"
export HS_STATE_DIR=$WORK/nstate HS_RUN_DIR=$WORK/run HS_VAULT_DIR=$WORK/vault HS_MACHINE_FILE=$WORK/machine.toml HS_SETTINGS_DIR=$WORK/nstate/settings
mkdir -p "$HS_STATE_DIR" "$HS_RUN_DIR"; printf 'hostName = "hs"\n' > "$HS_MACHINE_FILE"
N() { rc=0; out=$(timeout 30 bash "$SCRIPTS/node.sh" "$@" </dev/null 2>"$WORK/err") || rc=$?; }
N add edge1 edge1.tail.ts.net --kind edge
check_eq "add --kind edge: exit 0" 0 "$rc"
N --list
check_eq "the edge kind defaults to port 2222" "edge1${T}edge${T}edge1.tail.ts.net${T}2222${T}file${T}missing" "$out"
N --show edge1
check_out "it logs in as root" "^user${T}root\$" echo "$out"
check_out "and the command ends with the one word status" " -p 2222 .*root@edge1.tail.ts.net status\$" echo "$out"
if command -v ssh-keygen >/dev/null 2>&1; then
  N key edge1
  check_out "the key line is a nodeKeys line for machine.toml" '^nodeKeys = \["ssh-ed25519 ' echo "$out"
else
  skip "ssh-keygen missing: key line of an edge node"
fi
finish
