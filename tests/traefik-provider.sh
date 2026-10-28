#!/usr/bin/env bash
# The local proxy provider (scripts/providers/reverse-proxy/traefik.sh): info, list, owned-list, ensure, remove against a folder. No Traefik.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test HS_PYTHON=python3
export HS_GATEWAY_DIR=$WORK/gw HS_MACHINE_FILE=$WORK/machine.toml HS_SITE_NAME_FILE=$WORK/site-name HS_GATEWAY_UNIT_STATE=$WORK/unit
P="bash $SCRIPTS/providers/reverse-proxy/traefik.sh"
T=$'\t'
mkdir -p "$HS_GATEWAY_DIR/routes" "$HS_GATEWAY_DIR/tmp"
printf 'hostName = "homeserver"\nadDomain = { realm = "AD.EXAMPLE.ORG", workgroup = "EX" }\n' > "$HS_MACHINE_FILE"
echo homeserver > "$HS_SITE_NAME_FILE"
printf 'active' > "$HS_GATEWAY_UNIT_STATE"
H=app.homeserver.ad.example.org

echo "-- info"
check_eq "info: name, public no, the local domain, api" "name${T}traefik|public${T}no|domains${T}homeserver.ad.example.org|mode${T}api" "$($P info | tr '\n' '|' | sed 's/|$//')"
printf 'inactive' > "$HS_GATEWAY_UNIT_STATE"
check_out "a stopped Traefik is a note" "note${T}Traefik is not running" $P info
printf 'active' > "$HS_GATEWAY_UNIT_STATE"
printf 'hostName = "homeserver"\n' > "$HS_MACHINE_FILE"
check_eq "without adDomain the domains field is empty" "domains${T}" "$($P info | grep '^domains')"
printf 'hostName = "homeserver"\nadDomain = { realm = "AD.EXAMPLE.ORG", workgroup = "EX" }\n' > "$HS_MACHINE_FILE"
check_eq "check" ok "$($P check)"
check "login-check says no login is needed" bash -c "! $P login-check /dev/null"
check "adopt is a no-op" $P adopt "$H" /

echo "-- ensure, list, owned-list"
check_eq "nothing yet" "" "$($P list)"
check "ensure a root route" $P ensure "$H" / 10.10.95.50:8096
check_eq "list: host path target id" "$H${T}/${T}10.10.95.50:8096${T}local-$H.yml" "$($P list)"
check_eq "owned-list: host path" "$H${T}/" "$($P owned-list)"
check "ensure a second path" $P ensure "$H" /api https://10.10.95.50:8443
check_eq "the first path stays" "2" "$($P list | wc -l | tr -d ' ')"
check_out "the https target is kept" "/api${T}https://10.10.95.50:8443" $P list
check "ensure again with another target changes it" $P ensure "$H" / 10.10.95.51:8096
check_out "the new target" "^$H${T}/${T}10.10.95.51:8096" $P list
check_eq "still two routes" "2" "$($P list | wc -l | tr -d ' ')"
check_eq "tmp is empty after" "" "$(ls "$HS_GATEWAY_DIR/tmp")"
case "$(uname -s)" in
  MINGW*|MSYS*) skip "file mode (Windows file system)" ;;
  *) check_eq "the file is 0640" "640" "$(stat -c %a "$HS_GATEWAY_DIR/routes/local-$H.yml")" ;;
esac
check "a bad host is a render error (exit 1)" bash -c "! $P ensure 'Bad Host' / 1.2.3.4:80"
check_eq "and left no file or temp file" "" "$(ls "$HS_GATEWAY_DIR/tmp"; ls "$HS_GATEWAY_DIR/routes" | grep -v "^local-$H")"

echo "-- remove"
check "remove one path" $P remove "$H" /api
check_eq "the root stays" "$H${T}/${T}10.10.95.51:8096${T}local-$H.yml" "$($P list)"
check "remove the last route" $P remove "$H" /
check "its file is gone" test ! -e "$HS_GATEWAY_DIR/routes/local-$H.yml"
check "removing again is fine" $P remove "$H" /
check_eq "tmp is empty" "" "$(ls "$HS_GATEWAY_DIR/tmp")"
echo "hand made" > "$HS_GATEWAY_DIR/routes/mine.yml"
$P ensure "$H" / 10.0.0.2:80 >/dev/null
check "a hand-made file is untouched" test "$(cat "$HS_GATEWAY_DIR/routes/mine.yml")" = "hand made"
check_eq "and not listed as ours" "1" "$($P owned-list | wc -l | tr -d ' ')"
finish
