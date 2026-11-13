#!/usr/bin/env bash
# hs pkg new (scripts/pkg_new.py): both templates write a package that passes pkg.py validate, repo-check, the extension loader and the
# guide rules without edits; the command refuses a bad name, an unknown template, a folder that is no package repository and an
# existing package, and then writes nothing. No root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test HS_STATE_DIR=$WORK/state
mkdir -p "$HS_STATE_DIR"
PKG="python3 -I $SCRIPTS/pkg.py"
NEW="bash $SCRIPTS/pkg.sh new"
tab=$'	'
repo() { mkdir -p "$1/$2"; printf '# The index of this repository\n' > "$1/index.toml"; }

echo "-- the recipe template"
R=$WORK/recipes; repo "$R" recipes
check_out "hs pkg new writes a recipe" "Created run.sh" $NEW demo-app --template recipe --dir "$R" --title "Demo app: an app for the tests"
P=$R/recipes/demo-app
for f in package.toml run.sh guide.md; do check "the recipe has $f" test -s "$P/$f"; done
check "run.sh is executable" test -x "$P/run.sh"
check "run.sh is valid bash" bash -n "$P/run.sh"
T=$WORK/rtree; mkdir -p "$T"; ln -s "$R/recipes" "$T/packages"
check "pkg.py validate passes (as the CI of the recipes repository runs it)" env HS_PACKAGES_ROOT="$T" $PKG validate
check "pkg.py repo-check passes" $PKG repo-check "$R"
check_out "index.toml has the entry" '^\[package\.demo-app\]' cat "$R/index.toml"
check_eq "the title is in the manifest" 'title = "Demo app: an app for the tests"' "$(grep '^title = ' "$P/package.toml")"
check_out "the dry run names the container" "demo-app" env state="$WORK/state" HS_SCRIPTS="$SCRIPTS" bash "$P/run.sh" --dry-run
check_out "the closing text names its guide" 'docs_hint demo-app' cat "$P/run.sh"
check_eq "the guide has one H1" "1" "$(grep -c '^# ' "$P/guide.md")"
check_eq "the guide has no raw HTML" "0" "$(grep -cE '<(p|br|div|span|details|summary|img|a|table|b|i|small|center)[ >/]' "$P/guide.md" || true)"
check_out "the default folder is the current one" "Created run.sh" bash -c "cd '$R' && $NEW demo-two --template recipe"
check "repo-check passes with two new packages" $PKG repo-check "$R"

echo "-- the extension template"
E=$WORK/extensions; repo "$E" extensions
check_out "hs pkg new writes an extension" "Created commands.tsv" $NEW demo-ext --template extension --dir "$E"
X=$E/extensions/demo-ext
for f in package.toml capability.toml commands.tsv list.sh NOTES.md guide.md; do check "the extension has $f" test -s "$X/$f"; done
check "list.sh is executable" test -x "$X/list.sh"
check "list.sh is valid bash" bash -n "$X/list.sh"
T=$WORK/etree; mkdir -p "$T"; ln -s "$E/extensions" "$T/capabilities"
check "pkg.py validate passes (as the CI of the extensions repository runs it)" env HS_PACKAGES_ROOT="$T" $PKG validate
check "pkg.py repo-check passes" $PKG repo-check "$E"
check_eq "the title defaults to the name" 'title = "demo-ext"' "$(grep '^title = ' "$X/package.toml")"
bad=$(python3 -I - "$X" <<'EOF'
import os, sys, tomllib
d = sys.argv[1]
m = tomllib.load(open(os.path.join(d, "capability.toml"), "rb"))
if m.get("name") != os.path.basename(d): print("name")
if not m.get("title") or not m.get("title_de"): print("title")
if m.get("kind") not in ("feature", "provider"): print("kind")
if m.get("extension") is not True: print("extension")
if "notes" in m and not os.path.exists(os.path.join(d, m["notes"])): print("notes")
rows = [l.rstrip("\n").split("\t") for l in open(os.path.join(d, "commands.tsv"), encoding="utf-8") if l.strip() and not l.startswith("#")]
for r in rows:
    if len(r) < 6: print("columns")
paths = {r[1] for r in rows if r[0] == "sys"}
for r in m.get("web", {}).get("reads", []):
    if "sys ext %s %s" % (m["name"], r["words"]) not in paths: print("read " + r["words"])
EOF
)
check_eq "capability.toml follows the rules of tests/capabilities.sh and every web read has a sys row" "" "$bad"
export HS_PACKAGES_DIR=$E/extensions HS_CAPABILITIES_FILE=$WORK/caps HS_MACHINE_FILE=$WORK/machine.toml HS_SETTINGS_DIR=$WORK/settings HS_COMPLETE_DIR=$WORK/complete
printf 'demo-ext\n' > "$HS_CAPABILITIES_FILE"
HS="bash $SCRIPTS/lib/hs.sh"
check "hs help --all lists the command while the extension is on" bash -c "$HS help --all 2>/dev/null | grep -q 'ext demo-ext list'"
check_eq "hs sys ext demo-ext list prints nothing without entries" "" "$($HS sys ext demo-ext list 2>&1)"
mkdir -p "$HS_STATE_DIR/demo-ext"; printf 'one\t1\ntwo\t\n' > "$HS_STATE_DIR/demo-ext/entries"
check_eq "hs sys ext demo-ext list prints the entries, - for an empty value" "one${tab}1 two${tab}-" "$($HS sys ext demo-ext list | paste -sd' ')"
if command -v column >/dev/null 2>&1; then
  check_out "hs ext demo-ext list shows them" "two" $HS ext demo-ext list
else
  skip "hs ext demo-ext list shows them (column is not installed)"
fi

echo "-- refusals"
before="$(cksum < "$P/package.toml") $(cksum < "$R/index.toml")"
check_out "the same name again is refused" "already" $NEW demo-app --template recipe --dir "$R"
check_eq "and nothing changed" "$before" "$(cksum < "$P/package.toml") $(cksum < "$R/index.toml")"
check "and the exit code says so" bash -c "! $NEW demo-app --template recipe --dir '$R' >/dev/null 2>&1"
check_out "a name with capitals is refused" "not allowed" $NEW Demo --template recipe --dir "$R"
check_out "a reserved word is refused" "not allowed" $NEW list --template extension --dir "$E"
check_out "a name ending in a newline is refused" "not allowed" $NEW $'demo\n' --template recipe --title X --dir "$R"
check_out "a title holding a placeholder is written literally" "New package demo-ph" $NEW demo-ph --template recipe --title '{title_de}' --title-de 'x"y' --dir "$R"
check "the manifest of that package is valid TOML" python3 -c "import tomllib,sys;tomllib.load(open(sys.argv[1],'rb'))" "$R/recipes/demo-ph/package.toml"
check_out "the message names the package, not an option" "New package demo-ph2" $NEW --template recipe demo-ph2 --dir "$R"
check_out "the capability template is not there yet" "#238" $NEW demo-cap --template capability --dir "$E"
check_out "a folder that is no package repository is refused" "not a checkout" $NEW demo-x --template recipe --dir "$HS_STATE_DIR"
check_out "a recipe in an extensions checkout is refused" "not a checkout" $NEW demo-x --template recipe --dir "$E"
check_out "a title with a tab is refused" "one line" $NEW demo-y --template recipe --dir "$R" --title "a${tab}b"
check "nothing was written for the refused ones" bash -c "[ ! -e '$R/recipes/Demo' ] && [ ! -e '$E/extensions/list' ] && [ ! -e '$R/recipes/demo-y' ] && [ ! -e '$E/extensions/demo-cap' ] && [ ! -e '$E/recipes' ]"
check_out "without a name it shows the usage" "usage: hs pkg new" $NEW
printf '\n[package.ghost]\nversion = "1.0.0"\nkind = "recipe"\npath = "recipes/ghost"\n' >> "$R/index.toml"
check_out "a name that is only in index.toml is refused" "already" $NEW ghost --template recipe --dir "$R"
check "and no folder is written for it" test ! -e "$R/recipes/ghost"
finish
