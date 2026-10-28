#!/usr/bin/env bash
# hs ports (scripts/ports.sh) against stand-ins for incus and ss. No root needed.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1
B=$WORK/fake; mkdir -p "$B/state"
export HS_STATE_DIR=$B/state HS_HOST_ADDRS="10.10.10.95 192.168.1.5"
P="bash $SCRIPTS/ports.sh"

cat > "$B/ss-host" <<'FAKE'
#!/usr/bin/env bash
cat <<'EOF'
tcp   LISTEN 0 128  0.0.0.0:22     0.0.0.0:*  users:(("sshd",pid=1,fd=3))
tcp   LISTEN 0 128  [::]:22        [::]:*     users:(("sshd",pid=1,fd=4))
tcp   LISTEN 0 4096 *:8443         *:*        users:(("incusd",pid=2,fd=5))
tcp   LISTEN 0 10   127.0.0.1:631  0.0.0.0:*
tcp   LISTEN 0 10   0.0.0.0:6379   0.0.0.0:*  users:(("redis-server",pid=3,fd=6))
udp   UNCONN 0 0    0.0.0.0:5353   0.0.0.0:*
udp   UNCONN 0 0    127.0.0.53%lo:53 0.0.0.0:*
EOF
FAKE
chmod +x "$B/ss-host"
export HS_SS="bash $B/ss-host"

cat > "$B/incus" <<'FAKE'
#!/usr/bin/env bash
dir=$(dirname "$0")
case "$1" in
  list) cat "$dir/list.csv" ;;
  exec)
    ct=$2; shift 3
    case "$1" in
      ss)
        if [ "$ct" = zoraxy ] && [ "$4" = state ]; then cat "$dir/zoraxy-live" 2>/dev/null; exit 0; fi
        [ -f "$dir/ss-$ct" ] || exit 1
        cat "$dir/ss-$ct" ;;
      sh) [ ! -f "$dir/zoraxy-rules" ] || cat "$dir/zoraxy-rules" ;;
    esac ;;
esac
FAKE
chmod +x "$B/incus"
export HS_INCUS=$B/incus

cat > "$B/list.csv" <<'EOF'
zoraxy,RUNNING,CONTAINER,10.10.95.11 (eth0)
docker,RUNNING,CONTAINER,"10.10.95.20 (eth0)
172.17.0.1 (docker0)"
homepage,RUNNING,CONTAINER,10.10.95.21 (eth0)
webapp,RUNNING,CONTAINER,10.10.95.22 (eth0)
pelican-panel,RUNNING,CONTAINER,10.10.95.30 (eth0)
noss,RUNNING,CONTAINER,10.10.95.50 (eth0)
dc1,RUNNING,VIRTUAL-MACHINE,10.10.95.40 (enp5s0)
old,STOPPED,CONTAINER,
EOF
printf 'tcp LISTEN 0 4096 0.0.0.0:80 0.0.0.0:* users:(("caddy",pid=1,fd=3))\ntcp LISTEN 0 4096 *:8000 *:* users:(("zoraxy",pid=2,fd=3))\n' > "$B/ss-zoraxy"
printf 'tcp LISTEN 0 511 *:80 *:* users:(("node",pid=1,fd=3))\ntcp LISTEN 0 511 *:3333 *:* users:(("node",pid=4,fd=3))\n' > "$B/ss-docker"
printf 'tcp LISTEN 0 511 *:80 *:* users:(("nginx",pid=1,fd=3))\n' > "$B/ss-homepage"
printf 'tcp LISTEN 0 511 *:8080 *:* users:(("app",pid=1,fd=3))\ntcp LISTEN 0 511 127.0.0.1:9000 *:*\n' > "$B/ss-webapp"
printf 'tcp LISTEN 0 511 *:80 *:* users:(("nginx",pid=1,fd=3))\n' > "$B/ss-pelican-panel"
cat > "$B/zoraxy-rules" <<'EOF'
## /opt/zoraxy/conf/proxy/arcane.example.com.config
{"RootOrMatchingDomain":"arcane.example.com","Domain":"10.10.95.20:80","RequireTLS":false}
## /opt/zoraxy/conf/proxy/app.example.com.config
{
  "RootOrMatchingDomain": "app.example.com",
  "ActiveOrigins": [
    { "OriginIpOrDomain": "10.10.95.22:8080", "RequireTLS": false }
  ]
}
## /opt/zoraxy/conf/proxy/incus.example.com.config
{"RootOrMatchingDomain":"incus.example.com","ActiveOrigins":[{"OriginIpOrDomain":"10.10.10.95:8443"}]}
## /opt/zoraxy/conf/proxy/panel.example.com.config
{"RootOrMatchingDomain":"panel.example.com","Domain":"http://10.10.95.30"}
## /opt/zoraxy/conf/proxy/ghost.example.com.config
{"RootOrMatchingDomain":"ghost.example.com","Domain":"10.10.95.77:80"}
## /opt/zoraxy/conf/proxy/home.example.com.config
{"RootOrMatchingDomain":"home.example.com","Domain":"homepage"}
EOF

echo "-- listeners"
out=$($P --list)
check_eq "ssh on the host is expected, once (v4 and v6 merged)" "1" "$(awk -F'\t' '$1=="listen" && $2=="host" && $4==22' <<<"$out" | grep -c .)"
check_eq "Incus is an admin interface" "admin" "$(awk -F'\t' '$1=="listen" && $2=="host" && $4==8443 {print $7}' <<<"$out")"
check_eq "an unknown listener is unexpected" "unexpected" "$(awk -F'\t' '$1=="listen" && $2=="host" && $4==6379 {print $7}' <<<"$out")"
check_eq "the process name is shown" "redis-server" "$(awk -F'\t' '$1=="listen" && $4==6379 {print $6}' <<<"$out")"
check_eq "loopback-only sockets are left out" "0" "$(awk -F'\t' '$4==631 || $4==53' <<<"$out" | grep -c .)"
check_eq "a wildcard bind is shown as all" "all" "$(awk -F'\t' '$1=="listen" && $2=="host" && $4==22 {print $5}' <<<"$out")"
check_eq "Zoraxy's admin port is an admin interface in its container" "admin" "$(awk -F'\t' '$1=="listen" && $2=="zoraxy" && $4==8000 {print $7}' <<<"$out")"
check_eq "port 80 of the docker container is Arcane" "admin" "$(awk -F'\t' '$1=="listen" && $2=="docker" && $4==80 {print $7}' <<<"$out")"
check_eq "docker apps are expected on any port" "expected" "$(awk -F'\t' '$1=="listen" && $2=="docker" && $4==3333 {print $7}' <<<"$out")"
check_eq "a webapp port outside the list is unexpected" "unexpected" "$(awk -F'\t' '$1=="listen" && $2=="webapp" && $4==8080 {print $7}' <<<"$out")"
check_eq "a container without ss is reported" "no-ss" "$(awk -F'\t' '$1=="listen" && $2=="noss" {print $7}' <<<"$out")"
check_eq "a stopped container is not asked" "0" "$(awk -F'\t' '$2=="old"' <<<"$out" | grep -c .)"
printf 'webapp 8080\nwebapp 9000-9100\n' > "$B/state/ports-expected"
out2=$($P --list)
check_eq "ports-expected adds expected ports" "expected" "$(awk -F'\t' '$1=="listen" && $2=="webapp" && $4==8080 {print $7}' <<<"$out2")"
rm -f "$B/state/ports-expected"

echo "-- Zoraxy rules"
check_eq "exit code 1 when an admin interface is proxied" "1" "$($P --list >/dev/null; echo $?)"
check_eq "Arcane behind Zoraxy warns (old field names)" "WARN" "$(awk -F'\t' '$1=="proxy" && $2=="docker" && $4==80 {print $7}' <<<"$out")"
check_eq "the host name of the rule is shown" "arcane.example.com" "$(awk -F'\t' '$1=="proxy" && $2=="docker" {print $5}' <<<"$out")"
check_eq "a normal app is ok (new field names, pretty JSON)" "ok" "$(awk -F'\t' '$1=="proxy" && $2=="webapp" {print $7}' <<<"$out")"
check_eq "Incus on the host address warns" "WARN" "$(awk -F'\t' '$1=="proxy" && $2=="host" && $4==8443 {print $7}' <<<"$out")"
check_eq "a target without a port means 80; the panel is info" "info" "$(awk -F'\t' '$1=="proxy" && $2=="pelican-panel" && $4==80 {print $7}' <<<"$out")"
check_eq "a target that is no instance is unknown" "unknown" "$(awk -F'\t' '$1=="proxy" && $2=="?" {print $7}' <<<"$out")"
check_eq "a container name as target works" "WARN" "$(awk -F'\t' '$1=="proxy" && $2=="homepage" {print $7}' <<<"$out")"
check_eq "the source is the rule files" "rules" "$(awk -F'\t' '$1=="proxy" && $2=="webapp" {print $6}' <<<"$out")"
check_eq "--list needs no header and every line has 8 fields" "" "$(awk -F'\t' 'NF != 8' <<<"$out")"
printf 'panel.example.com\n' >/dev/null

echo "-- the readable table"
tab=$($P || true)
check_out "table has a listener heading" "Where +Proto +Port" echo "$tab"
check_out "the warning names the rule" "Arcane\) is reachable from the internet through the Zoraxy rule for 'arcane.example.com'" echo "$tab"
check_out "a hint for unexpected ports" "ports-expected" echo "$tab"
check_eq "exit code 1 in the readable form too" "1" "$($P >/dev/null; echo $?)"
one=$($P webapp --list || true)
check_eq "one container only" "0" "$(awk -F'\t' '$1=="listen" && ($2=="docker" || $2=="zoraxy")' <<<"$one" | grep -c .)"
check_out "an unknown container is refused" "No running instance called 'ghost'" $P ghost

echo "-- fallback: live connections when no rule file can be read"
mv "$B/zoraxy-rules" "$B/zoraxy-rules.off"
printf '0 0 10.10.95.11:50000 10.10.95.22:8080\n0 0 10.10.95.11:50001 10.10.95.22:8080\n0 0 10.10.95.11:80 10.10.95.99:41000\n' > "$B/zoraxy-live"
live=$($P --list); rc=$?
check_eq "only outgoing connections count, once each" "1" "$(grep -c '^proxy' <<<"$live")"
check_eq "the source says live" "live" "$(awk -F'\t' '$1=="proxy" {print $6}' <<<"$live")"
check_eq "no warning, exit 0" "0" "$rc"
printf '0 0 10.10.95.11:50002 10.10.95.20:80\n' >> "$B/zoraxy-live"
check_eq "a live connection to Arcane warns" "1" "$($P --list >/dev/null; echo $?)"
rm -f "$B/zoraxy-live"
check_out "nothing readable says so" "found nothing" $P

echo "-- Zoraxy is not there"
grep -v '^zoraxy' "$B/list.csv" > "$B/list2.csv"; cp "$B/list2.csv" "$B/list.csv"
check_out "the check is skipped with a note" "proxy check was skipped" $P
check_eq "and the exit code is 0" "0" "$($P >/dev/null; echo $?)"

finish
