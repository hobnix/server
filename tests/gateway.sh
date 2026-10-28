#!/usr/bin/env bash
# The gateway proxy (capabilities/gateway): the route file renderer (golden files), hs gateway status|routes|check against stand-ins.
# No root, no Traefik, no server: every place it looks at is a knob.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test HS_PYTHON=python3
export MSYS2_ARG_CONV_EXCL='*'   # Git Bash on Windows would turn arguments like /api into a Windows path (no effect elsewhere)
export HS_GATEWAY_DIR=$WORK/gw HS_ETC_DIR=$WORK/etc HS_MACHINE_FILE=$WORK/machine.toml HS_SITE_NAME_FILE=$WORK/site-name
export HS_GATEWAY_UNIT_STATE=$WORK/unit HS_GATEWAY_LISTENERS=$WORK/listeners HS_GATEWAY_RESOLVE=$WORK/resolve HS_HOST_IP=192.168.1.10
export HS_GATEWAY_RESOLV_CONF=$WORK/resolv.conf
R="python3 $SCRIPTS/gateway_render.py"
G="bash $SCRIPTS/gateway.sh"
T=$'\t'
mkdir -p "$HS_GATEWAY_DIR/routes" "$HS_ETC_DIR"
printf 'hostName = "homeserver"\nadDomain = { realm = "AD.EXAMPLE.ORG", workgroup = "EX" }\n' > "$HS_MACHINE_FILE"
echo homeserver > "$HS_SITE_NAME_FILE"
printf 'nameserver 192.168.1.2\n' > "$HS_GATEWAY_RESOLV_CONF"

echo "-- render: golden files"
root_golden="# hs-gateway local v1 host=app.home.example.org
# route path=/ target=192.168.1.50:8080
# written by hs services apply (gateway proxy); do not edit
http:
  routers:
    l-app-home-example-org-root:
      entryPoints: [lan-http]
      rule: 'Host(\`app.home.example.org\`)'
      middlewares: [hs-lan-only]
      service: l-app-home-example-org-root
  services:
    l-app-home-example-org-root:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: 'http://192.168.1.50:8080'"
check_eq "a root route" "$root_golden" "$($R local app.home.example.org /=192.168.1.50:8080)"
out=$($R local app.home.example.org /=192.168.1.50:8080 /api=https://192.168.1.50:8443)
check_out "a path route has PathPrefix" "rule: 'Host\(.app.home.example.org.\) && PathPrefix\(.\/api.\)'" echo "$out"
check_out "its router id has the path and a hash" "^    l-app-home-example-org-api-[0-9a-f]{6}:" echo "$out"
check_eq "paths /a_b and /a/b get different router ids" "2" "$($R local x.example.org /a_b=1.2.3.4:80 /a/b=1.2.3.4:80 | grep -E '^    l-x-example-org-[a-z_0-9-]+:$' | sort -u | wc -l | tr -d ' ')"
check_out "an https target uses the insecure transport" "serversTransport: hs-insecure" echo "$out"
check_out "and keeps the scheme in its url" "url: 'https://192.168.1.50:8443'" echo "$out"
check_eq "the http route has no transport" "1" "$(grep -c serversTransport <<<"$out")"

echo "-- render: bad input is refused"
check "a bad host" bash -c "! $R local 'Bad Host' /=1.2.3.4:80"
check "a host with a quote" bash -c "! $R local \"a'b.example.org\" /=1.2.3.4:80"
check "a bad path" bash -c "! $R local app.example.org '/a b'=1.2.3.4:80"
check "a path without a slash" bash -c "! $R local app.example.org api=1.2.3.4:80"
check "a target without a port" bash -c "! $R local app.example.org /=1.2.3.4"
check "a target with a scheme other than https" bash -c "! $R local app.example.org /=http://1.2.3.4:80"
check "a target with a quote" bash -c "! $R local app.example.org \"/=1.2.3.4:80'x\""

echo "-- read: the round trip"
$R local app.home.example.org /=192.168.1.50:8080 /api=https://192.168.1.50:8443 > "$HS_GATEWAY_DIR/routes/local-app.home.example.org.yml"
$R local b.home.example.org /=192.168.1.51:80 > "$HS_GATEWAY_DIR/routes/local-b.home.example.org.yml"
check_eq "read gives host path target file" "$(printf 'app.home.example.org\t/\t192.168.1.50:8080\tlocal-app.home.example.org.yml\napp.home.example.org\t/api\thttps://192.168.1.50:8443\tlocal-app.home.example.org.yml\nb.home.example.org\t/\t192.168.1.51:80\tlocal-b.home.example.org.yml')" "$($R read "$HS_GATEWAY_DIR/routes")"
printf 'garbage\n' > "$HS_GATEWAY_DIR/routes/local-bad.yml"
check_eq "a file without a valid header is not read" "3" "$($R read "$HS_GATEWAY_DIR/routes" | wc -l | tr -d ' ')"
rm "$HS_GATEWAY_DIR/routes/local-bad.yml"
: > "$HS_GATEWAY_DIR/routes/00-hs-base.yml"; : > "$HS_GATEWAY_DIR/routes/pt-x.example.org.yml"; : > "$HS_GATEWAY_DIR/routes/mine.yml"
check_eq "unmanaged lists only hand-made files" "mine.yml" "$($R unmanaged "$HS_GATEWAY_DIR/routes")"

echo "-- hs sys gateway status: ports and the service"
printf 'active' > "$HS_GATEWAY_UNIT_STATE"
printf 'LISTEN 0 4096 *:80 *:* users:(("traefik",pid=1,fd=7))\n' > "$HS_GATEWAY_LISTENERS"
printf '#!/bin/sh\necho "192.168.1.10 STREAM x"\n' > "$HS_GATEWAY_RESOLVE"; chmod +x "$HS_GATEWAY_RESOLVE"
val() { $G --status | awk -F'\t' -v k="$1" '$1 == k { print $2 }'; }
check_eq "keys come in order" "service port80 public_https public_http port_public_https port_public_http domain wildcard local_routes passthrough unmanaged webui direct" "$($G --status | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
check_eq "service" active "$(val service)"
check_eq "traefik holds port 80" traefik "$(val port80)"
check_eq "no public ports by default" "off off - -" "$(val public_https) $(val public_http) $(val port_public_https) $(val port_public_http)"
check_eq "domain from adDomain and the site name" homeserver.ad.example.org "$(val domain)"
check_eq "wildcard ok" ok "$(val wildcard)"
check_eq "local routes counted" 3 "$(val local_routes)"
check_eq "passthrough counted" 1 "$(val passthrough)"
check_eq "unmanaged counted" 1 "$(val unmanaged)"
check_eq "web interface name" "http://homeserver.ad.example.org/" "$(val webui)"
check_eq "direct address" "http://192.168.1.10:8480/" "$(val direct)"
printf 'LISTEN 0 4096 0.0.0.0:80 0.0.0.0:* users:(("nginx",pid=9,fd=6))\n' > "$HS_GATEWAY_LISTENERS"
check_eq "nginx holds port 80" nginx "$(val port80)"
: > "$HS_GATEWAY_LISTENERS"
check_eq "nobody holds port 80" free "$(val port80)"
printf 'failed' > "$HS_GATEWAY_UNIT_STATE"
check_eq "a failed unit" failed "$(val service)"
printf 'https=4443\nhttp=0\n' > "$HS_ETC_DIR/gateway-public"
printf 'LISTEN 0 4096 *:4443 *:* users:(("traefik",pid=1,fd=8))\n' > "$HS_GATEWAY_LISTENERS"
check_eq "public https port shown" "4443 off traefik -" "$(val public_https) $(val public_http) $(val port_public_https) $(val port_public_http)"
rm -f "$HS_ETC_DIR/gateway-public"

echo "-- hs gateway status (people)"
check_out "warns about a stopped service" "not running" $G status
printf 'LISTEN 0 4096 0.0.0.0:80 0.0.0.0:* users:(("nginx",pid=9,fd=6))\n' > "$HS_GATEWAY_LISTENERS"
printf 'active' > "$HS_GATEWAY_UNIT_STATE"
check_out "warns about a port held by another process" "held by nginx" $G status
: > "$HS_GATEWAY_LISTENERS"
check_out "all well" "running and the wildcard" $G status
check "no colour with HS_PLAIN=1" bash -c "! $G status | grep -q \$'\\033'"

echo "-- the wildcard check"
check "ok: exit 0 and no output" bash -c "[ -z \"\$($G --check-wildcard)\" ] && $G --check-wildcard"
check_out "check says it points here" "points at this server \(192.168.1.10\)" $G check
printf '#!/bin/sh\necho "192.168.1.99 STREAM x"\n' > "$HS_GATEWAY_RESOLVE"
check "wrong address: exit 1" bash -c "! $G --check-wildcard"
check_eq "status says wrong" wrong "$(val wildcard)"
check_out "check prints the samba-tool line from the settings" "samba-tool dns add 192.168.1.2 ad.example.org '\*.homeserver' A 192.168.1.10 -U Administrator" $G check
check_out "and the Windows way" "zone ad.example.org > homeserver > New Host, name \*, address 192.168.1.10" $G check
printf 'nameserver 10.0.0.7\n' > "$HS_GATEWAY_RESOLV_CONF"; echo foo > "$HS_SITE_NAME_FILE"; HS_HOST_IP=10.1.1.1
check_out "the line follows the settings, not a constant" "samba-tool dns add 10.0.0.7 ad.example.org '\*.foo' A 10.1.1.1" env HS_HOST_IP=10.1.1.1 $G check
echo homeserver > "$HS_SITE_NAME_FILE"
printf '#!/bin/sh\nexit 0\n' > "$HS_GATEWAY_RESOLVE"
check "no answer: exit 1" bash -c "! $G --check-wildcard"
check_eq "status says missing" missing "$(val wildcard)"
printf 'hostName = "homeserver"\n' > "$HS_MACHINE_FILE"
check "no adDomain: exit 1" bash -c "! $G --check-wildcard"
check_eq "status wildcard is a dash" "-" "$(val wildcard)"
check_eq "and the domain" "-" "$(val domain)"
check_out "check says why" "needs adDomain" $G check

echo "-- hs sys gateway routes"
printf 'hostName = "homeserver"\nadDomain = { realm = "AD.EXAMPLE.ORG", workgroup = "EX" }\n' > "$HS_MACHINE_FILE"
printf '# hs-gateway passthrough v1 domain=vpn.example.org address=192.168.1.60 https=443 http=- proxy=off\n' > "$HS_GATEWAY_DIR/routes/pt-vpn.example.org.yml"
printf 'hostName = "homeserver"\nwebUi = true\nadDomain = { realm = "AD.EXAMPLE.ORG", workgroup = "EX" }\n' > "$HS_MACHINE_FILE"
rows=$($G --routes)
check_eq "every row has five fields" "" "$(awk -F'\t' 'NF != 5' <<<"$rows")"
check_eq "kinds" "base local passthrough unmanaged" "$(cut -f1 <<<"$rows" | sort -u | tr '\n' ' ' | sed 's/ $//')"
check_out "a local route" "^local${T}app.home.example.org${T}/api${T}https://192.168.1.50:8443${T}local-app" echo "$rows"
check_out "a passthrough route" "^passthrough${T}vpn.example.org${T}-${T}192.168.1.60:443${T}pt-vpn" echo "$rows"
check_out "an unmanaged file has dashes" "^unmanaged${T}-${T}-${T}-${T}mine.yml" echo "$rows"
check_out "the web interface name" "^base${T}homeserver.ad.example.org${T}/" echo "$rows"
printf '# hs-gateway passthrough v1 domain=old.example.org https=443\n' > "$HS_GATEWAY_DIR/routes/pt-old.example.org.yml"
check_out "a passthrough file without address has a dash" "^passthrough${T}old.example.org${T}-${T}-${T}pt-old" $G --routes
printf 'hostName = "homeserver"\nadDomain = { realm = "AD.EXAMPLE.ORG", workgroup = "EX" }\n' > "$HS_MACHINE_FILE"
check_eq "no base rows while webUi is off" "0" "$($G --routes | grep -c '^base' || true)"
check_out "hs gateway routes draws a table" "Kind +Host +Path +Target" $G routes
finish
