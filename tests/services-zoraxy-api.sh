#!/usr/bin/env bash
# Step 4b-1 (docs/PLAN-modular-core.md): the zoraxy variant in api mode against tests/zoraxy-fake.py (a stand-in for Zoraxy's admin API):
# hs services proxy login, listing through the API, the self-check against the rule files, hs services apply (add only, typed confirmation).
# A fake incus serves the instance addresses and cats the rule files the fake writes. No root, no server (needs python3 and curl).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
have curl || { echo "curl is needed"; exit 77; }
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test HS_PYTHON=python3
export MSYS2_ARG_CONV_EXCL='/api;path=;domain=;vdir='   # Git Bash on Windows would turn arguments like /api/... into a Windows path (no effect elsewhere)
export HS_STATE_DIR=$WORK/state HS_SETTINGS_DIR=$WORK/state/settings HS_SERVICES_DIR=$WORK/services.d HS_ETC_DIR=$WORK/etc
BIN=$WORK/bin RULES=$WORK/rules
mkdir -p "$BIN" "$HS_SETTINGS_DIR" "$HS_ETC_DIR" "$RULES"
S="bash $SCRIPTS/services.sh"
Z="bash $SCRIPTS/providers/reverse-proxy/zoraxy.sh"
T=$'\t'

cat > "$WORK/instances.json" <<'EOF'
[
 {"name":"jellyfin","status":"Running","state":{"network":{"eth0":{"addresses":[{"family":"inet","scope":"global","address":"10.10.95.50"}]}}}},
 {"name":"docker","status":"Running","state":{"network":{"eth0":{"addresses":[{"family":"inet","scope":"global","address":"10.10.95.20"}]}}}}
]
EOF
cat > "$RULES/media.example.org.config" <<'EOF'
{"RootOrMatchingDomain":"media.example.org","MatchingDomainAlias":[],"ActiveOrigins":[{"OriginIpOrDomain":"10.10.95.50:8096"}],"VirtualDirectories":[]}
EOF
# the default site: a rule file with the host "/" that the API's host list does not have (found on the real Zoraxy: 32 files, 31 API routes)
cat > "$RULES/default.config" <<'EOF'
{"RootOrMatchingDomain":"/","ActiveOrigins":[{"OriginIpOrDomain":"127.0.0.1:5487"}],"VirtualDirectories":[]}
EOF
cat > "$BIN/incus" <<EOF
#!/usr/bin/env bash
case "\$1" in
  list) cat "$WORK/instances.json" ;;
  exec) for f in "$RULES"/*.config; do [ -e "\$f" ] || continue; echo "## \$f"; cat "\$f"; echo; done ;;
esac
EOF
chmod +x "$BIN/incus"
export HS_INCUS=$BIN/incus

python3 "$ROOT/tests/zoraxy-fake.py" "$RULES" "$WORK/port" &
FAKE=$!
trap 'kill $FAKE 2>/dev/null' EXIT
for _ in $(seq 1 60); do [ -s "$WORK/port" ] && break; sleep 0.1; done
export HS_ZORAXY_URL=http://127.0.0.1:$(cat "$WORK/port")
printf 'zoraxy' > "$HS_SETTINGS_DIR/reverseProxy"; printf 'example.org' > "$HS_SETTINGS_DIR/proxyDomains"
routes() { $Z list | cut -f1-3; }

echo "-- without a login: read-only"
check_eq "info: mode read-only, with the reason" "read-only" "$($Z info | awk -F"$T" '$1 == "mode" { print $2 }')"
check_out "and the reason is named" "no login yet" $Z info
check_eq "ensure is refused (exit 3)" "3" "$($Z ensure x.example.org / 10.0.0.1:80 >/dev/null 2>&1; echo $?)"
check_eq "the rule files are read" "media.example.org${T}/${T}10.10.95.50:8096" "$(routes | grep '^media')"
check_eq "and the default site is listed as *" "*${T}/${T}127.0.0.1:5487" "$(routes | grep -F '*')"

echo "-- hs services proxy login"
wrong=$(HS_PROXY_USER=admin HS_PROXY_PASS=nope $S proxy login 2>&1 || true)
check_out "a wrong password is refused" "did not accept the login" echo "$wrong"
check "and nothing is kept" test ! -e "$HS_STATE_DIR/zoraxy-admin"
HS_PROXY_USER=admin HS_PROXY_PASS=secret $S proxy login >/dev/null 2>&1
check_eq "the right login is kept (name, then password)" "admin secret" "$(tr '\n' ' ' < "$HS_STATE_DIR/zoraxy-admin" | sed 's/ $//')"
check_eq "info: mode api" "api" "$($Z info | awk -F"$T" '$1 == "mode" { print $2 }')"

echo "-- the CSRF token (Zoraxy 3.3.x refuses every POST without it)"
check_eq "a POST without the token is refused with 403" "403" "$(curl -s -o /dev/null -w '%{http_code}' -d type=host "$HS_ZORAXY_URL/api/proxy/list")"
check_eq "the login page carries the token" "1" "$(curl -s "$HS_ZORAXY_URL/login.html" | grep -c 'name="zoraxy.csrf.Token"')"

echo "-- listing through the API, and the self-check"
check_eq "list through the API gives the same route" "media.example.org${T}/${T}10.10.95.50:8096" "$(routes)"
check_eq "check: the API and the files agree (the default site is left out of the comparison)" "ok" "$($Z check)"
cat > "$RULES/ghost.example.org.config" <<'EOF'
{"RootOrMatchingDomain":"ghost.example.org","ActiveOrigins":[{"OriginIpOrDomain":"10.10.95.99:80"}],"VirtualDirectories":[]}
EOF
check_out "a rule the API does not know is a difference" "^differ" $Z check
$S add newapp --container jellyfin --port 9001 --exposure public-ok --want reverse-proxy >/dev/null 2>&1
check_eq "plan --plain carries a warn row" "1" "$($S plan --plain | grep -c '^warn')"
check_out "apply refuses while they differ" "different routes" $S apply --confirm newapp.example.org
rm -f "$RULES/ghost.example.org.config"
check_eq "and agrees again" "ok" "$($Z check)"

echo "-- apply: a public-ok service needs the typed host name"
check_eq "plan: newapp waits for a confirmation" "1" "$($S plan --plain | grep -c "^confirm${T}newapp.example.org${T}/${T}10.10.95.50:9001")"
check_out "apply --dry-run says what it would make" "Would make newapp.example.org/ -> 10.10.95.50:9001" $S apply --dry-run
check_eq "and made nothing" "1" "$(routes | wc -l | tr -d ' ')"
check_out "without a terminal and without --confirm it is not made" "needs the typed confirmation" $S apply
check_eq "still nothing" "1" "$(routes | wc -l | tr -d ' ')"
$S apply --confirm newapp.example.org >/dev/null 2>&1
check_eq "with --confirm <host> the route is made, with the right target" "newapp.example.org${T}/${T}10.10.95.50:9001" "$(routes | grep '^newapp')"
check_eq "plan: now ok" "1" "$($S plan --plain | grep -c "^ok${T}newapp.example.org")"
check_out "a second apply has nothing to do" "Nothing to do" $S apply
check "what was made is logged for the next step" grep -q "^newapp.example.org${T}/${T}10.10.95.50:9001" "$HS_STATE_DIR/services.state/zoraxy.created"
# found on the real server: with only zoraxy.created (nothing adopted yet) owned-list exited 1, and the plan then showed every route of hs as foreign
check "adopted file absent" test ! -e "$HS_STATE_DIR/services.state/zoraxy.adopted"
check_eq "owned-list succeeds (exit 0) when nothing has been adopted yet" "0" "$($Z owned-list >/dev/null 2>&1; echo $?)"
check_eq "and lists the route hs made" "1" "$($Z owned-list | grep -c "^newapp.example.org${T}/$")"
$S remove newapp >/dev/null 2>&1
check_eq "plan: a made route whose service is gone is a remove row, before any adopt" "1" "$($S plan --plain | grep -c "^remove${T}newapp.example.org")"
$S add newapp --container jellyfin --port 9001 --exposure public-ok --want reverse-proxy >/dev/null 2>&1

echo "-- a service with public paths: the dead-end root first, then the path"
$S add hook --container docker --port 80 --names hook --exposure public-ok --public-path /api/webhooks/trigger --want reverse-proxy >/dev/null 2>&1
$S apply --confirm hook.example.org >/dev/null 2>&1
r=$(routes | grep '^hook')
check_eq "the root is the dead end" "1" "$(grep -c "^hook.example.org${T}/${T}127.0.0.1:1$" <<<"$r")"
check_eq "the path leads to the service, carrying the path" "1" "$(grep -c "^hook.example.org${T}/api/webhooks/trigger${T}10.10.95.20:80/api/webhooks/trigger" <<<"$r")"
check_eq "plan: both rows are ok" "2" "$($S plan --plain | grep -c "^ok${T}hook.example.org")"
check_eq "ensure of a route that is there is a no-op (exit 0)" "0" "$($Z ensure newapp.example.org / 10.10.95.50:9001 >/dev/null 2>&1; echo $?)"
check_eq "a path whose root is missing is refused (exit 5)" "5" "$($Z ensure nohost.example.org /x 10.0.0.1:80 >/dev/null 2>&1; echo $?)"

echo "-- what apply leaves alone"
$S add media --container jellyfin --port 8097 --exposure public-ok --want reverse-proxy >/dev/null 2>&1
check_eq "plan: media is a change" "1" "$($S plan --plain | grep -c "^change${T}media.example.org")"
out=$($S apply --confirm media.example.org 2>&1 || true)
check_out "apply leaves a change to a route that is not ours alone and says so" "Left alone" echo "$out"
check_eq "the target is as it was" "media.example.org${T}/${T}10.10.95.50:8096" "$(routes | grep '^media')"
check_eq "ensure of another target is refused (exit 4)" "4" "$($Z ensure media.example.org / 10.10.95.50:8097 >/dev/null 2>&1; echo $?)"
$S add secretapp --container jellyfin --port 9002 --exposure never-public --want reverse-proxy >/dev/null 2>&1
$S apply --confirm secretapp.example.org >/dev/null 2>&1
check_eq "a never-public service gets no route, whatever is confirmed" "0" "$(routes | grep -c '^secretapp')"

echo "-- 4b-2: adopt, change, remove (only what hs made or adopted)"
check_eq "remove of a route that is not ours is refused (exit 6)" "6" "$($Z remove media.example.org / >/dev/null 2>&1; echo $?)"
$S remove media >/dev/null 2>&1
$S add media --container jellyfin --port 8096 --exposure public-ok --want reverse-proxy >/dev/null 2>&1
check_eq "plan: the hand-made route that matches is ok, but not adopted" "1" "$($S plan --plain | grep -c "^ok${T}media.example.org.*not adopted")"
$S adopt --yes >/dev/null 2>&1
check_eq "adopt lists it as ours" "1" "$($Z owned-list | grep -c "^media.example.org${T}/$")"
check_eq "and the plan has no note any more" "0" "$($S plan --plain | grep -c "^ok${T}media.example.org.*not adopted")"
check_out "a second adopt has nothing to do" "Nothing to adopt" $S adopt --yes

echo "-- change: another target"
$S remove media >/dev/null 2>&1
$S add media --container jellyfin --port 8097 --exposure public-ok --want reverse-proxy >/dev/null 2>&1
check_eq "plan: a change, now that it is ours (no 'adopt it first')" "1" "$($S plan --plain | grep "^change${T}media.example.org" | grep -vc 'adopt it first')"
check_out "apply --dry-run says what it would change" "Would change media.example.org/ -> 10.10.95.50:8097" $S apply --dry-run
out=$($S apply 2>&1 || true)
check_out "without the typed confirmation a change is not made" "needs the typed confirmation" echo "$out"
check_eq "the route is as it was" "10.10.95.50:8096" "$(routes | awk -F"$T" '$1 == "media.example.org" && $2 == "/" { print $3 }')"
$S apply --confirm media >/dev/null 2>&1
check_eq "--confirm <service name> covers its host: the target changed, one origin left" "10.10.95.50:8097" "$(routes | awk -F"$T" '$1 == "media.example.org" && $2 == "/" { print $3 }')"
check_eq "plan: ok again" "1" "$($S plan --plain | grep -c "^ok${T}media.example.org")"
$S remove hook >/dev/null 2>&1
$S add hook --container docker --port 8080 --names hook --exposure public-ok --public-path /api/webhooks/trigger --want reverse-proxy >/dev/null 2>&1
check_eq "plan: the path route is a change, the dead-end root stays ok" "1" "$($S plan --plain | grep -c "^change${T}hook.example.org${T}/api/webhooks/trigger")"
$S apply --confirm hook.example.org >/dev/null 2>&1
check_eq "the path route now leads to the new port, carrying the path" "1" "$(routes | grep -c "^hook.example.org${T}/api/webhooks/trigger${T}10.10.95.20:8080/api/webhooks/trigger")"

echo "-- remove: a service that is gone takes its routes with it"
check_eq "a host root with paths left is refused (exit 7)" "7" "$($Z remove hook.example.org / >/dev/null 2>&1; echo $?)"
$S remove hook >/dev/null 2>&1
plan=$($S plan --plain)
check_eq "plan: both routes of hook are remove rows" "2" "$(grep -c "^remove${T}hook.example.org" <<<"$plan")"
check_out "apply --dry-run lists paths before the root" "Would remove hook.example.org/api/webhooks/trigger" $S apply --dry-run
out=$($S apply 2>&1 || true)
check_out "without the typed confirmation nothing is removed" "needs the typed confirmation" echo "$out"
check_eq "hook is still there" "2" "$(routes | grep -c '^hook')"
$S apply --confirm hook.example.org >/dev/null 2>&1
check_eq "--confirm <host>: the path went first, then the root: nothing of hook is left" "0" "$(routes | grep -c '^hook')"
check_eq "and it is no longer listed as ours" "0" "$($Z owned-list | grep -c '^hook')"
check_eq "a route that is gone is no problem (exit 0)" "0" "$($Z remove hook.example.org / >/dev/null 2>&1; echo $?)"
check_eq "a hand-made route no service owns stays (unmanaged, never removed)" "0" "$($S plan --plain | grep -c '^remove.*ghost')"
check_eq "a route that never existed is simply gone (exit 0)" "0" "$($Z remove other.example.org / >/dev/null 2>&1; echo $?)"

echo "-- the dashboard follows apply"
mkdir -p "$WORK/dash"
cat > "$WORK/dash/fake.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  sync) touch "$HS_DASH_MARKER"; echo "2 links" ;;
  info) printf 'name\tfake\n' ;;
esac
EOF
export HS_DASHBOARD_DIR=$WORK/dash HS_DASH_MARKER=$WORK/dash/marker
$S declare tilesvc --container jellyfin --port 9100 --title Tile --want dashboard >/dev/null 2>&1
out=$($S apply --dry-run 2>&1 || true)
check "apply --dry-run does not touch the dashboard" test ! -e "$HS_DASH_MARKER"
check "without the setting dashboard nothing is refreshed" bash -c '! '"$S"' apply 2>&1 | grep -q "Dashboard:"'
printf 'fake' > "$HS_SETTINGS_DIR/dashboard"
out=$($S apply 2>&1 || true)
check_out "apply refreshes the dashboard when a service wants a tile" "Dashboard: 2 links" echo "$out"
check "the provider's sync ran" test -e "$HS_DASH_MARKER"
check_eq "the dashboard capability is on once the setting names a variant" "1" "$(bash -c '. "$1/lib/capability.sh"; capability_on dashboard && echo 1' _ "$SCRIPTS")"
$S remove tilesvc >/dev/null 2>&1

echo "-- registry"
for w in "services apply" "services adopt" "services proxy login"; do
  check "user row: $w" grep -q "^user${T}$w${T}services.sh${T}" "$SCRIPTS/lib/registry.tsv"
done
check "the login is a vault secret" grep -q 'zoraxy-admin' "$SCRIPTS/lib/vault.sh" "$SCRIPTS/secrets.sh"

finish
