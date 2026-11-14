#!/usr/bin/env bash
# hs pkg remove: uninstall of an installed package: dry run, refusal while it is on or another package that is on needs it, the typed name,
# clean-up of the on/off marks, and that nothing but the package's own state goes. No git needed: installed packages are plain folders.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_STATE_DIR=$WORK/state HS_CAPABILITIES_FILE=$WORK/caps HS_PACKAGES_ROOT=$WORK/root
mkdir -p "$HS_STATE_DIR/packages/current" "$WORK/root"
: > "$WORK/caps"
PKGSH="bash $SCRIPTS/pkg.sh"
mk() {   # mk <name> <kind> [requires]
  mkdir -p "$HS_STATE_DIR/packages/current/$1"
  printf 'name = "%s"\nversion = "1.0.0"\nkind = "%s"\ntitle = "T"\nrequires_core = ">=1"\n' "$1" "$2" > "$HS_STATE_DIR/packages/current/$1/package.toml"
  [ -z "${3:-}" ] || printf 'requires = ["%s"]\n' "$3" >> "$HS_STATE_DIR/packages/current/$1/package.toml"
  printf '[package.%s]\nversion = "1.0.0"\nrepo = "test"\n\n' "$1" >> "$HS_STATE_DIR/packages/installed.toml"
}
mk base extension
mk top extension base
mk app recipe
mkdir -p "$HS_STATE_DIR/pkg-events"; printf 'x\n' > "$HS_STATE_DIR/pkg-events/base.tsv"

echo "-- what is refused"
check_out "not installed from a repository" "was not installed" bash -c "$PKGSH remove nope 2>&1; true"
check_out "a bad name" "usage" bash -c "$PKGSH remove 'B@D' 2>&1; true"
printf 'base\n' > "$HS_STATE_DIR/capabilities-on"
check_out "refused while it is on" "switched on" bash -c "$PKGSH remove base --yes 2>&1; true"
check "and nothing was removed" test -d "$HS_STATE_DIR/packages/current/base"
printf 'base\ntop\n' > "$HS_STATE_DIR/capabilities-on"
printf 'base\n' > "$HS_STATE_DIR/capabilities-off"
check_out "refused while a package that is on needs it" "top" bash -c "$PKGSH remove base --yes 2>&1; true"
rm "$HS_STATE_DIR/capabilities-off"

echo "-- dry run and confirmation"
printf 'other\n' > "$HS_STATE_DIR/capabilities-on"
printf 'base\ntop\n' > "$HS_STATE_DIR/capabilities-off"
check_out "dry run says what goes" "Removed:" $PKGSH remove base --dry-run
check_out "and what stays" "Stays:" $PKGSH remove base --dry-run
check "the dry run changed nothing" test -d "$HS_STATE_DIR/packages/current/base"
check_out "without a terminal it needs --yes or the name" "needs a person" bash -c "$PKGSH remove base </dev/null 2>&1; true"
check_out "a wrong name is refused" "does not match" bash -c "$PKGSH remove base --confirm-name nope 2>&1; true"
check "still there" test -d "$HS_STATE_DIR/packages/current/base"

echo "-- removing"
check "a package that is off and not needed goes with the name" $PKGSH remove base --confirm-name base
check "the copy is gone" test ! -e "$HS_STATE_DIR/packages/current/base"
check "its event declaration is gone" test ! -e "$HS_STATE_DIR/pkg-events/base.tsv"
check "its off mark is gone" bash -c "! grep -qx base '$HS_STATE_DIR/capabilities-off'"
check "installed.toml has no row for it" bash -c "! grep -q 'package.base' '$HS_STATE_DIR/packages/installed.toml'"
check "others stay" grep -q 'package.top' "$HS_STATE_DIR/packages/installed.toml"
check "another package's on mark stays" grep -qx other "$HS_STATE_DIR/capabilities-on"
echo "-- the generated overlay"
mkdir -p "$HS_STATE_DIR/generated"
mk gone extension
printf 'name = "gone"\nversion = "1.0.0"\ntitle = "Gone"\n' > "$HS_STATE_DIR/packages/current/gone/capability.toml"
python3 "$SCRIPTS/schema-gen.py" overlay write --packages "$HS_STATE_DIR/packages/current" --out "$HS_STATE_DIR/generated" >/dev/null
check "the overlay lists the package" grep -q '^gone	' "$HS_STATE_DIR/generated/capabilities.tsv"
check "removing it" $PKGSH remove gone --yes
check "the overlay row is gone" bash -c "! grep -q '^gone	' '$HS_STATE_DIR/generated/capabilities.tsv'"
rm -rf "$HS_STATE_DIR/generated"
mk gone2 extension
check "no overlay is created where there was none" bash -c "$PKGSH remove gone2 --yes && test ! -e '$HS_STATE_DIR/generated'"
check "a recipe is removed with --yes" $PKGSH remove app --yes
check "and its folder is gone" test ! -e "$HS_STATE_DIR/packages/current/app"
finish
