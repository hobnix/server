#!/usr/bin/env bash
# Live test of the gateway proxy with a real Traefik (exit 77 = skipped when `traefik` is not installed). Traefik listens on 127.0.0.1:18080 with a
# test static file; the base file of the module (same rules as capabilities/gateway/module.nix) and a local route file go to python http.server
# stand-ins. Checks the route, that an unknown name gets 404, that X-Forwarded-For does not matter, the allowlist (403) and a websocket upgrade.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
command -v traefik >/dev/null 2>&1 || { echo "traefik is not installed: skipped"; exit 77; }
command -v curl >/dev/null 2>&1 || { echo "curl is not installed: skipped"; exit 77; }
export HS_PYTHON=python3
APP=18091 WEBUI=18092 PORT=18080 PORT2=18081
R="python3 $SCRIPTS/gateway_render.py"
mkdir -p "$WORK/routes" "$WORK/routes2"
pids=()
cleanup() { for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT
serve() {   # serve <port> <text>
  local d=$WORK/srv$1; mkdir -p "$d"; printf '%s' "$2" > "$d/index.html"
  ( cd "$d" && exec python3 -m http.server "$1" --bind 127.0.0.1 >/dev/null 2>&1 ) & pids+=($!)
}
serve $APP "the app"; serve $WEBUI "the web interface"

base() {   # base <dir> <source range json list>
  python3 - "$1" "$2" "$WEBUI" <<'PY'
import json, sys
d, rng, webui = sys.argv[1], json.loads(sys.argv[2]), sys.argv[3]
client = '(' + ' || '.join('ClientIP(`%s`)' % r for r in rng) + ')'   # as lanClient in module.nix
doc = {'http': {'middlewares': {'hs-lan-only': {'ipAllowList': {'sourceRange': rng}}},
    'services': {'hs-webui': {'loadBalancer': {'servers': [{'url': 'http://127.0.0.1:' + webui}]}}},
    'routers': {
      'hs-webui': {'entryPoints': ['lan-http'], 'rule': 'Host(`home.example.org`) && ' + client, 'middlewares': ['hs-lan-only'], 'service': 'hs-webui'}}}}
open(d + '/00-hs-base.yml', 'w').write(json.dumps(doc))
PY
}
static() {   # static <file> <port> <routes dir>
  printf '{"entryPoints":{"lan-http":{"address":"127.0.0.1:%s"}},"providers":{"file":{"directory":"%s","watch":true}},"log":{"level":"ERROR"}}\n' "$2" "$3" > "$1"
}
base "$WORK/routes" '["127.0.0.1/32","10.0.0.0/8"]'
$R local app.home.example.org "/=127.0.0.1:$APP" > "$WORK/routes/local-app.home.example.org.yml"
static "$WORK/static.yml" $PORT "$WORK/routes"
base "$WORK/routes2" '["10.0.0.0/8"]'
cp "$WORK/routes/local-app.home.example.org.yml" "$WORK/routes2/"
static "$WORK/static2.yml" $PORT2 "$WORK/routes2"
( cd "$WORK" && exec traefik --configfile="$WORK/static.yml" >"$WORK/t1.log" 2>&1 ) & pids+=($!)
( cd "$WORK" && exec traefik --configfile="$WORK/static2.yml" >"$WORK/t2.log" 2>&1 ) & pids+=($!)
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && curl -s -o /dev/null "http://127.0.0.1:$PORT2/" && break; sleep 0.2; done
get() { curl -s -m 5 -H "Host: $1" "${@:2}" "http://127.0.0.1:$PORT/"; }

echo "-- routes"
check_eq "a local name reaches its target" "the app" "$(get app.home.example.org)"
check_eq "the host's own name reaches the web interface" "the web interface" "$(get home.example.org)"
check_eq "an unknown name gets Traefik's 404, not the web interface" "404" "$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H 'Host: nobody.home.example.org' "http://127.0.0.1:$PORT/")"
check_eq "X-Forwarded-For from the peer does not matter" "the app" "$(get app.home.example.org -H 'X-Forwarded-For: 8.8.8.8')"

echo "-- allowlist"
check_eq "a source range without the peer gets 403" "403" "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: app.home.example.org' "http://127.0.0.1:$PORT2/")"
code2() { curl -s -m 5 -o /dev/null -w '%{http_code}' -H "Host: $1" "http://127.0.0.1:$PORT2/"; }
body2() { curl -s -m 5 -H "Host: $1" "http://127.0.0.1:$PORT2/"; }
echo "-- a public source (here: the peer is outside the source range) never reaches a local route or the web interface"
check_eq "an unknown name gets 404" "404" "$(code2 nobody.example.net)"
check_eq "the host's own name gets 404, not the web interface" "404" "$(code2 home.example.org)"
check_eq "any other name does not show the web interface" "" "$(body2 nobody.example.net | grep -c 'web interface' | grep -v '^0$')"
check_eq "a local name gets 403" "403" "$(code2 app.home.example.org)"

echo "-- a route file edited while running is picked up"
$R local b.home.example.org "/=127.0.0.1:$APP" > "$WORK/routes/local-b.home.example.org.yml"
sleep 1.5
check_eq "the new name works" "the app" "$(get b.home.example.org)"

echo "-- websocket upgrade"
code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H 'Host: app.home.example.org' -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "http://127.0.0.1:$PORT/" || true)
check "the upgrade request is passed on (the stand-in answers, Traefik does not refuse)" test "$code" != 403 -a "$code" != 502 -a "$code" != 000
finish
