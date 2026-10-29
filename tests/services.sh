#!/usr/bin/env bash
# Services and the reconciler, 4a (docs/PLAN-modular-core.md step 4): the descriptor files, the guard on a public proxy, the read-only
# zoraxy variant, hs services list|check|plan|add|remove|import. A fake incus and a fake private proxy; no root, no server.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test
export MSYS2_ARG_CONV_EXCL='/api;path=;domain=;vdir='   # Git Bash on Windows would turn arguments like /api/... into a Windows path (no effect elsewhere)
export HS_STATE_DIR=$WORK/state HS_SETTINGS_DIR=$WORK/state/settings HS_SERVICES_DIR=$WORK/services.d HS_ETC_DIR=$WORK/etc
export HS_PYTHON=python3
BIN=$WORK/bin; mkdir -p "$BIN" "$HS_SETTINGS_DIR" "$HS_ETC_DIR"
S="bash $SCRIPTS/services.sh"
T=$'\t'

# ── a fake incus: the instances (hs services reads their addresses) and the rule files inside the zoraxy container ──
cat > "$WORK/instances.json" <<'EOF'
[
 {"name":"zoraxy","status":"Running","state":{"network":{"eth0":{"addresses":[{"family":"inet","scope":"global","address":"10.10.95.11"}]}}}},
 {"name":"docker","status":"Running","state":{"network":{"eth0":{"addresses":[{"family":"inet","scope":"global","address":"10.10.95.20"}]},"docker0":{"addresses":[{"family":"inet","scope":"global","address":"172.17.0.1"}]}}}},
 {"name":"jellyfin","status":"Running","state":{"network":{"eth0":{"addresses":[{"family":"inet","scope":"global","address":"10.10.95.50"}]}}}},
 {"name":"uptime-kuma","status":"Running","state":{"network":{"eth0":{"addresses":[{"family":"inet","scope":"global","address":"10.10.95.43"}]}}}},
 {"name":"stopped","status":"Stopped","state":{"network":{}}}
]
EOF
cat > "$WORK/rules.txt" <<'EOF'
## /opt/zoraxy/conf/proxy/media.example.org.config
{"RootOrMatchingDomain":"media.example.org","MatchingDomainAlias":[],"ActiveOrigins":[{"OriginIpOrDomain":"10.10.95.50:8096","RequireTLS":false}],"VirtualDirectories":[]}

## /opt/zoraxy/conf/proxy/docker.example.org.config
{"RootOrMatchingDomain":"docker.example.org","ActiveOrigins":[{"OriginIpOrDomain":"127.0.0.1:1"}],"VirtualDirectories":[{"MatchingPath":"/api/webhooks/trigger","Domain":"10.10.95.20/api/webhooks/trigger"}]}

## /opt/zoraxy/conf/proxy/arcane.example.org.config
{"RootOrMatchingDomain":"arcane.example.org","ActiveOrigins":[{"OriginIpOrDomain":"10.10.95.20:80"}],"VirtualDirectories":[]}

## /opt/zoraxy/conf/proxy/status.example.org.config
{"RootOrMatchingDomain":"status.example.org","ActiveOrigins":[{"OriginIpOrDomain":"127.0.0.1:1"}],"VirtualDirectories":[{"MatchingPath":"/status","Domain":"10.10.95.43:3001/status"},{"MatchingPath":"/assets","Domain":"10.10.95.43:3001/assets"}]}

## /opt/zoraxy/conf/proxy/broken.config
{this is not json
EOF
cat > "$BIN/incus" <<EOF
#!/usr/bin/env bash
case "\$1" in
  list) cat "$WORK/instances.json" ;;
  exec) cat "$WORK/rules.txt" ;;
esac
EOF
chmod +x "$BIN/incus"
export HS_INCUS=$BIN/incus

echo "-- no proxy set up yet"
check_out "list: no services yet" "No services yet" $S list
check_out "plan: says there is no reverse proxy" "No reverse proxy is set up" $S plan
check_eq "plan --plain: status none" "status${T}none" "$($S plan --plain)"
check "reverse-proxy is not on" bash -c '. "$1/lib/capability.sh"; ! capability_on reverse-proxy' _ "$SCRIPTS"

echo "-- the zoraxy variant reads the rule files"
printf 'zoraxy' > "$HS_SETTINGS_DIR/reverseProxy"; printf 'example.org' > "$HS_SETTINGS_DIR/proxyDomains"
check "reverse-proxy is on once the setting names a variant" bash -c '. "$1/lib/capability.sh"; capability_on reverse-proxy' _ "$SCRIPTS"
Z="bash $SCRIPTS/providers/reverse-proxy/zoraxy.sh"
check_eq "info: public, domains, read-only" "name${T}zoraxy|public${T}yes|domains${T}example.org|mode${T}read-only" "$($Z info | grep -v "^note\|^container" | tr '\n' '|' | sed 's/|$//')"
check_eq "info: the container" "container${T}zoraxy" "$($Z info | grep '^container')"
check_eq "info: the container follows HS_ZORAXY" "container${T}proxy2" "$(HS_ZORAXY=proxy2 $Z info | grep '^container')"
routes=$($Z list)
check_eq "list: seven routes (a broken file is skipped)" "7" "$(printf '%s\n' "$routes" | grep -c .)"
check_eq "a root route" "media.example.org${T}/${T}10.10.95.50:8096${T}media.example.org" "$(grep '^media' <<<"$routes")"
check_eq "a virtual directory" "docker.example.org${T}/api/webhooks/trigger${T}10.10.95.20/api/webhooks/trigger${T}docker.example.org" "$(grep 'webhooks' <<<"$routes")"
check_eq "a dead-end root" "1" "$(grep -c "^status.example.org${T}/${T}127.0.0.1:1" <<<"$routes")"
check "ensure is refused (read-only)" bash -c '! bash "$1/providers/reverse-proxy/zoraxy.sh" ensure a.example.org / 10.0.0.1:80 2>/dev/null' _ "$SCRIPTS"

echo "-- nothing is described yet: every route is unmanaged"
check_eq "plan: the seven routes are unmanaged" "7" "$($S plan --plain | grep -c "^unmanaged")"

echo "-- import"
out=$($S import --dry-run 2>&1)
check_out "dry run lists what it would create" "create.*jellyfin" echo "$out"
check_eq "and writes nothing" "no" "$(ls "$HS_SERVICES_DIR" 2>/dev/null | grep -q toml && echo yes || echo no)"
check_out "without a terminal it refuses without --yes" "or add --yes" $S import
$S import --yes >/dev/null 2>&1
list=$($S list --plain)
check_eq "four services" "4" "$(printf '%s\n' "$list" | grep -c .)"
check_eq "jellyfin: public today = public-ok" "public-ok" "$(awk -F"$T" '$1 == "jellyfin" { print $4 }' <<<"$list")"
check_eq "the admin container's webhook host: public-ok with only its path" "public-ok" "$(awk -F"$T" '$1 == "docker" { print $4 }' <<<"$list")"
check_eq "the admin page itself: never-public" "never-public" "$(awk -F"$T" '$3 == "docker:80" && $4 == "never-public" { print $4 }' <<<"$list")"
check "the status page keeps only its paths" grep -q 'public_paths = \["/assets", "/status"\]' "$HS_SERVICES_DIR/uptime-kuma.toml"
check "the names are the host labels" grep -q 'names = \["media"\]' "$HS_SERVICES_DIR/jellyfin.toml"
check_eq "check: the files are fine" "0" "$($S check >/dev/null 2>&1; echo $?)"
check_out "a second import has nothing new" "Nothing new" $S import --yes

echo "-- plan after the import"
plan=$($S plan --plain)
check_eq "jellyfin is ok (not adopted: hs made nothing)" "ok${T}media.example.org${T}/${T}10.10.95.50:8096${T}jellyfin${T}not adopted (hs services adopt)" "$(grep '^ok.*media' <<<"$plan")"
check_eq "the webhook path and its dead-end root are ok" "2" "$(grep -c "^ok${T}docker.example.org" <<<"$plan")"
check_eq "the admin page on the public proxy is a violation" "1" "$(grep -c "^violation${T}arcane.example.org" <<<"$plan")"
check_eq "nothing is unmanaged" "0" "$(grep -c '^unmanaged' <<<"$plan")"

echo "-- the guard on a public proxy"
$S add secretapp --container jellyfin --port 9000 --exposure never-public --want reverse-proxy >/dev/null 2>&1
$S add newapp --container jellyfin --port 9001 --exposure public-ok --want reverse-proxy >/dev/null 2>&1
$S add lanapp --container jellyfin --port 9002 --want reverse-proxy >/dev/null 2>&1
plan=$($S plan --plain)
check_eq "never-public gets no route" "1" "$(grep -c "^blocked.*secretapp.*never-public" <<<"$plan")"
check_eq "private-ok gets none either" "1" "$(grep -c "^blocked.*lanapp.*private-ok" <<<"$plan")"
check_eq "public-ok needs a typed confirmation" "1" "$(grep -c "^confirm${T}newapp.example.org${T}/${T}10.10.95.50:9001${T}newapp" <<<"$plan")"
$S add dead --container nowhere --port 80 --exposure public-ok --want reverse-proxy >/dev/null 2>&1
check_eq "a stopped or unknown container is unresolved" "1" "$($S plan --plain | grep -c "^unresolved.*dead")"

echo "-- on a private proxy everything is allowed"
mkdir -p "$WORK/prov/reverse-proxy"
cat > "$WORK/prov/reverse-proxy/lan.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  info) printf 'name\tlan\npublic\tno\ndomains\tlan.test\nmode\tmanual\n' ;;
  list) printf 'secretapp.lan.test\t/\t10.10.95.50:9999\tx\n' ;;
esac
EOF
printf 'lan' > "$HS_SETTINGS_DIR/reverseProxy"
export HS_PROVIDER_DIR=$WORK/prov
plan=$(HS_PROVIDER_DIR=$WORK/prov $S plan --plain)
check_eq "private-ok is added on a private proxy" "1" "$(grep -c "^add${T}lanapp.lan.test" <<<"$plan")"
check_eq "never-public: here the route differs, so it is changed" "1" "$(grep -c "^change${T}secretapp.lan.test${T}/${T}10.10.95.50:9000" <<<"$plan")"
check_eq "no violation and no confirmation on a private proxy" "0" "$(grep -cE '^(violation|confirm)' <<<"$plan")"
unset HS_PROVIDER_DIR
printf 'zoraxy' > "$HS_SETTINGS_DIR/reverseProxy"

echo "-- an admin page cannot be made public-ok as a whole"
check_out "docker:80 public-ok is refused, with the reason" "admin page" $S add hs-test --container docker --port 80 --exposure public-ok --want reverse-proxy
check "and nothing was written" test ! -e "$HS_SERVICES_DIR/hs-test.toml"
$S add hs-ok --container docker --port 80 --exposure never-public --want reverse-proxy >/dev/null 2>&1
check "never-public is fine for it" test -e "$HS_SERVICES_DIR/hs-ok.toml"
$S remove hs-ok >/dev/null 2>&1
$S add hs-paths --container docker --port 80 --exposure public-ok --public-path /api/webhooks/trigger --want reverse-proxy >/dev/null 2>&1
check "so is public-ok with only its public_paths (the Arcane webhook)" test -e "$HS_SERVICES_DIR/hs-paths.toml"
$S remove hs-paths >/dev/null 2>&1
$S add other-app --container docker --port 8055 --exposure public-ok --want reverse-proxy >/dev/null 2>&1
check "another app in the same container is not an admin page" test -e "$HS_SERVICES_DIR/other-app.toml"
$S remove other-app >/dev/null 2>&1

echo "-- recipes declare their services; the dashboard shows them"
out=$($S declare ghosttv --container jellyfin --port 8096 --title "Ghost TV" --icon mdi-movie --group Apps --description "Films" --want dashboard 2>&1)
check_eq "declare creates a service" "created" "$out"
check "private-ok unless the recipe says never-public" grep -q 'exposure = "private-ok"' "$HS_SERVICES_DIR/ghosttv.toml"
sed -i 's/dashboard = true/dashboard = false/' "$HS_SERVICES_DIR/ghosttv.toml"   # a person switched its tile off
out=$($S declare ghosttv --container jellyfin --port 8097 --title "Ghost TV 2" --exposure public-ok --want dashboard,reverse-proxy 2>&1)
check_eq "declare again refreshes it" "updated" "$out"
check "the port is the recipe's new one" grep -q 'port = 8097' "$HS_SERVICES_DIR/ghosttv.toml"
check "and the title" grep -q 'title = "Ghost TV 2"' "$HS_SERVICES_DIR/ghosttv.toml"
check "the exposure stays what it was: a recipe never makes a service public" grep -q 'exposure = "private-ok"' "$HS_SERVICES_DIR/ghosttv.toml"
check "a want a person set is kept" grep -q 'dashboard = false' "$HS_SERVICES_DIR/ghosttv.toml"
check "a want that was missing is added" grep -q 'reverse-proxy = true' "$HS_SERVICES_DIR/ghosttv.toml"
check_out "an admin page cannot be declared public-ok" "admin page" $S declare adm --container docker --port 80 --exposure public-ok
check "and nothing was written for it" test ! -e "$HS_SERVICES_DIR/adm.toml"
$S remove ghosttv >/dev/null 2>&1
$S declare jellyfin --container jellyfin --port 8096 --title Jellyfin --icon mdi-movie-open --group Apps --description "Films" --want dashboard >/dev/null 2>&1
$S declare plain --container docker --port 8080 --title Plain --want dashboard >/dev/null 2>&1
$S declare sleeper --container stopped --port 80 --title Sleeper --want dashboard >/dev/null 2>&1
tiles=$($S tiles)
check_eq "a published service links to its public host" "Apps${T}Jellyfin${T}https://media.example.org${T}Films${T}mdi-movie-open${T}jellyfin" "$(grep '^Apps.Jellyfin' <<<"$tiles")"
check_eq "one without a route links to address and port" "http://10.10.95.20:8080" "$(awk -F"$T" '$2 == "Plain" { print $3 }' <<<"$tiles")"
check_eq "a container that is not running has no tile" "0" "$(grep -c Sleeper <<<"$tiles" || true)"
check_eq "without a description or icon: group Apps, description -, icon mdi-application" "Apps${T}Plain${T}http://10.10.95.20:8080${T}-${T}mdi-application${T}plain" "$(grep Plain <<<"$tiles")"
check_eq "no tile line has an empty field (bash read would shift the icon into the description)" "0" "$(awk -F"$T" '{ for (i = 1; i <= NF; i++) if ($i == "") bad++ } END { print bad + 0 }' <<<"$tiles")"
# what a bash reader does with the line: the same read
IFS="$T" read -r g ti hr de ic _ <<<"$(grep Plain <<<"$tiles")"
check_eq "read keeps the fields in place: the icon is the icon" "mdi-application" "$ic"
check_eq "tiles --containers names the containers that have a say" "docker jellyfin stopped" "$($S tiles --containers | tr '\n' ' ' | sed 's/ $//')"
check_out "hs services tiles (for people) shows a table" "Jellyfin.*https://media.example.org" $S tiles --table
check "and the user command is in the registry" grep -q "^user${T}services tiles${T}services.sh${T}tiles --table" "$SCRIPTS/lib/registry.tsv"
$S remove plain >/dev/null 2>&1; $S remove sleeper >/dev/null 2>&1

echo "-- add, check and remove"
check "add refuses a service without a container or host" bash -c '! '"$S"' add x --port 80 2>/dev/null'
check "add refuses a bad exposure" bash -c '! '"$S"' add x --container jellyfin --port 80 --exposure sometimes 2>/dev/null'
check "add refuses a bad port" bash -c '! '"$S"' add x --container jellyfin --port 99999 2>/dev/null'
check "add refuses an existing name" bash -c '! '"$S"' add jellyfin --container jellyfin --port 80 2>/dev/null'
printf 'name = "broken"\nport = "x"\nexposure = "sometimes"\n' > "$HS_SERVICES_DIR/broken.toml"
check_out "check names the mistakes" "broken: exposure must be one of" $S check
check_eq "and exits 1" "1" "$($S check >/dev/null 2>&1; echo $?)"
check_out "plan marks a broken file" "invalid" $S plan --plain
$S remove broken >/dev/null 2>&1
check "remove takes the file away" test ! -e "$HS_SERVICES_DIR/broken.toml"
check "remove of an unknown service fails" bash -c '! '"$S"' remove nosuch 2>/dev/null'

echo "-- set: local and public of an existing service, and the Apps read"
$S add setme --container jellyfin --port 9100 --title "Set me" >/dev/null 2>&1
check_eq "set --local yes" "updated" "$($S set setme --local yes 2>&1 | grep -o updated || true)"
check "local-proxy is true" grep -q 'local-proxy = true' "$HS_SERVICES_DIR/setme.toml"
$S set setme --public yes --public-name setme.example.org >/dev/null 2>&1
check "public is public-ok with the name" grep -q 'public-ok' "$HS_SERVICES_DIR/setme.toml"
check "reverse-proxy is true" grep -q 'reverse-proxy = true' "$HS_SERVICES_DIR/setme.toml"
check_eq "the Apps read has a row" "setme${T}jellyfin${T}Set me${T}yes${T}yes${T}setme.example.org${T}public-ok${T}no" "$($S apps | grep '^setme')"
$S set setme --public-name other.example.org >/dev/null 2>&1
check "--public-name alone renames" grep -q 'other.example.org' "$HS_SERVICES_DIR/setme.toml"
$S set setme --public no >/dev/null 2>&1
check "public no drops the name, goes private-ok" bash -c '! grep -q fqdn "$1" && grep -q private-ok "$1" && grep -q "reverse-proxy = false" "$1"' _ "$HS_SERVICES_DIR/setme.toml"
check "public yes needs a name" bash -c '! '"$S"' set setme --public yes 2>/dev/null'
$S add hidden --container jellyfin --port 9101 --exposure never-public >/dev/null 2>&1
check_out "never-public is refused" "never public" $S set hidden --public yes --public-name hidden.example.org
check "set of an unknown service fails" bash -c '! '"$S"' set nosuch --local yes 2>/dev/null'
$S remove setme >/dev/null 2>&1; $S remove hidden >/dev/null 2>&1
echo "-- edit and show"
# written by hand: scheme, fqdn and a public path are what the form does not set (and a /path argument gets mangled by Git Bash)
printf 'name = "wiki"
title = "Wiki"
container = "wikict"
port = 3000
scheme = "https"
names = ["wiki", "notes"]
fqdn = ["wiki.example.com"]
exposure = "private-ok"
public_paths = ["/hook"]

[want]
reverse-proxy = true
dashboard = true
local-proxy = true
' > "$HS_SERVICES_DIR/wiki.toml"
check_out "show prints where and machine" "where${T}container" $S show wiki
check_out "show prints the names" "names${T}wiki,notes" $S show wiki
check_out "show prints the paths" "public_paths${T}/hook" $S show wiki
check "show of an unknown service fails" bash -c '! '"$S"' show nosuch 2>/dev/null'
check "edit of an unknown service fails" bash -c '! '"$S"' edit nosuch --title X 2>/dev/null'
$S edit wiki --port 3001 --title Notes --want reverse-proxy >/dev/null 2>&1
check_out "edit changes the port" "port${T}3001" $S show wiki
check_out "edit changes the title" "title${T}Notes" $S show wiki
check_out "edit keeps what it was not given (names)" "names${T}wiki,notes" $S show wiki
check_out "edit keeps what the form does not show (fqdn)" "fqdn${T}wiki.example.com" $S show wiki
check_out "edit keeps a want the form does not own" "want${T}reverse-proxy,local-proxy" $S show wiki
$S edit wiki --clear title --clear names --clear public-path --want none >/dev/null 2>&1
check_out "edit clears the title" "title${T}-" $S show wiki
check_out "edit clears the names (back to the name)" "names${T}wiki" $S show wiki
check_out "edit clears the paths" "public_paths${T}-" $S show wiki
check_out "want none switches the owned wants off" "want${T}local-proxy" $S show wiki
$S edit wiki --host 10.0.0.9 >/dev/null 2>&1
check_out "edit switches container to host" "where${T}host" $S show wiki
check "edit refuses both targets" bash -c '! '"$S"' edit wiki --host a --container b 2>/dev/null'
check "edit refuses a bad exposure" bash -c '! '"$S"' edit wiki --exposure sometimes 2>/dev/null'
check "edit refuses a bad --clear" bash -c '! '"$S"' edit wiki --clear port 2>/dev/null'
$S remove wiki >/dev/null 2>&1

echo "-- a real Zoraxy: default site, several apps in one container, blocked paths, one host for several services"
rm -rf "$HS_SERVICES_DIR"
printf 'example.org,example.net' > "$HS_SETTINGS_DIR/proxyDomains"
cat > "$WORK/instances.json" <<'EOF'
[
 {"name":"docker","status":"Running","state":{"network":{"eth0":{"addresses":[{"family":"inet","scope":"global","address":"10.10.95.20"}]}}}},
 {"name":"authentik","status":"Running","state":{"network":{"eth0":{"addresses":[{"family":"inet","scope":"global","address":"10.10.95.23"}]}}}},
 {"name":"uptime-kuma","status":"Running","state":{"network":{"eth0":{"addresses":[{"family":"inet","scope":"global","address":"10.10.95.43"}]}}}},
 {"name":"synapse","status":"Running","state":{"network":{"eth0":{"addresses":[{"family":"inet","scope":"global","address":"10.10.95.46"}]}}}},
 {"name":"stalwart","status":"Running","state":{"network":{"eth0":{"addresses":[{"family":"inet","scope":"global","address":"10.10.95.47"}]}}}},
 {"name":"bulwark","status":"Running","state":{"network":{"eth0":{"addresses":[{"family":"inet","scope":"global","address":"10.10.95.48"}]}}}}
]
EOF
cat > "$WORK/rules.txt" <<'EOF'
## /opt/zoraxy/conf/proxy/default.config
{"RootOrMatchingDomain":"/","ActiveOrigins":[{"OriginIpOrDomain":"127.0.0.1:5487"}],"VirtualDirectories":[]}

## /opt/zoraxy/conf/proxy/api.config
{"RootOrMatchingDomain":"api.example.org","ActiveOrigins":[{"OriginIpOrDomain":"10.10.95.20:8055"}],"VirtualDirectories":[]}

## /opt/zoraxy/conf/proxy/auth.config
{"RootOrMatchingDomain":"auth.example.org","ActiveOrigins":[{"OriginIpOrDomain":"10.10.95.23:80"}],"VirtualDirectories":[{"MatchingPath":"/if/admin/","Domain":"127.0.0.1:1"}]}

## /opt/zoraxy/conf/proxy/distillery.config
{"RootOrMatchingDomain":"distillery.example.org","ActiveOrigins":[{"OriginIpOrDomain":"10.10.95.20:8054"}],"VirtualDirectories":[{"MatchingPath":"/outpost.goauthentik.io","Domain":"10.10.95.23:80"}]}

## /opt/zoraxy/conf/proxy/apex.config
{"RootOrMatchingDomain":"example.org","ActiveOrigins":[{"OriginIpOrDomain":"127.0.0.1:1"}],"VirtualDirectories":[{"MatchingPath":"/_matrix","Domain":"10.10.95.46:80"},{"MatchingPath":"/.well-known/matrix","Domain":"10.10.95.46:80"},{"MatchingPath":"/status","Domain":"10.10.95.43:3001"},{"MatchingPath":"/assets","Domain":"10.10.95.43:3001"}]}

## /opt/zoraxy/conf/proxy/apex2.config
{"RootOrMatchingDomain":"example.net","ActiveOrigins":[{"OriginIpOrDomain":"127.0.0.1:1"}],"VirtualDirectories":[{"MatchingPath":"/_matrix","Domain":"10.10.95.46:80"},{"MatchingPath":"/.well-known/matrix","Domain":"10.10.95.46:80"},{"MatchingPath":"/status","Domain":"10.10.95.43:3001"},{"MatchingPath":"/assets","Domain":"10.10.95.43:3001"}]}

## /opt/zoraxy/conf/proxy/webmail.config
{"RootOrMatchingDomain":"webmail.example.org","ActiveOrigins":[{"OriginIpOrDomain":"10.10.95.48:80"}],"VirtualDirectories":[{"MatchingPath":"/jmap","Domain":"10.10.95.47:8080"},{"MatchingPath":"/.well-known/jmap","Domain":"10.10.95.47:8080"}]}
EOF
imp=$($S import --dry-run 2>&1)
check_eq "the default site is no service" "0" "$(grep -c '^ *create.*  \*' <<<"$imp" || true)"
$S import --yes >/dev/null 2>&1
list=$($S list --plain)
check_eq "eight services" "8" "$(printf '%s\n' "$list" | grep -c .)"
check_eq "an app in the docker container is not an admin page" "public-ok" "$(awk -F"$T" '$3 == "docker:8055" { print $4 }' <<<"$list")"
check_eq "the Matrix paths are a service of their own" "1" "$(grep -l '"/_matrix"' "$HS_SERVICES_DIR"/*.toml | wc -l | tr -d ' ')"
check "and the status page paths are another one" bash -c 'grep -l "\"/status\"" '"$HS_SERVICES_DIR"'/*.toml | xargs grep -L "_matrix" | grep -q toml'
check "JMAP next to the webmail is its own service" grep -q 'container = "stalwart"' "$HS_SERVICES_DIR/stalwart.toml"
check_eq "a blocked path is not a published path" "0" "$(grep -rc 'if/admin' "$HS_SERVICES_DIR" | awk -F: '{ s += $2 } END { print s + 0 }')"
plan=$($S plan --plain)
check_eq "no violation and no conflict after the import" "0" "$(grep -cE '^(violation|conflict)' <<<"$plan")"
check_eq "only the default site and the blocked path are unmanaged" "2" "$(grep -c '^unmanaged' <<<"$plan")"
check_eq "the default site is called by its name" "1" "$(grep -c "^unmanaged${T}\*${T}/${T}127.0.0.1:5487.*default site" <<<"$plan")"
check_eq "a dead-end root wanted by two services is one row" "1" "$(grep -c "^ok${T}example.org${T}/${T}127.0.0.1:1" <<<"$plan")"
check_eq "a real root beats the dead end of the paths-only service" "1" "$(grep -c "^ok${T}webmail.example.org${T}/${T}10.10.95.48:80" <<<"$plan")"

echo "-- the local slot (gateway proxy, --proxy local): independent of the public one"
SAVE_SVC=$HS_SERVICES_DIR
export HS_SERVICES_DIR=$WORK/svc-local HS_CAPABILITIES_FILE=$WORK/caps HS_GATEWAY_DIR=$WORK/gw HS_GATEWAY_UNIT_STATE=$WORK/unit
export HS_MACHINE_FILE=$WORK/machine.toml HS_SITE_NAME_FILE=$WORK/site-name
mkdir -p "$HS_GATEWAY_DIR/routes" "$HS_GATEWAY_DIR/tmp"
printf 'active' > "$WORK/unit"; echo homeserver > "$HS_SITE_NAME_FILE"
printf 'hostName = "homeserver"\nadDomain = { realm = "AD.EXAMPLE.ORG", workgroup = "EX" }\n' > "$HS_MACHINE_FILE"
SL="$S"
check_out "refused while the capability is off" "gateway proxy is off" $SL plan --proxy local
check_eq "the machine-readable read answers status off while the capability is off" "status${T}off" "$($S plan --plain --proxy local)"
printf 'gateway\n' > "$HS_CAPABILITIES_FILE"
$S add jellyfin --container docker --port 8096 --exposure public-ok --want reverse-proxy,local-proxy >/dev/null
$S add docker --container docker --port 80 --exposure never-public --names docker,arcane --fqdn arcane.example.org --public-path /hook --want local-proxy >/dev/null
$S add secure --container docker --port 8443 --exposure private-ok --names secure --want local-proxy >/dev/null
sed -i 's/^port = 8443/port = 8443\nscheme = "https"/' "$HS_SERVICES_DIR/secure.toml"
$S add pubonly --container docker --port 9000 --exposure private-ok --want reverse-proxy >/dev/null
lp=$($S plan --plain --proxy local)
check_eq "local: a public-ok service gets its local name" "1" "$(grep -c "^add${T}jellyfin.homeserver.ad.example.org${T}/${T}10.10.95.20:8096" <<<"$lp")"
check_eq "local: a never-public admin page gets a local route" "1" "$(grep -c "^add${T}docker.homeserver.ad.example.org${T}/${T}10.10.95.20:80" <<<"$lp")"
check_eq "local: its second label too" "1" "$(grep -c "^add${T}arcane.homeserver.ad.example.org" <<<"$lp")"
check_eq "local: fqdn is ignored" "0" "$(grep -c "example.org${T}/hook\|^add${T}arcane.example.org" <<<"$lp")"
check_eq "local: public_paths are ignored (no path row, no dead end)" "0" "$(grep -c "/hook\|127.0.0.1:1" <<<"$lp")"
check_eq "local: an https target keeps its scheme" "1" "$(grep -c "^add${T}secure.homeserver.ad.example.org${T}/${T}https://10.10.95.20:8443" <<<"$lp")"
check_eq "local: a service that only wants the public proxy is not planned" "0" "$(grep -c pubonly <<<"$lp")"
printf 'zoraxy' > "$HS_SETTINGS_DIR/reverseProxy"; printf 'example.org' > "$HS_SETTINGS_DIR/proxyDomains"
pp=$($S plan --plain)
check_eq "public: the local-only services are not planned" "0" "$(grep -cE "docker|secure" <<<"$pp" | head -n1)"
check_eq "public: pubonly has its public row" "1" "$(grep -c "pubonly.example.org" <<<"$pp")"
check_eq "public: the both-wants service has a public row" "1" "$(grep -cE "^(add|confirm|ok|change)${T}jellyfin.example.org" <<<"$pp")"
$S add dd --container docker --port 7300 --exposure public-ok --names dd --fqdn dd.example.org --want reverse-proxy >/dev/null
check_eq "public: a fqdn equal to <name>.<domain> makes one add row, not two" "1" "$($S plan --plain | grep -cE "^(add|confirm)${T}dd.example.org")"
$S remove dd >/dev/null 2>&1
$S add pn --container docker --port 7310 --exposure public-ok --fqdn files.example.org --want reverse-proxy >/dev/null
pn=$($S plan --plain | grep -E "${T}pn${T}")
check_eq "public: a public name replaces the default <name>.<domain> host" "1" "$(grep -c "files.example.org" <<<"$pn")"
check_eq "public: no pn.<domain> host next to the public name" "0" "$(grep -c "pn.example.org" <<<"$pn")"
$S remove pn >/dev/null 2>&1
$S add tilel --container docker --port 7400 --title TileL --want dashboard,local-proxy >/dev/null
$S add tilep --container docker --port 7500 --title TileP --want dashboard >/dev/null
tl=$($S tiles)
check_eq "tiles: a service with a gateway name links to <name>.<local domain>" "http://tilel.homeserver.ad.example.org" "$(awk -F"$T" '$2 == "TileL" { print $3 }' <<<"$tl")"
check_eq "tiles: without the local-proxy want it links to the address" "http://10.10.95.20:7500" "$(awk -F"$T" '$2 == "TileP" { print $3 }' <<<"$tl")"
printf 'cloud
' > "$HS_CAPABILITIES_FILE"
check_eq "tiles: gateway off, the address again" "http://10.10.95.20:7400" "$($S tiles | awk -F"$T" '$2 == "TileL" { print $3 }')"
printf 'gateway
' > "$HS_CAPABILITIES_FILE"
$S remove tilel >/dev/null 2>&1; $S remove tilep >/dev/null 2>&1
printf 'zoraxy' > "$HS_SETTINGS_DIR/reverseProxy"

echo "-- the local slot: apply, explicit DNS records, adds-only, import"
cat > "$WORK/dns.sh" <<'EOF2'
#!/usr/bin/env bash
printf 'jellyfin.homeserver.ad.example.org\tA\t10.10.95.50\n*.homeserver.ad.example.org\tA\t192.168.1.10\n'
EOF2
printf 'ad\n' >> "$HS_CAPABILITIES_FILE"
export HS_DNS_SH=$WORK/dns.sh
lp=$($S plan --plain --proxy local)
check_eq "an explicit record is named in the note" "1" "$(grep -c "^add${T}jellyfin.homeserver.ad.example.org.*explicit DNS record jellyfin.homeserver.ad.example.org beats the wildcard.*10.10.95.50" <<<"$lp")"
check_eq "the wildcard record itself is no name" "0" "$(grep -c "beats the wildcard" <<<"$(grep -v jellyfin <<<"$lp")")"
unset HS_DNS_SH
printf 'gateway\n' > "$HS_CAPABILITIES_FILE"
check_out "apply makes the routes" "4 done, 0 failed" $S apply --proxy local
check_eq "files exist for each host" "4" "$(ls "$HS_GATEWAY_DIR/routes" | grep -c '^local-')"
check_eq "the tmp folder is empty" "" "$(ls "$HS_GATEWAY_DIR/tmp")"
lp=$($S plan --plain --proxy local)
check_eq "afterwards everything is ok" "4" "$(grep -c "^ok" <<<"$lp")"
check_eq "the public plan does not know the local routes" "0" "$(grep -c "homeserver.ad.example.org" <<<"$($S plan --plain)")"
sed -i 's/^port = 8096/port = 8097/' "$HS_SERVICES_DIR/jellyfin.toml"
$S add extra --container docker --port 7000 --want local-proxy >/dev/null
out=$($S apply --proxy local --adds-only 2>&1)
check_out "adds-only adds the new one" "extra.homeserver.ad.example.org" echo "$out"
check_eq "adds-only asked nothing and did not change jellyfin" "1" "$($S plan --plain --proxy local | grep -c "^change${T}jellyfin")"
check_out "a change needs the typed host (no terminal: skipped)" "needs the typed confirmation" $S apply --proxy local
check_out "or --confirm" "1 done" $S apply --proxy local --confirm jellyfin.homeserver.ad.example.org
$S add plain --container docker --port 7100 >/dev/null
check_out "import --proxy local lists a service without the want" "enable +plain" $S import --proxy local --dry-run
$S import --proxy local --yes >/dev/null
check "and writes local-proxy = true" grep -q 'local-proxy = true' "$HS_SERVICES_DIR/plain.toml"
check_out "a second import has nothing to do" "already says" $S import --proxy local --yes
sed -i 's/local-proxy = true/local-proxy = false/' "$HS_SERVICES_DIR/plain.toml"
check_out "a person's false stays" "already says" $S import --proxy local --yes
check "false is kept in the file" grep -q 'local-proxy = false' "$HS_SERVICES_DIR/plain.toml"

echo "-- the local slot refuses a provider that says public"
mkdir -p "$WORK/prov2/reverse-proxy"
printf '#!/usr/bin/env bash\ncase "$1" in info) printf "name\ttraefik\npublic\tyes\ndomains\tx.test\nmode\tapi\n" ;; list|owned-list) ;; esac\n' > "$WORK/prov2/reverse-proxy/traefik.sh"
check_out "refused" "must never be public" env HS_PROVIDER_DIR=$WORK/prov2 bash "$SCRIPTS/services.sh" plan --proxy local
export HS_SERVICES_DIR=$SAVE_SVC
unset HS_CAPABILITIES_FILE

echo "-- declare-known (containers set up before their recipe declared a service; one release)"
DK=$WORK/dk; mkdir -p "$DK/state" "$DK/svc"
cat > "$DK/incus" <<'EOF'
#!/usr/bin/env bash
case "$*" in "list -c ns -f csv") printf 'jellyfin,RUNNING\nzoraxy,RUNNING\nimmich,STOPPED\nother,RUNNING\n' ;; esac
EOF
chmod +x "$DK/incus"
printf 'PORT=8001\n' > "$DK/state/recipe-zoraxy.conf"
printf 'name = "jellyfin"\n' > "$DK/svc/jellyfin.toml"
DKS="env HS_INCUS=$DK/incus HS_STATE_DIR=$DK/state HS_SERVICES_DIR=$DK/svc bash $SCRIPTS/services.sh declare-known"
out=$($DKS --dry-run 2>&1)
check_eq "--dry-run says what it would do and writes nothing" "would-create${T}zoraxy
skip${T}jellyfin${T}already declared" "$out"
check "dry-run: no file" test ! -e "$DK/svc/zoraxy.toml"
out=$($DKS 2>&1)
check_eq "creates zoraxy only; jellyfin is skipped; stopped and unknown containers are not named" "created${T}zoraxy
skip${T}jellyfin${T}already declared" "$out"
check "the descriptor is there" test -e "$DK/svc/zoraxy.toml"
check_out "the port comes from recipe-zoraxy.conf" "8001" cat "$DK/svc/zoraxy.toml"
check_out "it wants the dashboard" "dashboard" cat "$DK/svc/zoraxy.toml"
check_eq "a second run creates nothing" "0" "$($DKS 2>&1 | grep -c '^created' || true)"
check_eq "no empty field in the lines" "0" "$($DKS 2>&1 | awk -F"$T" '{ for (i = 1; i <= NF; i++) if ($i == "") bad++ } END { print bad + 0 }')"

echo "-- stats: [[stats]] descriptors, stats-plan, stat-value"
SP="python3 $SCRIPTS/services.py"
SD=$WORK/stats.d; mkdir -p "$SD"
JS='http-json|Streams|/Sessions?activeWithinSeconds=960||count|/NowPlayingItem|stat-jellyfin|mediabrowser||int'
out=$($SP declare jellyfin --dir "$SD" --container jellyfin --port 8096 --stat "$JS" 2>&1)
check_eq "declare --stat creates the service" "created" "$out"
check_out "the descriptor holds a [[stats]] block" '\[\[stats\]\]' cat "$SD/jellyfin.toml"
check_out "the stat names its secret" 'secret = "stat-jellyfin"' cat "$SD/jellyfin.toml"
check_out "the empty pointer is written" 'pointer = ""' cat "$SD/jellyfin.toml"
check "the descriptor is valid" $SP check --dir "$SD"
$SP declare jellyfin --dir "$SD" --container jellyfin --port 8096 --icon mdi-movie >/dev/null 2>&1
check_out "no --stat keeps the stats" 'label = "Streams"' cat "$SD/jellyfin.toml"
$SP declare jellyfin --dir "$SD" --stat 'http-json|Films|/Items/Counts|/MovieCount|||stat-jellyfin|mediabrowser||int' >/dev/null 2>&1
check_eq "--stat replaces them" "1" "$(grep -c '^label' "$SD/jellyfin.toml")"
check_out "the new one is there" 'label = "Films"' cat "$SD/jellyfin.toml"
$SP declare jellyfin --dir "$SD" --no-stats >/dev/null 2>&1
check_eq "--no-stats removes them" "0" "$(grep -c 'stats' "$SD/jellyfin.toml" || true)"
$SP declare jellyfin --dir "$SD" --stat "$JS" >/dev/null 2>&1
check_out "a stat with a wrong field count is refused" "needs 10 fields" $SP declare jellyfin --dir "$SD" --stat 'http-json|x'

bad() {   # bad "what" "stat" "text of the problem"
  rm -rf "$SD/b.d"; mkdir -p "$SD/b.d"
  local o; o=$($SP declare b --dir "$SD/b.d" --container jellyfin --port 80 --stat "$2" 2>&1) || true
  case "$o" in *"$3"*) pass "$1" ;; *) fail "$1 (got: $o)" ;; esac
}
bad "a path with // is refused" 'http-json|X|/a//b|||||||' "path must"
bad "a path with @ is refused" 'http-json|X|/a@b|||||||' "path must"
bad "a path with .. is refused" 'http-json|X|/a/../b|||||||' "path must"
bad "a path without a slash is refused" 'http-json|X|a|||||||' "path must"
bad "a label over 24 characters is refused" 'http-json|0123456789012345678901234|/a|||||||' "label must"
bad "an unknown kind is refused" 'shell|X|/a|||||||' "kind must"
bad "a secret without auth is refused" 'http-json|X|/a||||stat-x|||' "secret needs auth"
bad "a foreign secret name is refused" 'http-json|X|/a||||restic-password|bearer||' "secret must"
bad "an unknown auth is refused" 'http-json|X|/a||||stat-x|basic||' "auth must"
bad "where without count is refused" 'http-json|X|/a|||/b||||' "where needs"
bad "a pointer without a slash is refused" 'http-json|X|/a|abc||||||' "pointer must"
bad "a unit over 8 characters is refused" 'http-json|X|/a||||||123456789|' "unit must"
bad "an unknown format is refused" 'http-json|X|/a|||||||hex' "format must"
printf 'name = "u"\ncontainer = "jellyfin"\nport = 80\n[[stats]]\nkind = "http-json"\nlabel = "X"\npath = "/a"\nrun = "rm"\n' > "$SD/u.toml"
check_out "an unknown key is refused" "unknown key run" $SP check --dir "$SD"
rm -f "$SD/u.toml"
printf 'name = "f"\ncontainer = "jellyfin"\nport = 80\n' > "$SD/f.toml"
for i in 1 2 3 4; do printf '[[stats]]\nkind = "http-json"\nlabel = "X"\npath = "/a"\n' >> "$SD/f.toml"; done
check_out "four stats are refused" "at most 3" $SP check --dir "$SD"
rm -f "$SD/f.toml"

printf 'jellyfin\t10.10.95.50\n' > "$WORK/stats-addrs"
$SP declare web --dir "$SD" --host 192.168.1.9 --port 8443 --scheme https --stat 'http-json|Up|/s|||||||text' >/dev/null 2>&1
$SP declare ghost --dir "$SD" --container nowhere --port 80 --stat 'http-json|X|/a|||||||' >/dev/null 2>&1
out=$($SP stats-plan --dir "$SD" --addrs "$WORK/stats-addrs" 2>&1)
check_eq "stats-plan: own address, secret and auth, - for none; no address, no line" "jellyfin${T}0${T}http://10.10.95.50:8096/Sessions?activeWithinSeconds=960${T}stat-jellyfin${T}mediabrowser
web${T}0${T}https://192.168.1.9:8443/s${T}-${T}-" "$out"

sv() {   # sv JSON STAT: the value stat-value prints for that body
  rm -rf "$SD/v.d"; mkdir -p "$SD/v.d"
  $SP declare v --dir "$SD/v.d" --container jellyfin --port 80 --stat "$2" >/dev/null 2>&1
  printf '%s' "$1" | $SP stat-value v 0 --dir "$SD/v.d" 2>&1
}
check_eq "pointer, int" "7" "$(sv '{"a":{"b":7}}' 'http-json|X|/a|/a/b||||||')"
check_eq "pointer into a list, ~1 escape" "5" "$(sv '{"a/b":[1,5]}' 'http-json|X|/a|/a~1b/1||||||')"
check_eq "count" "3" "$(sv '[1,2,3]' 'http-json|X|/a||count|||||')"
check_eq "count + where" "2" "$(sv '[{"N":{"a":1}},{"N":null},{"N":"x"},{"M":1}]' 'http-json|X|/a||count|/N||||')"
check_eq "float1" "3.5" "$(sv '{"v":3.456}' 'http-json|X|/a|/v||||||float1')"
check_eq "text is cut at 24" "012345678901234567890123" "$(sv '{"v":"0123456789012345678901234567"}' 'http-json|X|/a|/v||||||text')"
for c in 'a miss|{"a":1}|/b|int' 'a text for int|{"a":"x"}|/a|int' 'a bool for int|{"a":true}|/a|int' 'a dict for text|{"a":{}}|/a|text'; do
  IFS='|' read -r nm js pt fm <<< "$c"
  sv "$js" "http-json|X|/a|$pt||||||$fm" > "$WORK/sv.out" 2>&1 && rc=0 || rc=$?
  check_eq "$nm: exit 1 and nothing printed" "1:" "$rc:$(cat "$WORK/sv.out")"
done

echo "-- registry"
for w in "services list" "services check" "services plan" "services add" "services edit" "services remove" "services import" "services declare-known"; do
  check "user row: $w" grep -q "^user${T}$w${T}services.sh${T}" "$SCRIPTS/lib/registry.tsv"
done
for w in "sys services list" "sys services show <name>" "sys services plan"; do
  check "row: $w" grep -q "^sys${T}$w${T}services.sh${T}" "$SCRIPTS/lib/registry.tsv"
done

finish
