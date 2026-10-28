#!/usr/bin/env bash
# The extension passthrough (capabilities/passthrough): golden route files, the guard, plan/start of add and remove, the list/state/status shapes.
# No root, no Traefik, no network: every place it looks at is a knob.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test HS_PYTHON=python3
unset HS_GUIDED_TTY
export MSYS2_ARG_CONV_EXCL='*'
P=$ROOT/capabilities/passthrough
export HS_SCRIPTS=$SCRIPTS
export HS_GATEWAY_DIR=$WORK/gw HS_GATEWAY_PUBLIC_FILE=$WORK/etc/gateway-public HS_CAPABILITIES_FILE=$WORK/caps HS_STATE_DIR=$WORK/state
export HS_SETTINGS_DIR=$WORK/settings HS_MACHINE_FILE=$WORK/machine.toml HS_SITE_NAME_FILE=$WORK/site-name
export HS_PT_HOST_ADDRS=$WORK/host-addrs HS_PT_INSTANCE_ADDRS=$WORK/inst-addrs HS_PT_PROXY_HOSTS=$WORK/proxy-hosts
export HS_GATEWAY_LISTENERS=$WORK/listeners HS_ETC_DIR=$WORK/etc HS_GATEWAY_UNIT_STATE=$WORK/unit HS_PT_PROBE=$WORK/probe
mkdir -p "$HS_GATEWAY_DIR/routes" "$HS_GATEWAY_DIR/tmp" "$HS_SETTINGS_DIR" "$HS_STATE_DIR" "$HS_ETC_DIR"
R="python3 $P/passthrough.py"
C="bash $P/passthrough-change.sh"
S="bash $P/passthrough.sh"
RT=$HS_GATEWAY_DIR/routes
T=$'\t'
echo gateway > "$HS_CAPABILITIES_FILE"
printf 'https=443\nhttp=80\n' > "$HS_GATEWAY_PUBLIC_FILE"
printf 'hostName = "homeserver"\nadDomain = { realm = "AD.HOME.TEST", workgroup = "EX" }\n' > "$HS_MACHINE_FILE"
echo homeserver > "$HS_SITE_NAME_FILE"
printf 'example.org,example.net\n' > "$HS_SETTINGS_DIR/proxyDomains"
printf '2: br0    inet 192.168.1.10/24 brd 192.168.1.255 scope global br0\n2: br0    inet6 fd00::10/64 scope global\n' > "$HS_PT_HOST_ADDRS"
printf '10.10.95.5 (eth0)\n' > "$HS_PT_INSTANCE_ADDRS"
printf 'public.example.io\n' > "$HS_PT_PROXY_HOSTS"
echo active > "$HS_GATEWAY_UNIT_STATE"; : > "$HS_GATEWAY_LISTENERS"
printf '#!/usr/bin/env bash\ncase "$1" in 192.168.1.20) exit 0 ;; esac\nexit 1\n' > "$WORK/probe"; chmod +x "$WORK/probe"
run() { rc=0; out=$(timeout 30 "$@" </dev/null 2>/dev/null) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }
refused() {   # refused <what> <text> <args of plan>
  local what=$1 text=$2; shift 2
  run $C plan "$@"
  if [ "$rc" = 1 ] && has "^reason${T}.*$text"; then pass "$what"; else fail "$what: rc=$rc $out"; fi
}

echo "-- render: golden files"
g1="# hs-gateway passthrough v1 domain=a.example.com address=192.168.1.20 https=443 http=80 proxy=off
# written by hs ext passthrough; do not edit
tcp:
  routers:
    pt-a-example-com:
      entryPoints: [public-https]
      rule: 'HostSNI(\`a.example.com\`) || HostSNIRegexp(\`^.+\.a\.example\.com\$\`)'
      tls:
        passthrough: true
      service: pt-a-example-com
  services:
    pt-a-example-com:
      loadBalancer:
        servers:
          - address: '192.168.1.20:443'
http:
  routers:
    pt-a-example-com-http:
      entryPoints: [lan-http]
      rule: 'Host(\`a.example.com\`) || HostRegexp(\`^.+\.a\.example\.com\$\`)'
      service: pt-a-example-com-http
  services:
    pt-a-example-com-http:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: 'http://192.168.1.20:80'"
check_eq "v4, proxy off, http on port 80 (the entrypoint lan-http)" "$g1" "$($R render a.example.com 192.168.1.20 443 80 off 80)"
out=$($R render x.example.com fd00::5 443 80 on 8008)
check_out "v6 is bracketed" "address: '\[fd00::5\]:443'" echo "$out"
check_out "proxy on: PROXY protocol v2" "proxyProtocol:" echo "$out"
check_out "a public http port other than 80: entrypoint public-http" "entryPoints: \[public-http\]" echo "$out"
check_out "http url is bracketed too" "url: 'http://\[fd00::5\]:80'" echo "$out"
out=$($R render x.example.com 192.168.1.20 443 - off 80)
check_eq "http off: no http section" "0" "$(grep -c '^http:' <<<"$out")"
check_eq "proxy off: no proxyProtocol" "0" "$(grep -c proxyProtocol <<<"$out")"
out=$($R render x.example.com 192.168.1.20 443 80 off 0)
check_eq "public http 0: no http section" "0" "$(grep -c '^http:' <<<"$out")"
check_eq "the header is line 1" "1" "$(head -n 1 <<<"$out" | grep -c '^# hs-gateway passthrough v1 domain=x.example.com address=192.168.1.20 https=443 http=80 proxy=off$')"

echo "-- checks of the input"
for d in 'EXAMPLE.com' ; do check_eq "a domain is lower-cased" "example.com" "$($R domain $d)"; done
for bad in single '*.x.com' 'a.local' 'a.lan' 'a.home.arpa' 'a.internal' 'a.localhost' 'a b.com' "$(printf 'a%.0s' $(seq 1 63)).com"; do
  rc=0; $R domain "$bad" >/dev/null 2>&1 || rc=$?; check_eq "domain refused: $bad" 1 "$rc"
done
A="$R address"; K="--host-addrs $HS_PT_HOST_ADDRS --instance-addrs $HS_PT_INSTANCE_ADDRS"
check_eq "a private v4 address is fine" "192.168.1.20" "$($A 192.168.1.20 $K)"
check_eq "a ULA v6 address is fine" "fd00::5" "$($A fd00::5 $K)"
for bad in 127.0.0.1 ::1 169.254.1.1 fe80::1 8.8.8.8 0.0.0.0 224.0.0.1 192.168.1.10 fd00::10 10.10.95.5 nonsense; do
  rc=0; $A $bad $K >/dev/null 2>&1 || rc=$?; check_eq "address refused: $bad" 1 "$rc"
done
check_eq "port 443 ok" "443" "$($R port 443)"
for bad in 0 70000 abc; do rc=0; $R port $bad >/dev/null 2>&1 || rc=$?; check_eq "port refused: $bad" 1 "$rc"; done

echo "-- injection through the address or the domain"
bad_addrs=("fd00::5%a'}]" "fd00::5%eth0" $'fd00::5\nkey: x' $'192.168.1.20\n' 'fd00::5`' '192.168.1.20{x}' "192.168.1.20'")
for bad in "${bad_addrs[@]}"; do
  rc=0; $A "$bad" $K >/dev/null 2>&1 || rc=$?; check_eq "address refused: ${bad//$'\n'/\\n}" 1 "$rc"
  rc=0; $R render x.example.com "$bad" 443 80 off 80 >/dev/null 2>&1 || rc=$?; check_eq "render refuses: ${bad//$'\n'/\\n}" 2 "$rc"
done
bad_doms=($'a.example.com\n' $'a.example.com\nx: y' "a'.example.com" 'a.example.com`' 'a.example.com}' 'a{b}.example.com')
for bad in "${bad_doms[@]}"; do
  rc=0; $R domain "$bad" >/dev/null 2>&1 || rc=$?; check_eq "domain refused: ${bad//$'\n'/\\n}" 1 "$rc"
  rc=0; $R render "$bad" 192.168.1.20 443 80 off 80 >/dev/null 2>&1 || rc=$?; check_eq "render refuses domain: ${bad//$'\n'/\\n}" 2 "$rc"
done
rc=0; $R render x.example.com 192.168.1.20 $'443\nx' 80 off 80 >/dev/null 2>&1 || rc=$?; check_eq "render refuses a port with a newline" 1 "$rc"
printf '10.10.95.5 (eth0)\nfd42:1:2::5 (eth0)\n' > "$HS_PT_INSTANCE_ADDRS"
refused "a container IPv6 address" 'this server' example.com add --address fd42:1:2::5
refused "the server's own ULA" 'this server' example.com add --address fd00::10
printf '10.10.95.5 (eth0)
' > "$HS_PT_INSTANCE_ADDRS"

echo "-- plan: add"
run $C plan example.com add --address 192.168.1.20
check_eq "plan exit 0" 0 "$rc"
has "^status${T}ok$" && has "^heading${T}forward example.com and \*.example.com to 192.168.1.20$" && has "^step${T}public port 443 (TLS passthrough by SNI) -> 192.168.1.20:443$" &&
  has "^step${T}public port 80 (HTTP, Host header kept) -> 192.168.1.20:80$" && has "^command${T}" && has "^long${T}no$" && pass "plan lines" || fail "plan: $out"
has "^note${T}This server holds no certificate" && has "^note${T}DNS of example.com" && pass "plan notes" || fail "notes: $out"
check_eq "plan writes nothing" "0" "$(find "$RT" "$HS_GATEWAY_DIR/tmp" -type f | wc -l | tr -d ' ')"
run $C plan example.com add
check_eq "no address: exit 2" 2 "$rc"; has "^needs${T}address$" && pass "needs address" || fail "needs: $out"
run $C plan example.com add --address 192.168.1.20 --no-http --proxy-protocol
has "HTTP is not forwarded" && has "with PROXY protocol v2" && pass "no-http and proxy in the plan" || fail "$out"

echo "-- refusals of the common checks"
: > "$HS_CAPABILITIES_FILE"
refused "gateway not on" 'gateway proxy is off' example.com add --address 192.168.1.20
echo gateway > "$HS_CAPABILITIES_FILE"
printf 'https=0\nhttp=0\n' > "$HS_GATEWAY_PUBLIC_FILE"
refused "public https port 0" 'no public port' example.com add --address 192.168.1.20
printf 'https=443\nhttp=80\n' > "$HS_GATEWAY_PUBLIC_FILE"
refused "bad domain" 'single name' single add --address 192.168.1.20
refused "wildcard" 'wildcard' '*.x.com' add --address 192.168.1.20
refused ".local" 'home network' a.local add --address 192.168.1.20
refused "65 characters" 'longer than 64' "$(printf 'a%.0s' $(seq 1 61)).com" add --address 192.168.1.20
refused "loopback" 'private LAN' example.com add --address 127.0.0.1
refused "public address" 'private LAN' example.com add --address 8.8.8.8
refused "link-local v6" 'private LAN' example.com add --address fe80::1
refused "this server" 'this server' example.com add --address 192.168.1.10
refused "a container" 'this server' example.com add --address 10.10.95.5
refused "port 0" 'not a port' example.com add --address 192.168.1.20 --https-port 0
refused "port 70000" 'not a port' example.com add --address 192.168.1.20 --http-port 70000
refused "unknown option" 'unknown option' example.com add --address 192.168.1.20 --bogus
run $C plan Example.COM add --address 192.168.1.20
has "^heading${T}forward example.com " && pass "upper case is normalised" || fail "upper: $out"

echo "-- the guard"
refused "proxyDomains equal" 'overlaps example.org' example.org add --address 192.168.1.20
refused "under a proxyDomain" 'overlaps example.org' a.example.org add --address 192.168.1.20
printf 'sub.example.net\n' > "$HS_SETTINGS_DIR/proxyDomains"
refused "parent of a proxyDomain entry" 'overlaps sub.example.net' example.net add --address 192.168.1.20
printf 'example.org,example.net\n' > "$HS_SETTINGS_DIR/proxyDomains"
refused "the local domain" 'overlaps homeserver.ad.home.test' homeserver.ad.home.test add --address 192.168.1.20
refused "under the local domain" 'overlaps' x.homeserver.ad.home.test add --address 192.168.1.20
refused "the AD realm (with the local domain)" 'overlaps' ad.home.test add --address 192.168.1.20
check_out "the AD realm alone" "AD realm" $R guard corp.home.test --realm corp.home.test --routes $RT
refused "a host of the public proxy" 'overlaps public.example.io' public.example.io add --address 192.168.1.20
refused "under a host of the public proxy" 'overlaps public.example.io' x.public.example.io add --address 192.168.1.20
printf '# hs-gateway local v1 host=app.home.example.com\n' > "$RT/local-app.home.example.com.yml"
refused "a local- host" 'local name' home.example.com add --address 192.168.1.20
rm -f "$RT/local-app.home.example.com.yml"

echo "-- start: add, replace, remove"
run $C start example.com add --address 192.168.1.20 --proxy-protocol
check_eq "start exit 0" 0 "$rc"
has "^status${T}done$" && pass "status done" || fail "start: $out"
f=$RT/pt-example.com.yml
check_eq "the route file exists" "yes" "$([ -f "$f" ] && echo yes)"
check_eq "its header" "# hs-gateway passthrough v1 domain=example.com address=192.168.1.20 https=443 http=80 proxy=on" "$(head -n 1 "$f")"
check_eq "mode 0640" "640" "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")"
check_eq "tmp/ is empty" "0" "$(ls -A "$HS_GATEWAY_DIR/tmp" | wc -l | tr -d ' ')"
run $C plan example.com add --address 192.168.1.21
has "^warn${T}example.com is forwarded already (to 192.168.1.20): the target is replaced$" && pass "replace warns" || fail "replace: $out"
run $C start other.org add --address fd00::5 --no-http --https-port 8443
check_eq "list shape" "$(printf 'example.com\t192.168.1.20\t443\t80\ton\nother.org\tfd00::5\t8443\t-\toff')" "$($R list "$RT")"
refused "overlap with another pt- domain" 'forwarded already' sub.example.com add --address 192.168.1.20

echo "-- refresh picks up a changed public port"
printf 'https=443\nhttp=0\n' > "$HS_GATEWAY_PUBLIC_FILE"
run $C start --refresh refresh
check_eq "refresh: done" "status${T}done" "$out"
check_eq "public http 0: no http router left" "0" "$(grep -c '^http:' "$f")"
check_eq "the header keeps the http port" "yes" "$(head -n 1 "$f" | grep -q 'http=80' && echo yes)"
printf 'https=443\nhttp=80\n' > "$HS_GATEWAY_PUBLIC_FILE"
run $C start --refresh refresh
check_eq "back to 80: the http router is back" "1" "$(grep -c '^http:' "$f")"

echo "-- remove"
refused "unknown domain" 'is not forwarded' nobody.org remove
run $C plan example.com remove
has "^danger${T}Visitors of example.com and \*.example.com get no answer" && has "^confirm_name${T}example.com$" && has "^step${T}delete pt-example.com.yml" && pass "remove plan" || fail "remove plan: $out"
run $C start example.com remove
check_eq "start without --confirm: refused" 1 "$rc"
has 'type the domain to confirm: example.com' && pass "says so" || fail "$out"
run $C start example.com remove --confirm other.org
check_eq "wrong --confirm: refused" 1 "$rc"
check_eq "the file is still there" "yes" "$([ -f "$f" ] && echo yes)"
run $C start example.com remove --confirm example.com
check_eq "right --confirm: done" "status${T}done" "$out"
check_eq "the file is gone" "no" "$([ -f "$f" ] && echo yes || echo no)"
check_eq "the other domain stays" "other.org" "$($R list "$RT" | cut -f1)"

echo "-- sys shapes"
run $S --list
check_eq "--list" "$(printf 'other.org\tfd00::5\t8443\t-\toff')" "$out"
run $S --state
check_eq "--state: down by the probe, - for http off" "$(printf 'other.org\tfd00::5\tdown\t-')" "$out"
run $C start example.com add --address 192.168.1.20
run $S --state
check_eq "--state: up for the target that answers" "$(printf 'example.com\t192.168.1.20\tup\tup')" "$(grep '^example.com' <<<"$out")"
printf 'LISTEN 0 4096 *:443 *:* users:(("traefik",pid=1,fd=8))\nLISTEN 0 4096 *:80 *:* users:(("nginx",pid=2,fd=8))\n' > "$HS_GATEWAY_LISTENERS"
run $S --status
check_eq "--status" "$(printf 'gateway\ton\npublic_https\t443\npublic_http\t80\nport_public_https\ttraefik\nport_public_http\tnginx\ndomains\t2')" "$out"
run $C plan third.org add --address 192.168.1.30
has "^warn${T}the public http port is held by nginx, not by Traefik$" && pass "a foreign port holder warns" || fail "port warn: $out"
: > "$HS_GATEWAY_LISTENERS"
: > "$HS_CAPABILITIES_FILE"
run $S --status
check_out "--status with the gateway off" "^gateway${T}off$" echo "$out"
rm -f "$RT"/pt-*.yml
run $S --list
check_eq "--list is empty without a domain" "" "$out"

echo "-- hs ext passthrough through hs, with the package on"
printf 'gateway\npassthrough\n' > "$HS_CAPABILITIES_FILE"
HSB="bash $SCRIPTS/lib/hs.sh"
check_out "list is empty and says so" "No domain is forwarded yet" $HSB ext passthrough list
$HSB ext passthrough add example.com 192.168.1.20 --yes >/dev/null 2>&1
check_out "list shows the domain" "example.com" $HSB ext passthrough list
check_out "remove without a terminal and without --confirm fails" "Nobody to ask" bash -c "$HSB ext passthrough remove example.com 2>&1 </dev/null"
$HSB ext passthrough remove example.com --confirm example.com >/dev/null 2>&1
check_eq "remove --confirm deletes it" "" "$($R list "$RT")"
finish
