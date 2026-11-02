#!/usr/bin/env bash
# hs sys recipes list, hs sys config list|check|plan|start (scripts/recipes-list.sh, config-read.sh, config-change.sh). No root: a copy of
# machine.toml.example as the file, a fake incus, a fake recipes folder.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en
unset HS_CALLER HS_GUIDED_TTY
T=$'\t'
export HS_STATE_DIR=$WORK/state HS_ETC_DIR=$WORK/etc HS_MACHINE_EXAMPLE=$ROOT/machine.toml.example HS_MACHINE_FILE=$WORK/machine.toml
mkdir -p "$HS_STATE_DIR" "$HS_ETC_DIR"

echo "-- recipes list"
mkdir -p "$WORK"/recipes/{arr,jellyfin,pelican,sunshine,nodesc,domain}
printf '#!/usr/bin/env bash\n# recipe: arr: Radarr and Sonarr\nct=${RECIPE_NAME:-arr}\n' > "$WORK/recipes/arr/run.sh"
printf '#!/usr/bin/env bash\n# recipe: Jellyfin: watch films\nct=${RECIPE_NAME:-jellyfin}\n' > "$WORK/recipes/jellyfin/run.sh"
printf '#!/usr/bin/env bash\n# recipe: Pelican: game servers\n' > "$WORK/recipes/pelican/run.sh"
printf '#!/usr/bin/env bash\n# recipe: Sunshine: games on the TV\nct=${RECIPE_NAME:-sunshine}\n' > "$WORK/recipes/sunshine/run.sh"
printf '#!/usr/bin/env bash\nct=${RECIPE_NAME:-nodesc}\n' > "$WORK/recipes/nodesc/run.sh"
printf '#!/usr/bin/env bash\nprintf "arr\\npelican-panel\\n"\n' > "$WORK/incus"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/incus-down"
printf '#!/usr/bin/env bash\n# recipe: Domain: the domain controller\nct=${RECIPE_NAME:-$([ -n "$join_dc" ] && echo dc2 || echo dc1)}\n' > "$WORK/recipes/domain/run.sh"
printf '#!/usr/bin/env bash\nprintf "dc1\\n"\n' > "$WORK/incus-dc"
chmod +x "$WORK/incus" "$WORK/incus-down" "$WORK/incus-dc"
export HS_RECIPES_DIR=$WORK/recipes HS_INCUS=$WORK/incus
out=$(bash "$SCRIPTS/recipes-list.sh")
check_eq "one row per recipe" 6 "$(wc -l <<<"$out" | tr -d ' ')"
check_eq "the name prefix is cut from the description" "arr${T}Radarr and Sonarr${T}arr${T}installed" "$(grep '^arr' <<<"$out")"
check_eq "a recipe whose container is missing" "jellyfin${T}Watch films${T}jellyfin${T}not installed" "$(grep '^jellyfin' <<<"$out")"
check_eq "a recipe with two instances, one there" "pelican${T}Game servers${T}pelican-panel,pelican-wings${T}partly" "$(grep '^pelican' <<<"$out")"
check_eq "sunshine is parked" "parked" "$(awk -F'\t' '$1 == "sunshine" { print $4 }' <<<"$out")"
check_eq "a fixed text without a header line" "App recipe nodesc (hs recipe nodesc)" "$(awk -F'\t' '$1 == "nodesc" { print $2 }' <<<"$out")"
check_eq "domain: installed when the controller dc1 exists" "domain${T}installed" "$(HS_INCUS=$WORK/incus-dc bash "$SCRIPTS/recipes-list.sh" | awk -F'\t' '$1 == "domain" { print $1 FS $4 }')"
check_eq "domain: not installed without a controller" "domain${T}not installed" "$(awk -F'\t' '$1 == "domain" { print $1 FS $4 }' <<<"$out")"
check_eq "incus not answering: unknown" "unknown" "$(HS_INCUS=$WORK/incus-down bash "$SCRIPTS/recipes-list.sh" | awk -F'\t' '$1 == "arr" { print $4 }')"
echo "-- recipes versions"
printf 'name = "arr"\nversion = "1.2.0"\n' > "$WORK/recipes/arr/package.toml"
printf 'name = "jellyfin"\nversion = "1.2.0"\n' > "$WORK/recipes/jellyfin/package.toml"
mkdir -p "$HS_STATE_DIR/packages"
printf '[package.arr]\nversion = "1.2.0"\napplied = "1.2.0"\n\n[package.jellyfin]\nversion = "1.2.0"\napplied = "1.0.0"\n' > "$HS_STATE_DIR/packages/installed.toml"
vout=$(bash "$SCRIPTS/recipes-versions.sh")
check_eq "current" "arr${T}1.2.0${T}1.2.0${T}current" "$(grep '^arr' <<<"$vout")"
check_eq "update" "jellyfin${T}1.2.0${T}1.0.0${T}update" "$(grep '^jellyfin' <<<"$vout")"
check_eq "nothing known" "nodesc${T}-${T}-${T}unknown" "$(grep '^nodesc' <<<"$vout")"
check_eq "every row has 4 fields" "" "$(awk -F'\t' 'NF != 4 { print $1 }' <<<"$vout")"
check_eq "same names as recipes-list.sh" "$(bash "$SCRIPTS/recipes-list.sh" | cut -f1)" "$(cut -f1 <<<"$vout")"
unset HS_RECIPES_DIR
check_eq "the real recipes: no helper rows" 0 "$(HS_INCUS=$WORK/incus-down bash "$SCRIPTS/recipes-list.sh" | grep -c '^_')"
check_eq "the real recipes: every row has 4 fields" "" "$(HS_INCUS=$WORK/incus-down bash "$SCRIPTS/recipes-list.sh" | awk -F'\t' 'NF != 4 { print $1 }')"

echo "-- config list"
cp "$ROOT/machine.toml.example" "$HS_MACHINE_FILE"
sed -i 's|^# metrics = true|metrics = false|' "$HS_MACHINE_FILE"
# runtime settings (store = settings) are files, not lines of machine.toml
mkdir -p "$HS_STATE_DIR/settings"; echo de > "$HS_STATE_DIR/settings/language"; echo "https://ntfy.sh/very-secret" > "$HS_STATE_DIR/notify-url"
echo on > "$HS_ETC_DIR/login-message"
list=$(bash "$SCRIPTS/config-read.sh" list)
col() { awk -F'\t' -v k="$1" -v c="$2" '$2 == k { print $c }' <<<"$list"; }
check_eq "every row has 8 fields" "" "$(awk -F'\t' 'NF != 8 { print $2 }' <<<"$list")"
check_eq "one row per option of the example" "$(python3 "$SCRIPTS/schema-gen.py" list | wc -l | tr -d ' ')" "$(wc -l <<<"$list" | tr -d ' ')"
check_eq "a value that is set" "de" "$(col language 3)"
check_eq "an option that is off has no current value" "" "$(col keyMap 3)"
check_eq "its default is the example's" "de" "$(col keyMap 4)"
check_eq "the type of a bool" "bool" "$(col metrics 5)"
check_eq "a false bool is written false" "false" "$(col metrics 3)"
check_eq "the type of a number" "number" "$(col syncEveryHours 5)"
check_eq "the type of a table" "table" "$(col vlans 5)"
check_eq "the type of a list" "list" "$(col sshKeys 5)"
check_eq "the store of a runtime setting" "settings" "$(col language 8)"
check_eq "the store of a machine option" "machine" "$(col hostName 8)"
check_eq "a setting found only in the old /etc/hs file (on is true)" "true" "$(col loginMessage 3)"
check_eq "the section" "Interface" "$(col language 1)"
check_eq "settable" "yes" "$(col language 7)"
check_eq "not settable" "no" "$(col hostName 7)"
check_eq "a secret shows only that it is set" "(set)" "$(col notifyUrl 3)"
check_eq "a secret that is not set" "(not set)" "$(col heartbeatUrl 3)"
if grep -q "very-secret" <<<"$list"; then fail "the secret value is in the list"; else pass "the secret value is not in the list"; fi
# nodeKeys (the public keys of other nodes) is a plain list on purpose; the keys that log in as adminuser are secret
if grep -a "^[^	]*	sshKeys	" <<<"$list" | grep -q "ssh-ed25519"; then fail "an SSH key is in the list"; else pass "no SSH key in the list"; fi
case "$(col language 6)" in *"Language of the descriptions"*) pass "help text from the example" ;; *) fail "help text: $(col language 6)" ;; esac

echo "-- config check"
check_out "check names the problem" "^error: hostId: still CHANGEME" bash "$SCRIPTS/config-read.sh" check
sed -i 's/^hostId = .*/hostId = "deadbeef"/' "$HS_MACHINE_FILE"
check_eq "check on a good file" "machine.toml is fine." "$(bash "$SCRIPTS/config-read.sh" check)"

echo "-- config plan"
run() { rc=0; out=$(timeout 30 bash "$SCRIPTS/config-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }
run plan set syncEveryHours 6
check_eq "plan: exit 0" 0 "$rc"
has "^status${T}ok$" && has "^heading${T}set syncEveryHours$" && has "^command${T}hs sys config start set syncEveryHours 6$" && has "^note${T}.*hs rebuild" && has "^long${T}no$" && pass "plan lines" || fail "plan: $out"
check_eq "plan changes nothing" "" "$(grep -c '^syncEveryHours = 6' "$HS_MACHINE_FILE" | sed 's/^0$//')"
run plan set hostName other;           check_eq "a key that is not settable is refused" 1 "$rc"; has "^reason${T}" && pass "with a reason" || fail "reason: $out"
run plan set nosuchkey 1;              check_eq "an unknown key is refused" 1 "$rc"
run plan set metrics maybe;            check_eq "a bool must be true or false" 1 "$rc"
run plan set syncEveryHours 5;         check_eq "a number out of the allowed ones" 1 "$rc"
run plan set metricsDays abc;          check_eq "a number must be a number" 1 "$rc"
run plan set language fr;              check_eq "language is en or de" 1 "$rc"
run plan set webAccent red;            check_eq "webAccent must be a colour" 1 "$rc"
run plan set language 'x"y';           check_eq "quotes are refused" 1 "$rc"
run plan set language de;              check_eq "the value that is set already" 1 "$rc"
run plan set keyMap "";                check_eq "switching off what is off already" 1 "$rc"
run plan set notifyUrl https://x;      check_eq "secrets are not settable" 1 "$rc"
run plan set language en;              check_eq "a runtime setting: plan ok" 0 "$rc"; has "^note${T}.*no rebuild" && pass "and says no rebuild is needed" || fail "no-rebuild note: $out"

echo "-- config start"
run start set syncEveryHours 6
check_eq "start: exit 0" 0 "$rc"; has "^status${T}done$" && pass "status done" || fail "start: $out"
check_eq "the value is in the file" "syncEveryHours = 6" "$(grep '^syncEveryHours' "$HS_MACHINE_FILE")"
check_eq "a copy of the old file" "yes" "$(test -f "$HS_STATE_DIR/machine.toml.before-config" && echo yes)"
run start set language en;             check_eq "a runtime setting goes to its file" "en" "$(cat "$HS_STATE_DIR/settings/language")"
check_eq "and not into machine.toml" "0" "$(grep -c '^language' "$HS_MACHINE_FILE" || true)"
run start set language "";             check_eq "an empty value removes the file" "no" "$(test -e "$HS_STATE_DIR/settings/language" && echo yes || echo no)"
run start set language "";             check_eq "removing what is not set is refused" 1 "$rc"
run start set metrics true;            check_eq "a bool" "metrics = true" "$(grep '^metrics =' "$HS_MACHINE_FILE")"
run start set keyMap us;               check_eq "an option that was off is switched on in its place" 'keyMap = "us"' "$(grep '^keyMap' "$HS_MACHINE_FILE")"
run start set keyMap "";               check_eq "an empty value switches it off" '# keyMap = "us"' "$(grep 'keyMap = ' "$HS_MACHINE_FILE")"
before=$(cat "$HS_MACHINE_FILE")
run start set hostName x;              check_eq "start refuses what plan refuses" 1 "$rc"
check_eq "and changes nothing" "$before" "$(cat "$HS_MACHINE_FILE")"
sed -i 's/^hostId = .*/hostId = "CHANGEME"/' "$HS_MACHINE_FILE"
before=$(cat "$HS_MACHINE_FILE")
run start set syncEveryHours 8
check_eq "a file the check rejects: refused" 1 "$rc"; has "put back" && pass "says it was put back" || fail "put back: $out"
check_eq "and the file is as it was" "$before" "$(cat "$HS_MACHINE_FILE")"

echo "-- config apply (several keys, one plan, one start)"
sed -i 's/^hostId = .*/hostId = "deadbeef"/' "$HS_MACHINE_FILE"
run plan apply --set syncEveryHours=8 --set backupNewShares=true
check_eq "apply plan: exit 0" 0 "$rc"
has "^status${T}ok$" && has "^heading${T}change 2 settings$" && has "^command${T}hs sys config start apply --set syncEveryHours=8 --set backupNewShares=true$" \
  && has "^note${T}.*hs rebuild" && has "^long${T}no$" && pass "apply plan lines" || fail "apply plan: $out"
check_eq "apply plan: one step per key" 2 "$(grep -c "^step${T}" <<<"$out")"
run plan apply --set backupNewShares=true; has "^note${T}.*no rebuild" && pass "settings only: no rebuild note" || fail "apply settings only: $out"
before=$(cat "$HS_MACHINE_FILE")
run plan apply;                                              check_eq "apply: no --set is refused" 1 "$rc"
run plan apply --set syncEveryHours=8 --set syncEveryHours=6; check_eq "apply: a key twice is refused" 1 "$rc"
run plan apply --set syncEveryHours;                         check_eq "apply: a pair without = is refused" 1 "$rc"
run plan apply --set hostName=x --set backupNewShares=true;  check_eq "apply: a key that is not settable is refused" 1 "$rc"
run start apply --set backupNewShares=true --set syncEveryHours=5; check_eq "apply start: a bad value is refused" 1 "$rc"
check_eq "and no setting was written" "no" "$(test -e "$HS_STATE_DIR/settings/backupNewShares" && echo yes || echo no)"
check_eq "and machine.toml is unchanged" "$before" "$(cat "$HS_MACHINE_FILE")"
run start apply --set syncEveryHours=8 --set backupNewShares=true
check_eq "apply start: exit 0" 0 "$rc"; has "^status${T}done$" && pass "apply start: status done" || fail "apply start: $out"
check_eq "apply start: the machine key is in the file" "syncEveryHours = 8" "$(grep '^syncEveryHours' "$HS_MACHINE_FILE")"
check_eq "apply start: the setting is in its file" "true" "$(cat "$HS_STATE_DIR/settings/backupNewShares")"
sed -i 's/^hostId = .*/hostId = "CHANGEME"/' "$HS_MACHINE_FILE"
before=$(cat "$HS_MACHINE_FILE")
run start apply --set syncEveryHours=6 --set language=de
check_eq "apply start: a file the check rejects is refused" 1 "$rc"; has "put back" && pass "apply says it was put back" || fail "apply put back: $out"
check_eq "and machine.toml is as it was" "$before" "$(cat "$HS_MACHINE_FILE")"
check_eq "and the setting was not written" "no" "$(test -e "$HS_STATE_DIR/settings/language" && echo yes || echo no)"
sed -i 's/^hostId = .*/hostId = "deadbeef"/' "$HS_MACHINE_FILE"

echo "-- config sync and migrate (a stand-in for machine-sync.sh)"
cat > "$WORK/sync-stub.sh" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$WORK/sync-calls"
case "\$1" in
  --list) [ -f "$WORK/has-new" ] && printf 'new${T}webDocs${T}the guides in the web interface\n' ;;
  sync|migrate) exit 0 ;;
esac
STUB
chmod +x "$WORK/sync-stub.sh"; export HS_MACHINE_SYNC=$WORK/sync-stub.sh; : > "$WORK/sync-calls"
rm -f "$WORK/has-new"
run plan sync;                  check_eq "sync: nothing new is refused" 1 "$rc"
touch "$WORK/has-new"
run plan sync;                  check_eq "sync plan: exit 0" 0 "$rc"
has "new option webDocs" && pass "the plan lists the new option" || fail "$out"
: > "$WORK/sync-calls"; run start sync; check_eq "sync start: exit 0" 0 "$rc"
check_eq "machine-sync.sh sync was called" "--list
sync" "$(cat "$WORK/sync-calls")"
run plan sync extra;            check_eq "an extra argument is refused" 1 "$rc"
export HS_MACHINE_OLD=$WORK/machine.nix
run plan migrate;               check_eq "migrate: machine.toml exists: refused" 1 "$rc"
cp "$HS_MACHINE_FILE" "$WORK/machine.toml.keep"; rm -f "$HS_MACHINE_FILE"
run plan migrate;               check_eq "migrate: no machine.nix: refused" 1 "$rc"
: > "$HS_MACHINE_OLD"
run plan migrate;               check_eq "migrate plan: exit 0" 0 "$rc"
: > "$WORK/sync-calls"; run start migrate; check_eq "migrate start: exit 0" 0 "$rc"
check_eq "machine-sync.sh migrate was called" "migrate" "$(cat "$WORK/sync-calls")"
cp "$WORK/machine.toml.keep" "$HS_MACHINE_FILE"; unset HS_MACHINE_SYNC HS_MACHINE_OLD

echo "-- network keys (nic, smbAllow, dhcpRange, siteName, incusUi)"
export HS_SYS_NET=$WORK/net HS_HOST_NET=10.10.10.0/24 HS_SITE_NAME_FILE=$WORK/site-name HS_CAPABILITIES_FILE=$WORK/caps
mkdir -p "$HS_SYS_NET/eno1/device" "$HS_SYS_NET/br0"; echo 0 >"$HS_SYS_NET/eno1/carrier"; : >"$HS_CAPABILITIES_FILE"
run plan set nic wlan9;       check_eq "nic: unknown card is refused" 1 "$rc"
run plan set nic br0;         check_eq "nic: a bridge is refused" 1 "$rc"; has "not a physical" && pass "says why" || fail "br0: $out"
run plan set nic "";          check_eq "nic: empty is refused" 1 "$rc"
run plan set nic 'a b';       check_eq "nic: a bad name is refused" 1 "$rc"
run plan set nic eno1;        check_eq "nic: plan ok" 0 "$rc"
has "^danger${T}" && has "^confirm_name${T}eno1$" && has "^warn${T}No cable is connected to eno1" && pass "nic plan: danger, typed name, cable warning" || fail "nic plan: $out"
check_eq "nic plan: danger comes before the command" "yes" "$(awk -F'\t' '$1 == "danger" { d = 1 } $1 == "command" { print (d ? "yes" : "no") }' <<<"$out")"
echo 1 >"$HS_SYS_NET/eno1/carrier"
run plan apply --set nic=eno1; has "^warn${T}No cable" && fail "cable present: no warning" || pass "no cable warning with a carrier"
check_eq "nic apply: one confirm_name" 1 "$(grep -c "^confirm_name${T}" <<<"$out")"
run plan set smbAllow "10.0.0.5/24";   check_eq "smbAllow: host bits are refused" 1 "$rc"
run plan set smbAllow "";              check_eq "smbAllow: empty is refused" 1 "$rc"
run plan set smbAllow "192.168.1.0/24"; check_eq "smbAllow: plan ok" 0 "$rc"
has "^warn${T}.*10.10.10.0/24" && has "^note${T}Only the Samba shares" && pass "smbAllow: own network warning and note" || fail "smbAllow: $out"
run plan set smbAllow "10.10.10.0/24 127.0.0.1"; has "^warn${T}" && fail "smbAllow with the own network warns: $out" || pass "smbAllow with the own network: no warning"
run plan set dhcpRange "199 100";      check_eq "dhcpRange: from above to is refused" 1 "$rc"
run plan set dhcpRange "0 50";         check_eq "dhcpRange: 0 is refused" 1 "$rc"
run plan set dhcpRange "1 255";        check_eq "dhcpRange: 255 is refused" 1 "$rc"
run plan set dhcpRange "5";            check_eq "dhcpRange: one number is refused" 1 "$rc"
run plan set dhcpRange "1 2 3";        check_eq "dhcpRange: three numbers are refused" 1 "$rc"
run start set dhcpRange "[100, 150]";  check_eq "dhcpRange: start ok" 0 "$rc"
check_eq "dhcpRange: written as a TOML list" "dhcpRange = [100, 150]" "$(grep '^dhcpRange' "$HS_MACHINE_FILE")"
run plan set dhcpRange "100-150";      check_eq "dhcpRange: the same range is set already" 1 "$rc"
run plan apply --set "dhcpRange=120-180"; check_eq "dhcpRange: apply plan ok" 0 "$rc"
run start apply --set "dhcpRange=120 180"; check_eq "dhcpRange: apply start ok" 0 "$rc"
check_eq "dhcpRange: apply wrote it" "dhcpRange = [120, 180]" "$(grep '^dhcpRange' "$HS_MACHINE_FILE")"
run plan set dhcpRange "010 150";      check_eq "dhcpRange: leading zeros plan ok" 0 "$rc"
run start set dhcpRange "[08, 150]";   check_eq "dhcpRange: leading zeros start ok" 0 "$rc"
check_eq "dhcpRange: leading zeros are written plain" "dhcpRange = [8, 150]" "$(grep '^dhcpRange' "$HS_MACHINE_FILE")"
run plan set dhcpRange "008-150";      check_eq "dhcpRange: the same range with zeros is set already" 1 "$rc"
run plan set smbAllow "10.10.10.0/24 127.0.0.0/8"; has "^command${T}hs sys config start set smbAllow '10.10.10.0/24 127.0.0.0/8'$" && pass "plan command quotes a value with spaces" || fail "quoting: $out"
run plan apply --set "smbAllow=10.10.10.0/24 127.0.0.0/8"; has "^command${T}.*--set 'smbAllow=10.10.10.0/24 127.0.0.0/8'$" && pass "apply command quotes a value with spaces" || fail "apply quoting: $out"
cp -p "$HS_MACHINE_FILE" "$HS_MACHINE_FILE.nicbak"
run start set nic eno1;                check_eq "nic: start without confirm is refused" 1 "$rc"
check_eq "nic: refused start leaves machine.toml" "" "$(cmp "$HS_MACHINE_FILE" "$HS_MACHINE_FILE.nicbak" 2>&1)"
run start set nic eno1 --confirm eth0; check_eq "nic: wrong confirm is refused" 1 "$rc"
check_eq "nic: wrong confirm leaves machine.toml" "" "$(cmp "$HS_MACHINE_FILE" "$HS_MACHINE_FILE.nicbak" 2>&1)"
run start apply --set nic=eno1;        check_eq "nic apply: start without confirm is refused" 1 "$rc"
run start apply --set nic=eno1 --confirm eno2; check_eq "nic apply: wrong confirm is refused" 1 "$rc"
check_eq "nic apply: refusals leave machine.toml" "" "$(cmp "$HS_MACHINE_FILE" "$HS_MACHINE_FILE.nicbak" 2>&1)"
run plan set nic eno1;                 check_eq "nic: plan needs no confirm" 0 "$rc"
run start set nic eno1 --confirm eno1; check_eq "nic: right confirm works" 0 "$rc"
check_eq "nic: written" "nic = \"eno1\"" "$(grep '^nic' "$HS_MACHINE_FILE")"
cp -p "$HS_MACHINE_FILE.nicbak" "$HS_MACHINE_FILE"
run start apply --set nic=eno1 --confirm eno1; check_eq "nic apply: right confirm works" 0 "$rc"
run start set syncEveryHours 12 --confirm whatever; check_eq "other keys: an extra confirm is harmless" 0 "$rc"
cp -p "$HS_MACHINE_FILE.nicbak" "$HS_MACHINE_FILE"; rm -f "$HS_MACHINE_FILE.nicbak"
run plan set siteName Home;            check_eq "siteName: capital letters are refused" 1 "$rc"
run plan set siteName -x;              check_eq "siteName: a leading hyphen is refused" 1 "$rc"
run plan set siteName lab;             check_eq "siteName: plan ok" 0 "$rc"
has "^warn${T}" && fail "siteName without gateway warns: $out" || pass "siteName: no warning while the gateway is off"
echo gateway >"$HS_CAPABILITIES_FILE"
run plan set siteName lab;             has "^warn${T}.*\*\.lab" && pass "siteName: DNS warning with the gateway on" || fail "siteName gateway: $out"
run plan set incusUi false;            has "^warn${T}Port 8443 closes" && pass "incusUi false: warning" || fail "incusUi: $out"
unset HS_SYS_NET HS_HOST_NET HS_SITE_NAME_FILE HS_CAPABILITIES_FILE

echo "-- registry"
for w in "recipes list" "config list" "config check" "config plan <action>" "config start <action>"; do
  check "row sys $w" grep -q "^sys${T}sys $w${T}" "$SCRIPTS/lib/registry.tsv"
done
finish
