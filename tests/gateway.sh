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

echo "-- public: golden files (traefik-public, entrypoint public-tunnel)"
SP=$WORK/spec
spec() { local l; : > "$SP"; for l in "$@"; do printf '%s\n' "${l//@/$'\t'}" >> "$SP"; done; }
P() { $R public "$1" "$SP" "${@:2}"; }
spec 'route@app@/@127.0.0.1:1' 'route@app@/hook@10.0.0.5:8080'
out=$(P app.example.org)
check_out "paths only: the header has the spec lines" '^# spec route app /hook 10.0.0.5:8080$' echo "$out"
check_eq "a private root has no router" "" "$(grep -E 'p-app-example-org-root' <<<"$out" || true)"
check_out "the path router is on public-tunnel with priority 1005" "priority: 1005" echo "$out"
check_out "only on public-tunnel" "entryPoints: \[public-tunnel\]" echo "$out"
check_eq "a path without auth has only the strip middleware" "1" "$(grep -c 'middlewares: \[pa-app-example-org-strip\]$' <<<"$out" || true)"
spec 'route@app@/@10.0.0.5:80' 'route@app@/if/admin/@127.0.0.1:1'
out=$(P app.example.org)
check_out "a blocked path denies" "middlewares: \[hs-deny\]" echo "$out"
check_out "and goes to hs-null with priority 30010" "priority: 30010" echo "$out"
check_out "hs-null is the deny service" "service: hs-null" echo "$out"
check_out "the root real router has priority 100" "priority: 100$" echo "$out"
spec 'route@app@/@10.0.0.5:80' 'route@app@/outpost.goauthentik.io@10.0.0.9:9000' 'auth@app@10.0.0.9:9000' 'skip@app@/api'
out=$(P app.example.org)
check_out "the auth middleware address" "address: 'http://10.0.0.9:9000/outpost.goauthentik.io/auth/traefik'" echo "$out"
check_out "the root has the auth middleware" "middlewares: \[pa-app-example-org-strip, pa-app-example-org-app-auth\]" echo "$out"
check_out "the callback has priority 20000" "priority: 20000" echo "$out"
check_out "the skip router has priority 1003 (one below a real route of its own path)" "priority: 1003" echo "$out"
check_out "the skip router matches the path or below it, not /api-docs" "(Path(\`/api\`) || PathPrefix(\`/api/\`))" echo "$out"
check_eq "the skip router goes to the root service and has no auth" "1" "$(awk '/^    p-app-example-org-s-/ {f=1} f && /middlewares/ {n++} f && /service:/ {print $2; f=0}' <<<"$out" | grep -c '^p-app-example-org-root$')"
check_eq "only the root router has the auth middleware" "1" "$(grep -c 'middlewares: .*-auth\]' <<<"$out" || true)"
spec 'route@app@/@10.0.0.5:80' 'route@app@/outpost.goauthentik.io@10.0.0.9:9000' 'route@app@/apix@10.0.0.5:80' 'auth@app@10.0.0.9:9000' 'skip@app@/api'
out=$(P app.example.org)
check_eq "a route /apix is no part of the skip path /api (keeps its login)" "2" "$(grep -c 'middlewares: .*-auth\]' <<<"$out" || true)"
spec 'route@app@/@10.0.0.5:80' 'route@app@/outpost.goauthentik.io@10.0.0.9:9000' 'route@b@/api/v2@10.0.0.6:80' 'auth@app@10.0.0.9:9000' 'skip@app@/api'
out=$(P app.example.org)
check_eq "a longer path of another service beats the skip router" "1" "$(awk '/^    p-app-example-org-s-/ {f=1} f && /priority/ {print $2; f=0}' <<<"$out" | awk '$1 < 1007' | wc -l | tr -d ' ')"
spec 'route@app@/@10.0.0.5:80' 'reqh@app@X-Tag@it'"'"'s a value' 'reqh@app@x-tag@last wins' 'resh@app@X-Frame-Options@DENY'
out=$(P app.example.org)
check_out "a duplicate header name: the last wins" "'x-tag': 'last wins'" echo "$out"
check_eq "and the first is gone" "0" "$(grep -c "'X-Tag'" <<<"$out" || true)"
check_out "response headers" "customResponseHeaders:" echo "$out"
spec 'route@app@/@10.0.0.5:80' 'reqh@app@X-Tag@it'"'"'s'
check_out "a quote in a value is doubled" "'X-Tag': 'it''s'" P app.example.org
spec 'route@a@/@10.0.0.5:80' 'route@b@/hook@10.0.0.6:80' 'auth@a@10.0.0.9:9000'
out=$(P app.example.org)
check_out "service a has auth on its root" "p-app-example-org-root:.*" echo "$out"
check_eq "service b has only the strip middleware" "1" "$(grep -c 'middlewares: \[pa-app-example-org-strip\]$' <<<"$out" || true)"
spec 'route@a@/@10.0.0.5:80' 'route@a@/x@127.0.0.1:1' 'auth@a@10.0.0.9:9000' 'reqh@a@X-A@1'
check_eq "no lan entrypoint in any public file" "0" "$(P app.example.org | grep -c 'lan-http\|hs-lan-only' || true)"
P app.example.org > "$WORK/pubgold.yml"
check_eq "strip first, then auth, then headers in the middleware line" "1" "$(grep -c 'middlewares: \[pa-app-example-org-strip, pa-app-example-org-a-auth, pa-app-example-org-a-hdr\]' "$WORK/pubgold.yml")"
check_out "the strip middleware sets the forwarded host" "'X-Forwarded-Host': 'app.example.org'" cat "$WORK/pubgold.yml"
check_out "and the proto" "'X-Forwarded-Proto': 'https'" cat "$WORK/pubgold.yml"
check_out "and removes the forwarded uri" "'X-Forwarded-Uri': ''" cat "$WORK/pubgold.yml"
check_out "and the forwarded method" "'X-Forwarded-Method': ''" cat "$WORK/pubgold.yml"
check_out "and the login headers a client may send" "'X-authentik-username': ''" cat "$WORK/pubgold.yml"
check_eq "the deny router has no strip" "0" "$(grep -c 'middlewares: \[pa-app-example-org-strip, hs-deny' "$WORK/pubgold.yml" || true)"
check_eq "the strip middleware is defined once" "1" "$(grep -c '^    pa-app-example-org-strip:' "$WORK/pubgold.yml")"

echo "-- public: bad input is refused"
spec 'route@a@/@10.0.0.5:80' 'reqh@a@Bad Name@x'
check "a bad header name" bash -c "! $R public app.example.org $SP"
spec 'route@a@/@10.0.0.5:80' 'reqh@a@Host@x'
check "a refused header name" bash -c "! $R public app.example.org $SP"
spec 'route@a@/@10.0.0.5:80' 'reqh@a@X-A@a@b'
check "a value with a tab" bash -c "! $R public app.example.org $SP"
spec 'route@a@/@10.0.0.5:80' 'bogus@a@/x'
check "an unknown kind" bash -c "! $R public app.example.org $SP"
spec 'route@a@/@10.0.0.5:80' 'auth@b@10.0.0.9:9000'
check "auth of a service without a route" bash -c "! $R public app.example.org $SP"
spec 'route@a@/@10.0.0.5:80' 'auth@a@10.0.0.9:9000' 'auth@a@10.0.0.9:9001'
check "auth twice" bash -c "! $R public app.example.org $SP"
spec 'route@a@/@https://10.0.0.5:80'
check "an https target" bash -c "! $R public app.example.org $SP"
: > "$SP"
check "an empty spec file" bash -c "! $R public app.example.org $SP"

echo "-- public: direct mode (d- routers on public-https, certResolver hs-le)"
spec 'route@app@/@127.0.0.1:1' 'route@app@/hook@10.0.0.5:8080' 'route@app@/if/admin/@127.0.0.1:1'
out=$(P app.example.org --mode direct)
check_out "the header records the mode" '^# hs-gateway public v1 host=app.example.org mode=direct$' echo "$out"
check_eq "tunnel mode header has no mode" "# hs-gateway public v1 host=app.example.org" "$(P app.example.org | head -1)"
check_eq "direct: no tunnel router" "0" "$(grep -c 'public-tunnel' <<<"$out" || true)"
check_eq "direct: every router is on public-https" "2" "$(grep -c 'entryPoints: \[public-https\]' <<<"$out" || true)"
check_out "direct: the cert resolver" "certResolver: hs-le" echo "$out"
check_out "direct: the host is the certificate domain" "main: 'app.example.org'" echo "$out"
check_out "direct: the deny twin exists" "middlewares: \[hs-deny\]" echo "$out"
check_eq "direct: a private root has no router" "" "$(grep -E 'd-app-example-org-root' <<<"$out" || true)"
mixed=$(P app.example.org --mode tunnel,direct,http)
check_out "mixed: the header" '^# hs-gateway public v1 host=app.example.org mode=tunnel,direct,http$' echo "$mixed"
check_out "mixed: the redirect router is on public-http only" "entryPoints: \[public-http\]" echo "$mixed"
check_out "mixed: the redirect uses hs-to-https" "middlewares: \[hs-to-https\]" echo "$mixed"
check_eq "lan-http is never used" "0" "$(grep -c 'lan-http' <<<"$mixed" || true)"
ok=1
for n in $(grep -oE '^    p-app-example-org-[^:]+' <<<"$mixed" | sed 's/^    p-//'); do grep -q "^    d-$n:" <<<"$mixed" || ok=0; done
check_eq "mixed: every p- router has a d- twin" "1" "$ok"
check_eq "mixed: services are rendered once" "$(grep -c '^    p-app-example-org-.*:$' <<<"$(P app.example.org)")" "$(( $(grep -c '^    p-app-example-org-.*:$' <<<"$mixed") ))"
spec 'route@app@/@10.0.0.5:80'
check "http without direct" bash -c "! $R public app.example.org $SP --mode http"
check "http alone" bash -c "! $R public app.example.org $SP --mode tunnel,http"
check "an unknown mode" bash -c "! $R public app.example.org $SP --mode bogus"
check "an empty mode" bash -c "! $R public app.example.org $SP --mode ''"
check "a doubled mode" bash -c "! $R public app.example.org $SP --mode direct,direct"
check "a wrong order" bash -c "! $R public app.example.org $SP --mode direct,tunnel"

echo "-- public: read and specs on a directory with local-, pt- and pub- files"
PD=$WORK/pubdir; mkdir -p "$PD"
spec 'route@a@/@10.0.0.5:80' 'route@a@/hook@10.0.0.5:81' 'auth@a@10.0.0.9:9000' 'reqh@a@X-A@two words'
P app.example.org > "$PD/pub-app.example.org.yml"
$R local l.example.org /=1.2.3.4:80 > "$PD/local-l.example.org.yml"; : > "$PD/pt-x.example.org.yml"; : > "$PD/mine.yml"
check_eq "read --prefix pub- lists the route rows" "$(printf 'app.example.org\t/\t10.0.0.5:80\tpub-app.example.org.yml\napp.example.org\t/hook\t10.0.0.5:81\tpub-app.example.org.yml')" "$($R read "$PD" --prefix pub-)"
check_eq "read without a prefix still lists local- files" "l.example.org	/	1.2.3.4:80	local-l.example.org.yml" "$($R read "$PD")"
check_eq "specs gives host and the spec line" "$(printf 'app.example.org\troute\ta\t/\t10.0.0.5:80\napp.example.org\troute\ta\t/hook\t10.0.0.5:81\napp.example.org\tauth\ta\t10.0.0.9:9000\napp.example.org\treqh\ta\tX-A\ttwo words')" "$($R specs "$PD")"
check_eq "unmanaged does not list pub- files" "mine.yml" "$($R unmanaged "$PD")"
spec 'route@a@/@10.0.0.5:80'
P d.example.org > "$PD/pub-d.example.org.yml"
$R public e.example.org "$SP" --mode tunnel,direct > "$PD/pub-e.example.org.yml"
printf '# hs-gateway public v1 host=f.example.org mode=bogus
# spec route a / 10.0.0.5:80
' > "$PD/pub-f.example.org.yml"
printf '# hs-gateway passthrough v1 domain=pt.example.org target=1.2.3.4:443
' > "$PD/pt-pt.example.org.yml"
check_eq "modes: old header = tunnel, a mode is read, an invalid one is skipped" "$(printf 'app.example.org	tunnel
d.example.org	tunnel
e.example.org	tunnel,direct')" "$($R modes "$PD")"
check_eq "ptdomains reads the domain of pt- files" "pt.example.org" "$($R ptdomains "$PD")"
rm -f "$PD"/pub-[def]* "$PD/pt-pt.example.org.yml"

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
check_eq "keys come in order" "service port80 public_https public_http port_public_https port_public_http public_tunnel port_public_tunnel domain wildcard local_routes passthrough public_routes public_proxy acme unmanaged webui direct" "$($G --status | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
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
check_eq "no tunnel by default" "off - 0 off" "$(val public_tunnel) $(val port_public_tunnel) $(val public_routes) $(val public_proxy)"
printf 'https=0\nhttp=0\ntunnel=8081\n' > "$HS_ETC_DIR/gateway-public"
printf 'LISTEN 0 4096 *:8081 *:* users:(("traefik",pid=1,fd=8))\n' > "$HS_GATEWAY_LISTENERS"
check_eq "tunnel port shown" "8081 traefik" "$(val public_tunnel) $(val port_public_tunnel)"
check_eq "acme off without the file entry" off "$(val acme)"
rm -f "$HS_ETC_DIR/gateway-public"

echo "-- own certificates (direct mode)"
export HS_SETTINGS_DIR=$WORK/settings; mkdir -p "$HS_SETTINGS_DIR"
printf 'https=443\nhttp=80\ntunnel=0\nacme=staging\n' > "$HS_ETC_DIR/gateway-public"
check_eq "acme row" staging "$(val acme)"
check_eq "traefik-public not chosen: proxy off" off "$(val public_proxy)"
printf 'traefik-public' > "$HS_SETTINGS_DIR/reverseProxy"
check_eq "direct with traefik-public" direct "$(val public_proxy)"
printf 'https=443\nhttp=80\ntunnel=8081\nacme=production\n' > "$HS_ETC_DIR/gateway-public"
check_eq "tunnel and direct" tunnel,direct "$(val public_proxy)"
check_eq "acme production" production "$(val acme)"
printf 'https=0\nhttp=0\ntunnel=8081\nacme=off\n' > "$HS_ETC_DIR/gateway-public"
check_eq "tunnel only is unchanged" "tunnel off" "$(val public_proxy) $(val acme)"
printf 'https=443\nhttp=80\ntunnel=0\nacme=staging\n' > "$HS_ETC_DIR/gateway-public"
pubfile() { printf '# hs-gateway public v1 host=%s%s\n# spec route a / 10.0.0.5:80\n' "$1" "$2" > "$HS_GATEWAY_DIR/routes/pub-$1.yml"; }
pubfile a.example.org ' mode=direct'
pubfile b.example.org ' mode=direct,http'
pubfile c.example.org ''
pubfile d.example.org ' mode=direct'
FAKEBIN=$WORK/fakebin; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/openssl" <<'EOF'
#!/bin/sh
# stand-in: s_client answers per -servername, x509 passes the text on
case "$1" in
  s_client) while [ $# -gt 0 ]; do [ "$1" = -servername ] && n=$2; shift; done
            case "$n" in a.example.org) echo "issuer=C=US, O=(STAGING) Let's Encrypt, CN=(STAGING) Ersatz E5"; echo "notAfter=Jan  1 00:00:00 2027 GMT" ;;
                         b.example.org) echo "issuer=CN=TRAEFIK DEFAULT CERT"; echo "notAfter=Jan  1 00:00:00 2027 GMT" ;; esac ;;
  x509) cat ;;
esac
EOF
chmod +x "$FAKEBIN/openssl"
certs=$(PATH="$FAKEBIN:$PATH" $G --certs)
check_eq "certs: staging" "a.example.org${T}staging${T}Jan  1 00:00:00 2027 GMT" "$(grep '^a\.' <<<"$certs")"
check_eq "certs: default certificate" "b.example.org${T}default${T}Jan  1 00:00:00 2027 GMT" "$(grep '^b\.' <<<"$certs")"
check_eq "certs: nothing served is none" "d.example.org${T}none${T}-" "$(grep '^d\.' <<<"$certs")"
check_eq "certs: tunnel-only host has no row" 3 "$(grep -c . <<<"$certs")"
rm -f "$HS_GATEWAY_DIR/routes/pub-"*.yml "$HS_ETC_DIR/gateway-public" "$HS_SETTINGS_DIR/reverseProxy"

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
check_eq "no wildcard row for the web interface (unknown names get 404)" "0" "$(grep -c "^base${T}\*${T}/" <<<"$rows" || true)"
printf '# hs-gateway passthrough v1 domain=old.example.org https=443\n' > "$HS_GATEWAY_DIR/routes/pt-old.example.org.yml"
check_out "a passthrough file without address has a dash" "^passthrough${T}old.example.org${T}-${T}-${T}pt-old" $G --routes
printf 'hostName = "homeserver"\nadDomain = { realm = "AD.EXAMPLE.ORG", workgroup = "EX" }\n' > "$HS_MACHINE_FILE"
check_eq "no base rows while webUi is off" "0" "$($G --routes | grep -c '^base' || true)"
check_out "hs gateway routes draws a table" "Kind +Host +Path +Target" $G routes

echo "-- hs sys gateway health"
mkdir -p "$HS_SETTINGS_DIR"
printf 'hostName = "homeserver"\nadDomain = { realm = "AD.EXAMPLE.ORG", workgroup = "EX" }\n' > "$HS_MACHINE_FILE"
rm -f "$HS_GATEWAY_DIR/routes/"*.yml
printf 'active' > "$HS_GATEWAY_UNIT_STATE"
printf 'LISTEN 0 4096 *:80 *:* users:(("traefik",pid=1,fd=7))\nLISTEN 0 4096 *:8081 *:* users:(("traefik",pid=1,fd=8))\n' > "$HS_GATEWAY_LISTENERS"
printf '#!/bin/sh\necho "192.168.1.10 STREAM x"\n' > "$HS_GATEWAY_RESOLVE"
printf '#!/bin/sh\nh=${1#https://}; h=${h%%/*}\ncat "%s/code.$h" 2>/dev/null || echo 000\n' "$WORK" > "$WORK/curl"; chmod +x "$WORK/curl"
export HS_GATEWAY_CURL=$WORK/curl HS_GATEWAY_JOURNAL=$WORK/journal
: > "$HS_GATEWAY_JOURNAL"
H() { $G --health; }
hv() { H | awk -F'\t' -v i="$1" -v c="$2" '$1 == i { print $c }'; }
printf 'zoraxy' > "$HS_SETTINGS_DIR/reverseProxy"
check_eq "health: always six lines in order" "setup running reach cert dns auth" "$(H | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
check_eq "zoraxy: setup is off" off "$(hv setup 2)"
check_eq "zoraxy: reach, cert and auth are off" "off off off" "$(hv reach 2) $(hv cert 2) $(hv auth 2)"
printf 'traefik-public' > "$HS_SETTINGS_DIR/reverseProxy"
printf 'https=0\nhttp=0\ntunnel=8081\nacme=off\n' > "$HS_ETC_DIR/gateway-public"
spec 'route@app@/@10.0.0.5:80' 'auth@app@10.0.0.9:9000'
P app.example.org > "$HS_GATEWAY_DIR/routes/pub-app.example.org.yml"
check_eq "traefik-public: setup ok" ok "$(hv setup 2)"
check_eq "running ok" ok "$(hv running 2)"
printf '530' > "$WORK/code.app.example.org"
check_eq "tunnel 530: reach fails with fix connect" "fail connect 530" "$(hv reach 2) $(hv reach 3) $(hv reach 4)"
printf '200' > "$WORK/code.app.example.org"
check_eq "tunnel 200: reach ok" ok "$(hv reach 2)"
check_eq "200 on an auth host: auth fails" "fail auth" "$(hv auth 2) $(hv auth 3)"
printf '302' > "$WORK/code.app.example.org"
check_eq "302 on an auth host: auth ok" ok "$(hv auth 2)"
check_eq "no acme: cert off" off "$(hv cert 2)"
printf '#!/bin/sh\necho "x"\n' > /dev/null
printf 'inactive' > "$HS_GATEWAY_UNIT_STATE"
check_eq "a stopped service fails running" fail "$(hv running 2)"
printf 'active' > "$HS_GATEWAY_UNIT_STATE"
printf 'LISTEN 0 4096 0.0.0.0:80 0.0.0.0:* users:(("nginx",pid=9,fd=6))\n' > "$HS_GATEWAY_LISTENERS"
check_out "a foreign port holder is named" "held by nginx" echo "$(hv running 5)"
printf 'LISTEN 0 4096 *:80 *:* users:(("traefik",pid=1,fd=7))\n' > "$HS_GATEWAY_LISTENERS"
printf 'https=443\nhttp=0\ntunnel=0\nacme=staging\n' > "$HS_ETC_DIR/gateway-public"
spec 'route@app@/@10.0.0.5:80'
$R public app.example.org "$SP" --mode direct > "$HS_GATEWAY_DIR/routes/pub-app.example.org.yml"
printf '#!/bin/sh\ncase "$1" in\n  s_client) echo "issuer=O=(STAGING) Let'"'"'s Encrypt"; echo "notAfter=Jan  1 00:00:00 2099 GMT" ;;\n  x509) cat ;;\nesac\n' > "$FAKEBIN/openssl"
check_eq "staging certificate: cert warns with fix certs" "warn certs staging" "$(PATH="$FAKEBIN:$PATH" hv cert 2) $(PATH="$FAKEBIN:$PATH" hv cert 3) $(PATH="$FAKEBIN:$PATH" hv cert 4)"
printf '#!/bin/sh\ncase "$1" in\n  s_client) echo "issuer=O=Let'"'"'s Encrypt"; echo "notAfter=Jan  1 00:00:00 2099 GMT" ;;\n  x509) cat ;;\nesac\n' > "$FAKEBIN/openssl"
check_eq "a good certificate: cert ok, detail is the date" "ok 2099-01-01" "$(PATH="$FAKEBIN:$PATH" hv cert 2) $(PATH="$FAKEBIN:$PATH" hv cert 4)"
printf '#!/bin/sh\nexit 1\n' > "$FAKEBIN/openssl"
printf 'time=1 level=error msg="Unable to obtain ACME certificate for domains app.example.org: rate limited"\n' > "$HS_GATEWAY_JOURNAL"
check_eq "no certificate: cert fails" "fail certs none" "$(PATH="$FAKEBIN:$PATH" hv cert 2) $(PATH="$FAKEBIN:$PATH" hv cert 3) $(PATH="$FAKEBIN:$PATH" hv cert 4)"
check_out "and gives the ACME error as the reason" "Unable to obtain ACME" echo "$(PATH="$FAKEBIN:$PATH" hv cert 5)"
printf '#!/bin/sh\nexit 0\n' > "$HS_GATEWAY_RESOLVE"
check_eq "a direct host that does not resolve: dns fails with fix domain" "fail domain" "$(PATH="$FAKEBIN:$PATH" hv dns 2) $(PATH="$FAKEBIN:$PATH" hv dns 3)"
check_eq "every line has five non-empty fields" "" "$(PATH="$FAKEBIN:$PATH" H | awk -F'\t' 'NF != 5 || $1 == "" || $2 == "" || $3 == "" || $4 == "" || $5 == ""')"
check_out "hs gateway health draws a table" "Check +State +Reason" $G health
unset HS_GATEWAY_CURL HS_GATEWAY_JOURNAL
rm -f "$HS_GATEWAY_DIR/routes/pub-"*.yml "$HS_ETC_DIR/gateway-public" "$HS_SETTINGS_DIR/reverseProxy"
finish
