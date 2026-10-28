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
check_eq "info: public, domains, read-only" "name${T}zoraxy|public${T}yes|domains${T}example.org|mode${T}read-only" "$($Z info | grep -v "^note" | tr '\n' '|' | sed 's/|$//')"
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
check_out "homepage:80 public-ok is refused, with the reason" "admin page" $S add hs-test --container homepage --port 80 --exposure public-ok --want reverse-proxy
check "and nothing was written" test ! -e "$HS_SERVICES_DIR/hs-test.toml"
$S add hs-ok --container homepage --port 80 --exposure never-public --want reverse-proxy >/dev/null 2>&1
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
check_out "an admin page cannot be declared public-ok" "admin page" $S declare adm --container homepage --port 80 --exposure public-ok
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
# what homepage.sh does with the line: the same read
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

echo "-- registry"
for w in "services list" "services check" "services plan" "services add" "services remove" "services import"; do
  check "user row: $w" grep -q "^user${T}$w${T}services.sh${T}" "$SCRIPTS/lib/registry.tsv"
done
for w in "sys services list" "sys services plan"; do
  check "row: $w" grep -q "^sys${T}$w${T}services.sh${T}" "$SCRIPTS/lib/registry.tsv"
done

finish
