#!/usr/bin/env bash
# declare_service (scripts/recipes/_lib.sh, docs/PLAN-modular-core.md step 4e): what a recipe says about its service becomes a descriptor for
# `hs services`; the questions are asked per provider that is set up and remembered; a recipe never makes a service public.
# A stub recipe sources the real _lib.sh with a fake incus; no root, no server.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test HS_PYTHON=python3
export HS_STATE_DIR=$WORK/state HS_SETTINGS_DIR=$WORK/state/settings HS_SERVICES_DIR=$WORK/services.d HS_ETC_DIR=$WORK/etc
mkdir -p "$WORK/bin" "$HS_SETTINGS_DIR" "$HS_ETC_DIR" "$HS_STATE_DIR"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/bin/incus"; chmod +x "$WORK/bin/incus"   # incus info <ct>: no such instance
export PATH="$WORK/bin:$PATH" HS_INCUS=$WORK/bin/incus
cat > "$WORK/stub.sh" <<EOF
#!/usr/bin/env bash
# recipe: Demo: a stub for the test
set -euo pipefail
scripts=$SCRIPTS
state=\$HS_STATE_DIR
ct=\${DEMO_CT:-demo}
. "\$scripts/recipes/_lib.sh"
PORT=\${DEMO_PORT-8080}
declare_service "\$@"
EOF
run() { bash "$WORK/stub.sh" "$@" 2>&1; }   # run <declare_service arguments>
toml() { cat "$HS_SERVICES_DIR/$1.toml" 2>/dev/null; }

echo "-- no provider set up: just the description"
out=$(DEMO_CT=demo run demo Demo mdi-test private-ok Apps "A demo")
check_out "it says so" "Service 'demo' is created" echo "$out"
check "port is the recipe's PORT" grep -q 'port = 8080' "$HS_SERVICES_DIR/demo.toml"
check "container is the recipe's" grep -q 'container = "demo"' "$HS_SERVICES_DIR/demo.toml"
check "private-ok" grep -q 'exposure = "private-ok"' "$HS_SERVICES_DIR/demo.toml"
check "the group and description" bash -c 'grep -q "group = \"Apps\"" "$1" && grep -q "description = \"A demo\"" "$1"' _ "$HS_SERVICES_DIR/demo.toml"
check "no want at all" bash -c '! grep -q want "$1"' _ "$HS_SERVICES_DIR/demo.toml"

echo "-- a dashboard is set up: asked (default yes), remembered"
printf 'homepage' > "$HS_SETTINGS_DIR/dashboard"
DEMO_CT=demo2 run demo2 "Demo 2" mdi-test >/dev/null
check "the tile is wanted by default" grep -q 'dashboard = true' "$HS_SERVICES_DIR/demo2.toml"
check "the answer is remembered per container" grep -q '^DASH_DEMO2=yes' "$HS_STATE_DIR/recipe-demo2.conf"
RECIPE_DASH_DEMO3=no DEMO_CT=demo3 run demo3 "Demo 3" mdi-test >/dev/null
check "RECIPE_DASH_<NAME>=no leaves the tile out" bash -c '! grep -q "dashboard = true" "$1"' _ "$HS_SERVICES_DIR/demo3.toml"

echo "-- a reverse proxy is set up: asked (default no)"
printf 'zoraxy' > "$HS_SETTINGS_DIR/reverseProxy"
DEMO_CT=demo4 run demo4 "Demo 4" mdi-test >/dev/null
check "not put on the proxy by default" bash -c '! grep -q "reverse-proxy = true" "$1"' _ "$HS_SERVICES_DIR/demo4.toml"
check "but the tile is" grep -q 'dashboard = true' "$HS_SERVICES_DIR/demo4.toml"
RECIPE_PROXY_DEMO5=yes DEMO_CT=demo5 run demo5 "Demo 5" mdi-test >/dev/null
check "RECIPE_PROXY_<NAME>=yes puts it on the proxy" grep -q 'reverse-proxy = true' "$HS_SERVICES_DIR/demo5.toml"
check "and it is still not public" grep -q 'exposure = "private-ok"' "$HS_SERVICES_DIR/demo5.toml"

echo "-- never-public, a name with a dash, running again"
DEMO_CT=demo-six run demo-six "Demo Six" mdi-test never-public Monitoring >/dev/null
check "an admin page is never-public" grep -q 'exposure = "never-public"' "$HS_SERVICES_DIR/demo-six.toml"
check "a dash in the name is fine for the setting (DASH_DEMO_SIX)" grep -q '^DASH_DEMO_SIX=' "$HS_STATE_DIR/recipe-demo-six.conf"
sed -i 's/exposure = "private-ok"/exposure = "public-ok"/' "$HS_SERVICES_DIR/demo5.toml"   # a person made it public
DEMO_PORT=9090 DEMO_CT=demo5 run demo5 "Demo Five" mdi-test >/dev/null
check "running again refreshes the port and the title" bash -c 'grep -q "port = 9090" "$1" && grep -q "title = \"Demo Five\"" "$1"' _ "$HS_SERVICES_DIR/demo5.toml"
check "but keeps what a person decided (public-ok)" grep -q 'exposure = "public-ok"' "$HS_SERVICES_DIR/demo5.toml"
out=$(DEMO_PORT= DEMO_CT=demo7 run demo7 "Demo 7" mdi-test || true)
check "without a port nothing is declared (a recipe without a web page)" test ! -e "$HS_SERVICES_DIR/demo7.toml"

echo "-- a container with a name of its own is a service of its own"
out=$(RECIPE_NAME=demo8b DEMO_CT=demo8b run demo8 "Demo 8" mdi-test private-ok Apps "A demo")
check_out "the service is named after the container" "Service 'demo8b' is created" echo "$out"
check "the title says which one" grep -q 'title = "Demo 8 (demo8b)"' "$HS_SERVICES_DIR/demo8b.toml"
check "and the first one's name is not taken" test ! -e "$HS_SERVICES_DIR/demo8.toml"

echo "-- hs recipe --name"
FS=$WORK/fs; mkdir -p "$FS/recipes" "$FS/packages/demo"; export HS_RECIPES_DIR=$FS/packages; cp "$SCRIPTS/recipe.sh" "$FS/"; cp -r "$SCRIPTS/lib" "$FS/lib"
printf '#!/usr/bin/env bash
echo "name=${RECIPE_NAME:-none} args=$*"
' > "$FS/packages/demo/run.sh"
out=$(bash "$FS/recipe.sh" demo --name second --dry-run 2>&1)
check_eq "--name <ct> becomes RECIPE_NAME and the other arguments pass on" "name=second args=--dry-run" "$out"
out=$(bash "$FS/recipe.sh" demo --name=third 2>&1)
check_eq "--name=<ct> too" "name=third args=" "$out"
out=$(bash "$FS/recipe.sh" demo --name "Bad Name" 2>&1 || true)
check_out "a name that is no container name is refused" "is not a container name" echo "$out"
out=$(bash "$FS/recipe.sh" demo --name 2>&1 || true)
check_out "--name without a value is refused" "Give a container name" echo "$out"
out=$(bash "$FS/recipe.sh" demo 2>&1)
check_eq "without it nothing changes" "name=none args=" "$out"

echo "-- SERVICE_PUBLIC_NAME: the person typed a public host name"
SERVICE_PUBLIC_NAME=files.example.com DEMO_CT=pub run pub Pub mdi-test >/dev/null
check "the name is the fqdn" grep -q 'fqdn = \["files.example.com"\]' "$HS_SERVICES_DIR/pub.toml"
check "the service may be public (a route still needs hs services apply)" grep -q 'exposure = "public-ok"' "$HS_SERVICES_DIR/pub.toml"
check "it wants the reverse proxy without being asked" grep -q 'reverse-proxy = true' "$HS_SERVICES_DIR/pub.toml"
SERVICE_PUBLIC_NAME=files.example.com DEMO_CT=adm run adm Adm mdi-test never-public >/dev/null
check "never-public stays never-public" grep -q 'exposure = "never-public"' "$HS_SERVICES_DIR/adm.toml"

echo "-- the gateway proxy is off: nothing local"
printf 'cloud
' > "$HS_ETC_DIR/capabilities"; export HS_CAPABILITIES_FILE=$HS_ETC_DIR/capabilities
printf 'hostName = "homeserver"
adDomain = { realm = "AD.EXAMPLE.ORG", workgroup = "EX" }
' > "$WORK/machine.toml"; echo homeserver > "$WORK/site-name"
export HS_MACHINE_FILE=$WORK/machine.toml HS_SITE_NAME_FILE=$WORK/site-name
out=$(DEMO_CT=lo1 run lo1 Lo1 mdi-test)
check "no local-proxy want" bash -c '! grep -q local-proxy "$1"' _ "$HS_SERVICES_DIR/lo1.toml"
check "no local address printed" bash -c '! grep -q "Local address" <<<"$1"' _ "$out"

echo "-- the gateway proxy is on: wanted without a question, added at once, address printed"
printf 'gateway
' > "$HS_ETC_DIR/capabilities"
mkdir -p "$WORK/gw/routes" "$WORK/gw/tmp"; printf 'active' > "$WORK/unit"
export HS_GATEWAY_DIR=$WORK/gw HS_GATEWAY_UNIT_STATE=$WORK/unit
printf '#!/usr/bin/env bash
case "$1" in
  list) printf '"'"'[{"name":"lo2","status":"Running","state":{"network":{"eth0":{"addresses":[{"family":"inet","scope":"global","address":"10.10.95.77"}]}}}}]'"'"' ;;
  *) exit 1 ;;
esac
' > "$WORK/bin/incus"
out=$(DEMO_CT=lo2 run lo2 Lo2 mdi-test)
check "local-proxy is wanted" grep -q 'local-proxy = true' "$HS_SERVICES_DIR/lo2.toml"
check "and no reverse-proxy want came with it" bash -c '! grep -q "^reverse-proxy" "$1"' _ "$HS_SERVICES_DIR/lo2.toml"
check_out "the address is printed" "Local address: http://lo2.homeserver.ad.example.org" echo "$out"
check "the route file was made" test -f "$WORK/gw/routes/local-lo2.homeserver.ad.example.org.yml"
DEMO_CT=lo3 run lo3 Lo3 mdi-test never-public >/dev/null
check "an admin page gets the local want too (no question, never public)" grep -q 'local-proxy = true' "$HS_SERVICES_DIR/lo3.toml"
unset HS_CAPABILITIES_FILE
finish
