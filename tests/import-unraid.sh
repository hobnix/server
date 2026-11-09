#!/usr/bin/env bash
# hs docker import-unraid (scripts/import-unraid.sh, scripts/lib/unraid_import.py) on the templates in tests/fixtures/unraid/. No Docker, no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi
export HS_LANG=en HS_PLAIN=1
F=$ROOT/tests/fixtures/unraid
IMP="bash $ROOT/scripts/import-unraid.sh"
runi() { "$@" </dev/null 2>&1; }

echo "-- plan only"
out=$(runi $IMP "$F/plex.xml") && rc=0 || rc=$?
check_eq "preview exits 0" 0 "$rc"
grep -q '32400:32400/tcp' <<<"$out" && pass "port mapped" || fail "port missing"
grep -q '1900:1900/udp' <<<"$out" && pass "udp port mapped" || fail "udp port missing"
grep -q './data/plex -> /config' <<<"$out" && pass "appdata path mapped" || fail "appdata path missing"
grep -q 'http://<server>:32400/web' <<<"$out" && pass "WebUI address resolved" || fail "WebUI missing"
grep -q 'outside appdata' <<<"$out" && pass "array path listed as unmapped" || fail "array path not flagged"
grep -q 'ExtraParams' <<<"$out" && pass "ExtraParams listed as unmapped" || fail "ExtraParams not flagged"
grep -q '/dev/dvb' <<<"$out" && pass "other device listed as unmapped" || fail "device not flagged"
grep -q 'claim-secretvalue' <<<"$out" && fail "a secret was printed" || pass "secret value never printed"
grep -q 'Preview only' <<<"$out" && pass "says nothing was written" || fail "no preview note"

echo "-- draft"
D=$WORK/draft
out=$(runi $IMP "$F/plex.xml" --out "$D" --name myplex) && rc=0 || rc=$?
check_eq "--out exits 0" 0 "$rc"
check "compose written" test -s "$D/docker-compose.yml"
check "env file written" test -s "$D/app.env"
grep -q 'claim-secretvalue' "$D/docker-compose.yml" "$D/app.env" && fail "secret copied into the draft" || pass "secret not in the draft"
check_eq "env file names the secret, empty" "PLEX_CLAIM=" "$(cat "$D/app.env")"
grep -q 'image: "lscr.io/linuxserver/plex:1.41.0"' "$D/docker-compose.yml" && pass "image in the draft" || fail "image missing"
grep -q '"./data/plex:/config"' "$D/docker-compose.yml" && pass "bind in the draft" || fail "bind missing"
grep -q '/mnt/user/media' "$D/docker-compose.yml" && fail "array path leaked into the draft" || pass "array path not in the draft"
grep -q 'hs docker import .*--name myplex' <<<"$out" && pass "points at the compose importer" || fail "next step missing"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  (cd "$D" && PLEX_CLAIM=x docker compose -f docker-compose.yml config -q) && pass "docker compose accepts the draft" || fail "docker compose rejects the draft"
else skip "docker compose missing: draft not validated"; fi
out=$(runi $IMP "$F/plex.xml" --out "$D") && rc=0 || rc=$?
check_eq "never overwrites a folder" 1 "$rc"

echo "-- refused and odd templates"
out=$(runi $IMP "$F/host-privileged.xml" --out "$WORK/odd") && rc=0 || rc=$?
check_eq "odd template still drafts" 0 "$rc"
for w in 'privileged' 'host is not mapped' 'PostArgs' 'no version in the template'; do
  grep -q "$w" <<<"$out" && pass "flagged: $w" || fail "not flagged: $w"
done
grep -qE 'privileged|network_mode|\.\./' "$WORK/odd/docker-compose.yml" && fail "dangerous setting in the draft" || pass "no dangerous setting in the draft"
check "no env file without secrets" test ! -e "$WORK/odd/app.env"
out=$(runi $IMP "$F/entity.xml") && rc=0 || rc=$?
check_eq "DOCTYPE/ENTITY refused" 1 "$rc"
out=$(runi $IMP "$F/not-a-template.xml") && rc=0 || rc=$?
check_eq "not a template refused" 1 "$rc"
out=$(runi $IMP "$F/missing.xml") && rc=0 || rc=$?
check_eq "missing file refused" 1 "$rc"
out=$(runi $IMP "$F/plex.xml" --name 'Bad Name') && rc=0 || rc=$?
check_eq "bad app name refused" 1 "$rc"
finish
