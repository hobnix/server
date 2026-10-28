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
mkdir -p "$WORK"/recipes/{arr,jellyfin,pelican,sunshine,nodesc}
printf '#!/usr/bin/env bash\n# recipe: arr: Radarr and Sonarr\nct=${RECIPE_NAME:-arr}\n' > "$WORK/recipes/arr/run.sh"
printf '#!/usr/bin/env bash\n# recipe: Jellyfin: watch films\nct=${RECIPE_NAME:-jellyfin}\n' > "$WORK/recipes/jellyfin/run.sh"
printf '#!/usr/bin/env bash\n# recipe: Pelican: game servers\n' > "$WORK/recipes/pelican/run.sh"
printf '#!/usr/bin/env bash\n# recipe: Sunshine: games on the TV\nct=${RECIPE_NAME:-sunshine}\n' > "$WORK/recipes/sunshine/run.sh"
printf '#!/usr/bin/env bash\nct=${RECIPE_NAME:-nodesc}\n' > "$WORK/recipes/nodesc/run.sh"
printf '#!/usr/bin/env bash\nprintf "arr\\npelican-panel\\n"\n' > "$WORK/incus"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/incus-down"
chmod +x "$WORK/incus" "$WORK/incus-down"
export HS_RECIPES_DIR=$WORK/recipes HS_INCUS=$WORK/incus
out=$(bash "$SCRIPTS/recipes-list.sh")
check_eq "one row per recipe" 5 "$(wc -l <<<"$out" | tr -d ' ')"
check_eq "the name prefix is cut from the description" "arr${T}Radarr and Sonarr${T}arr${T}installed" "$(grep '^arr' <<<"$out")"
check_eq "a recipe whose container is missing" "jellyfin${T}Watch films${T}jellyfin${T}not installed" "$(grep '^jellyfin' <<<"$out")"
check_eq "a recipe with two instances, one there" "pelican${T}Game servers${T}pelican-panel,pelican-wings${T}partly" "$(grep '^pelican' <<<"$out")"
check_eq "sunshine is parked" "parked" "$(awk -F'\t' '$1 == "sunshine" { print $4 }' <<<"$out")"
check_eq "a fixed text without a header line" "App recipe nodesc (hs recipe nodesc)" "$(awk -F'\t' '$1 == "nodesc" { print $2 }' <<<"$out")"
check_eq "incus not answering: unknown" "unknown" "$(HS_INCUS=$WORK/incus-down bash "$SCRIPTS/recipes-list.sh" | awk -F'\t' '$1 == "arr" { print $4 }')"
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
if grep -q "ssh-ed25519" <<<"$list"; then fail "an SSH key is in the list"; else pass "no SSH key in the list"; fi
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

echo "-- registry"
for w in "recipes list" "config list" "config check" "config plan <action>" "config start <action>"; do
  check "row sys $w" grep -q "^sys${T}sys $w${T}" "$SCRIPTS/lib/registry.tsv"
done
finish
