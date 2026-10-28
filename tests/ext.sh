#!/usr/bin/env bash
# Extension packages (docs/PLAN-extensions.md): the loader that merges scripts/lib/registry.tsv with capabilities/<name>/commands.tsv of every
# package that is ON (scripts/lib/registry-load.sh), the namespace rule, `hs ext list|enable|disable|<name>`, "off = invisible", the legacy
# rows of the moved commands, and the real packages (games, posters). A throwaway packages folder stands in for capabilities/. No root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test HS_STATE_DIR=$WORK/state HS_CAPABILITIES_FILE=$WORK/caps HS_MACHINE_FILE=$WORK/machine.toml
export HS_COMPLETE_DIR=$WORK/complete HS_SETTINGS_DIR=$WORK/settings
mkdir -p "$HS_STATE_DIR"
: > "$HS_CAPABILITIES_FILE"
printf 'hostName = "t"\n' > "$HS_MACHINE_FILE"
tab=$'\t'
HS="bash $SCRIPTS/lib/hs.sh"
CORE=$SCRIPTS/lib/registry.tsv

# a stand-in packages folder: demo (no Nix module), nixy (has a module.nix), evil (rows outside its namespace), list (a reserved name)
PK=$WORK/packages; mkdir -p "$PK/demo" "$PK/nixy" "$PK/evil" "$PK/list"
manifest() {   # manifest <name> [extra lines]
  printf 'name = "%s"\ntitle = "%s package"\ntitle_de = "%s Paket"\nkind = "feature"\nrequires = []\nprovides = []\nneeds = []\nextension = true\n%s\n' "$1" "$1" "$1" "${2:-}" > "$PK/$1/capability.toml"
}
manifest demo; manifest nixy 'nix = "module.nix"'; manifest evil; manifest list
: > "$PK/nixy/module.nix"
printf '#!/usr/bin/env bash\necho "demo says: $*"\n' > "$PK/demo/hello.sh"
printf '# kind\n# a comment\nuser%sext demo hello%s@/hello.sh%s{rest}%ssay hello%ssag hallo%stopic:system,reads\nsys%ssys ext demo data <x>%s@/hello.sh%sdata {1}%sdata for one thing%s-\n' \
  "$tab" "$tab" "$tab" "$tab" "$tab" "$tab" "$tab" "$tab" "$tab" "$tab" "$tab" > "$PK/demo/commands.tsv"
printf 'user%sext nixy go%sdisk.sh%s-%sgo%sgeh%stopic:system,reads\n' "$tab" "$tab" "$tab" "$tab" "$tab" "$tab" > "$PK/nixy/commands.tsv"
{
  printf 'user%sext evil fine%sdisk.sh%s-%sok%sok%stopic:system,reads\n' "$tab" "$tab" "$tab" "$tab" "$tab" "$tab"
  printf 'user%sdisk takeover%sdisk.sh%s-%sx%sx%stopic:system,reads\n' "$tab" "$tab" "$tab" "$tab" "$tab" "$tab"      # a core word
  printf 'user%sext demo steal%sdisk.sh%s-%sx%sx%stopic:system,reads\n' "$tab" "$tab" "$tab" "$tab" "$tab" "$tab"      # another package
  printf 'user%sext evil%sdisk.sh%s-%sx%sx%stopic:system,reads\n' "$tab" "$tab" "$tab" "$tab" "$tab" "$tab"            # the bare name lists the package
  printf 'sys%ssys disk list%sdisk.sh%s-%sx%s-\n' "$tab" "$tab" "$tab" "$tab" "$tab"                                    # a core sys word
  printf 'sys%ssys ext demo steal%sdisk.sh%s-%sx%s-\n' "$tab" "$tab" "$tab" "$tab" "$tab"
  printf 'user%sext evil up%s../disk.sh%s-%sx%sx%stopic:system,reads\n' "$tab" "$tab" "$tab" "$tab" "$tab" "$tab"      # leaves scripts/
  printf 'user%sext evil abs%s/bin/sh%s-%sx%sx%stopic:system,reads\n' "$tab" "$tab" "$tab" "$tab" "$tab" "$tab"
  printf 'user%sext evil old%sdisk.sh%s-%sx%sx%stopic:system,reads,legacy:ext evil fine\n' "$tab" "$tab" "$tab" "$tab" "$tab" "$tab"
  printf 'user%sext evil fine%sdisk.sh%s-%sagain%sagain%stopic:system,reads\n' "$tab" "$tab" "$tab" "$tab" "$tab" "$tab"   # twice
} > "$PK/evil/commands.tsv"
printf 'user%sext list x%sdisk.sh%s-%sx%sx%stopic:system,reads\n' "$tab" "$tab" "$tab" "$tab" "$tab" "$tab" > "$PK/list/commands.tsv"
export HS_PACKAGES_DIR=$PK
. "$SCRIPTS/lib/registry-load.sh"

echo "-- the loader merges the core with the packages that are on"
check_eq "all packages are found" "demo evil list nixy" "$(ext_package_names | paste -sd' ')"
check_eq "everything off: only the core rows" "$(grep -av '^#' "$CORE" | wc -l | tr -d ' ')" "$(registry_rows | wc -l | tr -d ' ')"
if registry_rows | grep -q "ext demo hello"; then fail "a package that is off adds no row"; else pass "a package that is off adds no row"; fi
echo demo > "$HS_CAPABILITIES_FILE"
check_out "a package that is on adds its rows" "^user${tab}ext demo hello${tab}$PK/demo/hello.sh${tab}" registry_rows
check_out "and its sys rows" "^sys${tab}sys ext demo data <x>${tab}" registry_rows
check_eq "a row is not added twice" "1" "$(registry_rows | grep -c "^user${tab}ext demo hello${tab}")"
check_out "@/file becomes the file in the package folder" "$PK/demo/hello.sh" registry_rows_of demo
check_eq "comments are not rows" "0" "$(registry_rows | grep -c '^#')"

echo "-- the namespace rule"
printf 'evil\n' >> "$HS_CAPABILITIES_FILE"
rows=$(registry_rows)
check_out "the row of its own name is loaded" "^user${tab}ext evil fine${tab}" echo "$rows"
for w in "disk takeover" "ext demo steal" "sys disk list" "sys ext demo steal" "ext evil up" "ext evil abs" "ext evil old"; do
  if grep -q "${tab}$w${tab}" <<<"$rows"; then fail "refused: $w"; else pass "refused: $w"; fi
done
check_eq "the bare name is no row" "0" "$(grep -c "^user${tab}ext evil${tab}" <<<"$rows")"
check_eq "a second row for the same words is refused" "1" "$(grep -c "^user${tab}ext evil fine${tab}" <<<"$rows")"
ref=$(registry_refused evil)
check_out "the refusal names the package, the line and why" "^evil${tab}[0-9]+${tab}disk takeover${tab}a user row must be: ext evil" echo "$ref"
check_eq "nine rows of evil are refused" "9" "$(grep -c . <<<"$ref")"
printf 'list\n' >> "$HS_CAPABILITIES_FILE"
check_out "a reserved name is refused" "the name list is reserved" registry_refused list
if registry_rows | grep -q "ext list x"; then fail "reserved name loads nothing"; else pass "reserved name loads nothing"; fi
check_eq "the core is untouched" "$(grep -av '^#' "$CORE" | wc -l | tr -d ' ')" "$(registry_rows | grep -v "ext demo\|ext evil" | wc -l | tr -d ' ')"
: > "$HS_CAPABILITIES_FILE"

echo "-- off = invisible"
check_eq "hs help hides the package" "0" "$($HS help | grep -c 'ext demo')"
check_eq "hs help --all hides it too" "0" "$($HS help --all | grep -c 'ext demo')"
check_eq "completion offers the package name" "yes" "$($HS sys complete ext | grep -qx demo && echo yes)"
check_eq "but not its commands" "" "$($HS sys complete ext demo)"
out=$($HS ext demo hello 2>&1; echo "rc=$?")
check_out "running it says it is off and how to switch it on" "extension 'demo' is off" echo "$out"
check_out "with the command to run" "hs ext enable demo" echo "$out"
check_out "and exits 1" "rc=1" echo "$out"
out=$($HS ext demo 2>&1; echo "rc=$?")
check_out "hs ext demo lists the commands even while it is off" "ext demo hello" echo "$out"
check_out "marked as off" "off" echo "$out"
check_eq "sys rows are not reachable either" "1" "$($HS sys ext demo data x >/dev/null 2>&1; echo $?)"

echo "-- on: dispatch, help, completion"
echo demo > "$HS_CAPABILITIES_FILE"
check_eq "hs ext demo hello runs the script of the package" "demo says: world" "$($HS ext demo hello world)"
check_eq "a sys row too, with its value" "demo says: data thing" "$($HS sys ext demo data thing)"
check_out "hs help lists it" "ext demo hello" $HS help
check_out "with the help text" "say hello" $HS help
check_out "hs help --all lists the sys row" "sys ext demo data <x>" $HS help --all
check_out "hs help <words> explains it" "say hello" $HS help ext demo hello
check_eq "completion offers the commands" "hello" "$($HS sys complete ext demo)"
check_out "hs sys registry shows the rows" "ext demo hello" $HS sys registry
check_eq "an unknown word of a package is named" "1" "$($HS ext demo nothing >/dev/null 2>&1; echo $?)"
check_out "and the commands are listed" "ext demo hello" $HS ext demo nothing

echo "-- hs ext list / enable / disable"
: > "$HS_CAPABILITIES_FILE"
check_out "list shows the state" "demo +off" $HS ext list
check_eq "the data form" "$(printf 'demo\toff\t1\tno\tdemo package')" "$($HS sys ext list | grep '^demo')"
check_eq "a package with a Nix module says so" "$(printf 'nixy\toff\t1\tyes\tnixy package')" "$($HS sys ext list | grep '^nixy')"
out=$($HS ext enable demo 2>&1)
check_out "enable says it is on" "Extension 'demo' is on" echo "$out"
check_out "machine.toml has it" 'capabilities = \["demo"\]' cat "$HS_MACHINE_FILE"
check_out "it is on at once, without a rebuild" "ext demo hello" $HS help
check_eq "and the command runs" "demo says: x" "$($HS ext demo hello x)"
check "capability_on agrees" bash -c ". '$SCRIPTS/lib/capability.sh'; capability_on demo"
check_out "list shows it on" "demo +on" $HS ext list
check_out "enable again is a note" "on already" $HS ext enable demo
out=$($HS ext enable nixy 2>&1)
check_out "a package with a Nix module needs a rebuild" "hs rebuild" echo "$out"
check_out "machine.toml has both" 'capabilities = \["demo", "nixy"\]' cat "$HS_MACHINE_FILE"
check_eq "the module package is not on until then" "off" "$($HS sys ext list | awk -F'\t' '$1 == "nixy" { print $2 }')"
out=$($HS ext disable demo 2>&1)
check_out "disable says it is off" "Extension 'demo' is off" echo "$out"
check_out "machine.toml lost it" 'capabilities = \["nixy"\]' cat "$HS_MACHINE_FILE"
check_eq "its commands are gone at once" "0" "$($HS help | grep -c 'ext demo')"
check_eq "even when the file Nix wrote still names it" "off" "$(echo demo > "$HS_CAPABILITIES_FILE"; $HS sys ext list | awk -F'\t' '$1 == "demo" { print $2 }')"
$HS ext enable demo >/dev/null 2>&1
check_eq "enable takes the overlay back" "on" "$($HS sys ext list | awk -F'\t' '$1 == "demo" { print $2 }')"
check_out "an unknown package is refused" "No extension called 'nope'" $HS ext enable nope
check_eq "with exit 1" "1" "$($HS ext enable nope >/dev/null 2>&1; echo $?)"
check_eq "a name with a slash is refused" "1" "$($HS ext enable ../demo >/dev/null 2>&1; echo $?)"
rm -f "$HS_STATE_DIR"/capabilities-on "$HS_STATE_DIR"/capabilities-off; : > "$HS_CAPABILITIES_FILE"

echo "-- the real packages (games, posters), their old words, the web declarations"
unset HS_PACKAGES_DIR
check_eq "games and posters are packages" "yes" "$(ext_package_names | paste -sd' ' | grep -q 'games' && ext_package_names | grep -qx posters && echo yes)"
check_eq "both are off by default" "0" "$($HS help --all | grep -cE 'ext (games|posters)')"
printf 'games
posters
gateway
passthrough
' > "$HS_CAPABILITIES_FILE"
for w in "ext passthrough list" "ext passthrough status" "ext passthrough add" "ext passthrough remove" "ext passthrough refresh" "sys ext passthrough state" "sys ext passthrough plan <domain> <action>" "sys ext passthrough start <domain> <action>"; do
  check_out "row: $w" "${tab}$w${tab}" registry_rows
done
for w in "ext games list" "ext games add" "ext games remove" "ext games wake" "ext posters generate" "sys ext games list" "sys ext games state" "sys ext games plan <name> <action>" "sys ext games start <name> <action>" \
         "sys ext posters generate" "sys ext posters list" "sys ext posters plan <action>" "sys ext posters start <action>"; do
  check_out "row: $w" "${tab}$w${tab}" registry_rows
done
check_eq "no row of the real packages is refused" "" "$(registry_refused | paste -sd, -)"
check_eq "hs ext games list runs pc.sh" "yes" "$($HS ext games list 2>&1 | grep -q 'No PC saved yet' && echo yes)"
check_eq "hs sys ext games list is plain and empty without a PC" "" "$($HS sys ext games list)"
$HS ext games add gaming AA:BB:CC:DD:EE:FF 10.10.95.30 >/dev/null 2>&1
check_eq "hs sys ext games list prints the row" "$(printf 'gaming\taa:bb:cc:dd:ee:ff\t10.10.95.30')" "$($HS sys ext games list)"
err=$($HS pc list 2>&1 >/dev/null)
check_out "the old word says where it went" "'hs pc list' has moved to the extension games: hs ext games list" echo "$err"
check_eq "and still runs while the package is on" "$(printf 'gaming\taa:bb:cc:dd:ee:ff\t10.10.95.30')" "$($HS sys ext games list)"
check_eq "the old word is not in hs help" "0" "$($HS help --all | grep -cE '^  (pc |generate poster)')"
: > "$HS_CAPABILITIES_FILE"
check_eq "passthrough rows vanish while it is off" "0" "$($HS help --all | grep -c 'ext passthrough')"
out=$($HS pc list 2>&1; echo "rc=$?")
check_out "off: the old word names the new form and the switch" "hs ext enable games" echo "$out"
check_out "and exits 1" "rc=1" echo "$out"
out=$($HS generate poster 2>&1; echo "rc=$?")
check_out "the old poster word moved too" "has moved to the extension posters: hs ext posters generate" echo "$out"

echo "-- web allowlists come from the manifests of the packages that are on"
if have python3; then
  if out=$(python3 -I "$ROOT/tests/web-ext-test.py" 2>&1); then pass "web declarations ($(grep -E '^Ran ' <<<"$out"))"; else fail "web declarations: $(tail -n 25 <<<"$out")"; fi
else skip "python3 missing"; fi

finish
