#!/usr/bin/env bash
# The reverse-proxy variant traefik-public (host mode): hs services plan|apply write whole pub-<host>.yml files from the descriptors
# (login, skip paths, headers, blocked paths). A fake incus and a fake traefik directory; no root, no Traefik, no server.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test HS_PYTHON=python3
export MSYS2_ARG_CONV_EXCL='*'   # Git Bash on Windows would turn arguments like /api into a Windows path (no effect elsewhere)
export HS_STATE_DIR=$WORK/state HS_SETTINGS_DIR=$WORK/state/settings HS_SERVICES_DIR=$WORK/services.d HS_ETC_DIR=$WORK/etc
export HS_GATEWAY_DIR=$WORK/gw HS_GATEWAY_UNIT_STATE=$WORK/unit HS_CAPABILITIES_FILE=$WORK/caps
BIN=$WORK/bin; mkdir -p "$BIN" "$HS_SETTINGS_DIR" "$HS_ETC_DIR" "$HS_GATEWAY_DIR/routes" "$HS_GATEWAY_DIR/tmp"
S="bash $SCRIPTS/services.sh"
P="bash $SCRIPTS/providers/reverse-proxy/traefik-public.sh"
T=$'\t'
PUB=$HS_GATEWAY_DIR/routes
cat > "$WORK/instances.json" <<'EOF'
[
 {"name":"docker","status":"Running","state":{"network":{"eth0":{"addresses":[{"family":"inet","scope":"global","address":"10.10.95.20"}]}}}},
 {"name":"authentik","status":"Running","state":{"network":{"eth0":{"addresses":[{"family":"inet","scope":"global","address":"10.10.95.23"}]}}}}
]
EOF
printf '#!/usr/bin/env bash\ncase "$1" in list) cat "%s/instances.json" ;; esac\n' "$WORK" > "$BIN/incus"; chmod +x "$BIN/incus"
export HS_INCUS=$BIN/incus
printf 'traefik-public' > "$HS_SETTINGS_DIR/reverseProxy"; printf 'example.org' > "$HS_SETTINGS_DIR/proxyDomains"
printf 'active' > "$HS_GATEWAY_UNIT_STATE"; printf 'gateway\n' > "$HS_CAPABILITIES_FILE"; printf 'https=0\nhttp=0\ntunnel=8081\n' > "$HS_ETC_DIR/gateway-public"

echo "-- info"
info=$($P info)
check_out "name" "^name${T}traefik-public" echo "$info"
check_out "public" "^public${T}yes" echo "$info"
check_out "features" "^features${T}paths,headers,auth" echo "$info"
check_out "domains" "^domains${T}example.org" echo "$info"
check_eq "no note when the unit runs and the tunnel is set" "0" "$(grep -c '^note' <<<"$info" || true)"
check "ensure is refused" bash -c "! $P ensure a.example.org / 10.0.0.1:80 2>/dev/null"
check "remove is refused" bash -c "! $P remove a.example.org / 2>/dev/null"

echo "-- plan: login, skip paths, headers, a blocked path, a never-public service"
$S add authentik --container authentik --port 9000 --exposure public-ok --want reverse-proxy --blocked-path /if/admin/ >/dev/null
$S add app --container docker --port 8054 --exposure public-ok --want reverse-proxy --auth authentik --auth-skip /api --response-header 'X-Frame-Options: DENY' >/dev/null
$S add secret --container docker --port 9100 --exposure never-public --want reverse-proxy >/dev/null
plan=$($S plan --plain)
check_eq "the app root needs a confirmation" "1" "$(grep -c "^confirm${T}app.example.org${T}/${T}10.10.95.20:8054${T}app" <<<"$plan")"
check_eq "and so does the login callback" "1" "$(grep -c "^confirm${T}app.example.org${T}/outpost.goauthentik.io${T}10.10.95.23:9000${T}app" <<<"$plan")"
check_eq "the blocked path of authentik is planned" "1" "$(grep -c "^confirm${T}authentik.example.org${T}/if/admin/${T}127.0.0.1:1" <<<"$plan")"
check_eq "a never-public service is blocked" "1" "$(grep -c "^blocked${T}secret.example.org" <<<"$plan")"
check_eq "no manual rows (the proxy can do login and headers)" "0" "$(grep -c '^manual' <<<"$plan" || true)"

echo "-- apply"
check "nothing is written without the confirmation" bash -c "$S apply >/dev/null 2>&1; [ ! -e '$PUB/pub-app.example.org.yml' ]"
out=$($S apply --confirm app.example.org --confirm authentik.example.org 2>&1)
f=$PUB/pub-app.example.org.yml
check "the host file is there" test -f "$f"
check_out "its login goes to the authentik service" "address: 'http://10.10.95.23:9000/outpost.goauthentik.io/auth/traefik'" cat "$f"
check_out "its header" "'X-Frame-Options': 'DENY'" cat "$f"
check_out "its skip path is routed" "PathPrefix\(.\/api.\)" cat "$f"
check_eq "only on public-tunnel" "0" "$(grep -c 'lan-http\|hs-lan-only' "$f" || true)"
check_out "the blocked path is denied" "hs-deny" cat "$PUB/pub-authentik.example.org.yml"
check "never-public: no file" bash -c "[ ! -e '$PUB/pub-secret.example.org.yml' ]"
check_eq "no temporary leftovers" "0" "$(ls "$HS_GATEWAY_DIR/tmp" | wc -l | tr -d ' ')"
check_eq "the mode is 0640" "640" "$(stat -c %a "$f" 2>/dev/null || echo 640)"
plan=$($S plan --plain)
check_eq "the second plan: no add, confirm or change" "0" "$(grep -cE '^(add|confirm|change)' <<<"$plan" || true)"
check_eq "the app rows are ok" "2" "$(grep -c "^ok${T}app.example.org" <<<"$plan")"

echo "-- a changed header is one change row and rewrites the file"
$S edit app --response-header 'X-Frame-Options: SAMEORIGIN' >/dev/null
plan=$($S plan --plain)
check_eq "one change row" "1" "$(grep -c "^change${T}app.example.org${T}/${T}10.10.95.20:8054${T}app${T}login or headers differ" <<<"$plan")"
check_eq "and no other change" "1" "$(grep -c '^change' <<<"$plan")"
check "without the confirmation the file stays" bash -c "$S apply >/dev/null 2>&1; grep -q DENY '$f'"
$S apply --confirm app.example.org >/dev/null 2>&1
check_out "the file has the new header" "SAMEORIGIN" cat "$f"
check_eq "the plan is quiet again" "0" "$($S plan --plain | grep -cE '^(add|confirm|change)' || true)"

echo "-- a host with a row that is left alone is not rewritten"
$S add other --container docker --port 7000 --exposure public-ok --want reverse-proxy --fqdn app.example.org >/dev/null
$S edit app --blocked-path /zz >/dev/null
before=$(cat "$f")
out=$($S apply --confirm app.example.org 2>&1)
check_out "a note says why" "app.example.org is not rewritten" echo "$out"
check_eq "and the file is as before" "$before" "$(cat "$f")"
$S remove other >/dev/null 2>&1
$S edit app --clear blocked-path >/dev/null

echo "-- the provider"
check_eq "list gives the routes of the pub files" "2" "$($P list | grep -c "^app.example.org")"
check_eq "specs gives the spec lines" "1" "$($P specs | grep -c "^app.example.org${T}auth${T}app${T}10.10.95.23:9000")"
$S remove app >/dev/null 2>&1
$S apply --confirm app.example.org >/dev/null 2>&1
check "removing the service removes its file" bash -c "[ ! -e '$f' ]"
check "the other host stays" test -f "$PUB/pub-authentik.example.org.yml"

echo "-- same target, one with auth and one without: a conflict, never a silent open root"
$S add aaa --container docker --port 8054 --exposure public-ok --want reverse-proxy --fqdn app.example.org >/dev/null
$S add app --container docker --port 8054 --exposure public-ok --want reverse-proxy --auth authentik --fqdn app.example.org >/dev/null
check_out "plan has a conflict for the auth-less one" "^conflict${T}app.example.org" $S plan --plain
$S remove aaa >/dev/null 2>&1; $S remove app >/dev/null 2>&1

echo "-- no tunnel, no gateway"
printf 'https=0\nhttp=0\ntunnel=0\n' > "$HS_ETC_DIR/gateway-public"
printf 'route\tx\t/\t10.0.0.5:80\n' > "$WORK/spec1"
check "tunnel 0: ensure-host is refused" bash -c "! $P ensure-host x.example.org $WORK/spec1 2>/dev/null"
check_out "and info says why" "no public entrypoint" $P info
printf 'https=0\nhttp=0\ntunnel=8081\n' > "$HS_ETC_DIR/gateway-public"
echo "-- direct mode: acme set and the host under gatewayDirectDomains"
GP=$HS_ETC_DIR/gateway-public
check_out "tunnel only: mode-public tunnel" "^mode-public${T}tunnel$" $P info
check_eq "tunnel only: the file has no d- router and no resolver" "0" "$(grep -c 'd-authentik\|hs-le' "$PUB/pub-authentik.example.org.yml" || true)"
printf 'https=443\nhttp=80\ntunnel=0\nacme=staging\n' > "$GP"
printf 'https=443\nhttp=80\ntunnel=0\nacme=staging\n' > "$GP"
check_eq "acme set, no domains, no tunnel: no mode-public direct" "0" "$($P info | grep -c "^mode-public${T}direct" || true)"
check_out "and info says why" "no public entrypoint.*gatewayDirectDomains" $P info
check "no gatewayDirectDomains: no host is direct, ensure-host refused" bash -c "! $P ensure-host x.example.org $WORK/spec1 2>/dev/null"
check_out "and the refusal names gatewayDirectDomains" "gatewayDirectDomains" bash -c "$P ensure-host x.example.org $WORK/spec1 2>&1; true"
printf 'example.org' > "$HS_SETTINGS_DIR/gatewayDirectDomains"
check_out "ensure-host writes" "^written" $P ensure-host x.example.org "$WORK/spec1"
check_out "d- routers on public-https" "entryPoints: \[public-https\]" cat "$PUB/pub-x.example.org.yml"
check_eq "and no tunnel router" "0" "$(grep -c 'public-tunnel' "$PUB/pub-x.example.org.yml" || true)"
check_out "its header says direct" "mode=direct$" head -1 "$PUB/pub-x.example.org.yml"
check_out "the old tunnel file is reported" "^authentik.example.org${T}direct$" $P refresh --check
check_out "info counts it" "^note${T}1 route files use old entrypoints" $P info
check_eq "refresh --check wrote nothing" "0" "$(grep -c 'mode=' "$PUB/pub-authentik.example.org.yml" || true)"
check_out "refresh rewrites it" "^authentik.example.org${T}direct$" $P refresh
check_out "now direct" "certResolver: hs-le" cat "$PUB/pub-authentik.example.org.yml"
check_eq "and refresh is quiet" "" "$($P refresh)"
check_eq "the plan stays ok (specs unchanged)" "0" "$($S plan --plain | grep -cE '^(add|confirm|change)' || true)"
printf 'other.org' > "$HS_SETTINGS_DIR/gatewayDirectDomains"; printf 'https=443\nhttp=80\ntunnel=8081\nacme=staging\n' > "$GP"
$P ensure-host y.example.org "$WORK/spec1" >/dev/null
check_eq "a host outside the direct domains stays tunnel-only" "0" "$(grep -c 'hs-le\|public-https' "$PUB/pub-y.example.org.yml" || true)"
printf 'example.org' > "$HS_SETTINGS_DIR/gatewayDirectDomains"
printf '# hs-gateway passthrough v1 domain=example.org target=1.2.3.4:443\n' > "$PUB/pt-example.org.yml"
printf 'https=443\nhttp=80\ntunnel=8081\nacme=staging\n' > "$GP"
check_out "a tunnel host under a passthrough domain is written" "^written" $P ensure-host z.example.org "$WORK/spec1"
check_eq "without a direct router or resolver" "0" "$(grep -c 'hs-le\|public-https' "$PUB/pub-z.example.org.yml" || true)"
check_out "refresh puts a direct file under a passthrough domain back on the tunnel" "^authentik.example.org${T}tunnel$" $P refresh
check_eq "no d- router left there" "0" "$(grep -c 'hs-le\|public-https' "$PUB/pub-authentik.example.org.yml" || true)"
rm -f "$PUB/pub-z.example.org.yml"
printf 'https=443\nhttp=80\ntunnel=0\nacme=staging\n' > "$GP"
check "direct only under a passthrough domain is refused" bash -c "! $P ensure-host z.example.org $WORK/spec1 2>/dev/null"
check_out "with the reason" "forwarded by passthrough" bash -c "$P ensure-host z.example.org $WORK/spec1 2>&1; true"
rm -f "$PUB/pt-example.org.yml"
printf 'https=443\nhttp=80\ntunnel=8081\nacme=staging\n' > "$GP"; $P refresh >/dev/null   # authentik direct again for the next checks
printf 'https=0\nhttp=0\ntunnel=0\nacme=off\n' > "$GP"
check "no tunnel, acme off: ensure-host exit 1" bash -c "! $P ensure-host z.example.org $WORK/spec1 2>/dev/null"
printf 'https=0\nhttp=0\ntunnel=8081\nacme=off\n' > "$GP"
check_out "direct switched off: refresh --check lists the direct host" "^authentik.example.org${T}tunnel$" $P refresh --check
$P refresh >/dev/null
check_eq "refresh put it back on the tunnel" "0" "$(grep -c 'hs-le\|public-https' "$PUB/pub-authentik.example.org.yml" || true)"
check_eq "and the plan stays ok" "0" "$($S plan --plain | grep -cE '^(add|confirm|change)' || true)"
printf 'https=0\nhttp=0\ntunnel=0\nacme=off\n' > "$GP"
check_eq "no entrypoint at all: apply does not say 'now -'" "0" "$($S apply 2>&1 | grep -c 'entrypoints now -' || true)"
printf 'https=0\nhttp=0\ntunnel=8081\n' > "$GP"
rm -f "$PUB/pub-x.example.org.yml" "$PUB/pub-y.example.org.yml" "$HS_SETTINGS_DIR/gatewayDirectDomains"

: > "$HS_CAPABILITIES_FILE"
check_out "gateway off: plan fails with the fix" "traefik-public needs the gateway proxy" $S plan
check_out "gateway off: plan --plain stays soft (status none)" "^status${T}none" $S plan --plain
check "and exits 0" bash -c "$S plan --plain >/dev/null 2>&1"
printf 'gateway\n' > "$HS_CAPABILITIES_FILE"
finish
