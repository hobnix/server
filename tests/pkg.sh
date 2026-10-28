#!/usr/bin/env bash
# Packages (docs/PLAN-packages.md, step 1): every recipe and extension of the repository has a valid package.toml that agrees with its
# header lines, the validator catches what it should, `hs pkg list|updates`, and a recipe run remembers the version it applied. No root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_STATE_DIR=$WORK/state
mkdir -p "$HS_STATE_DIR"
PKG="python3 -I $SCRIPTS/pkg.py"
tab=$'\t'

echo "-- the repository"
check "every manifest is valid" $PKG validate
n_recipes=$(ls "$ROOT"/packages/*/run.sh | wc -l)
check_eq "every recipe has a manifest" "$n_recipes" "$(ls "$ROOT"/packages/*/package.toml | wc -l)"
check_eq "games and posters are extension packages" "2" "$($PKG list --all --kind extension | wc -l)"
check_out "list shows arr with a version" "^arr${tab}recipe${tab}1[.]0[.]0" $PKG list
check_eq "a personal recipe is hidden without --all" "0" "$($PKG list | grep -c "^zoraxy${tab}")"
check_eq "and shown with it" "1" "$($PKG list --all | grep -c "^zoraxy${tab}")"
check_eq "the API level is a number" "1" "$($PKG api | grep -cE '^[1-9][0-9]*$')"

echo "-- the converter (header lines to manifest)"
check_out "convert reads kind, needs and an ask" 'key = "' bash -c "$PKG convert $ROOT/packages/catalyst-node/run.sh"
check_out "convert gives the audience" 'audience = "personal"' bash -c "$PKG convert $ROOT/packages/pelican/run.sh"

echo "-- the validator on a broken tree"
BAD=$WORK/tree; mkdir -p "$BAD/packages/demo" "$BAD/packages/other" "$BAD/scripts"
printf '#!/usr/bin/env bash\n# recipe: demo: a demo\n# kind: generic\n# needs: docker\n# uses: -\n' > "$BAD/scripts/demo.sh"
mkdir -p "$BAD/scripts/recipes"; mv "$BAD/scripts/demo.sh" "$BAD/scripts/recipes/demo.sh"
good='name = "demo"\nversion = "1.0.0"\nkind = "recipe"\ntitle = "d"\nrequires_core = ">=1"\nneeds = ["docker"]\nscript = "scripts/recipes/demo.sh"\n'
run() { HS_PACKAGES_ROOT=$BAD $PKG validate; }
printf "$good" > "$BAD/packages/demo/package.toml"; rm -rf "$BAD/packages/other"
check "a good manifest passes" run
printf "${good/1.0.0/1.0}" > "$BAD/packages/demo/package.toml"
check_out "a version that is not semver is named" "semver" bash -c "HS_PACKAGES_ROOT=$BAD $PKG validate; true"
printf "${good/>=1/>=99}" > "$BAD/packages/demo/package.toml"
check_out "a package that needs a newer core is named" "above the API level" bash -c "HS_PACKAGES_ROOT=$BAD $PKG validate; true"
printf "${good/docker/share}" > "$BAD/packages/demo/package.toml"
check_out "needs that differ from the header are named" "differ from the script" bash -c "HS_PACKAGES_ROOT=$BAD $PKG validate; true"
printf "${good/demo/Demo}" > "$BAD/packages/demo/package.toml"
check_out "a name that differs from the folder is named" "differs from the folder" bash -c "HS_PACKAGES_ROOT=$BAD $PKG validate; true"

echo "-- applied versions and updates"
check_eq "nothing is applied yet, no update" "" "$($PKG updates)"
$PKG record arr
check_out "record writes the version" 'version = "1.0.0"' cat "$HS_STATE_DIR/packages/installed.toml"
check_eq "up to date after record" "" "$($PKG updates)"
printf '[package.arr]\nversion = "0.9.0"\n' > "$HS_STATE_DIR/packages/installed.toml"
check_out "an older applied version shows as an update" "^arr${tab}0[.]9[.]0${tab}1[.]0[.]0" $PKG updates
check "an unknown package cannot be recorded" bash -c "! $PKG record nope 2>/dev/null"

echo "-- hs pkg"
check_out "hs pkg validate says ok" "valid" bash "$SCRIPTS/pkg.sh" validate
check_out "hs sys pkg list has a row per package" "^games${tab}extension" bash "$SCRIPTS/pkg.sh" --list

echo "-- a recipe package with commands (arr)"
export HS_CAPABILITIES_FILE=$WORK/caps; : > "$HS_CAPABILITIES_FILE"
HS="bash $SCRIPTS/lib/hs.sh"
rm -f "$HS_STATE_DIR/packages/installed.toml"
check_eq "before the recipe is applied its commands do not exist" "0" "$($HS help --all 2>/dev/null | grep -c 'ext arr status')"
check_out "hs ext arr names the recipe and says to apply it" "hs recipe arr" $HS ext arr
check_eq "hs ext list shows extensions only" "0" "$($HS ext list 2>/dev/null | grep -c '^arr')"
check_out "hs ext enable refuses a recipe" "is a recipe" bash -c "$HS ext enable arr 2>&1; true"
$PKG record arr
check "after the recipe was applied the command is there" bash -c "$HS help --all 2>/dev/null | grep -q 'ext arr status'"
check_out "hs sys ext arr status prints nothing without incus/container" "^$" bash -c "PATH=/nonexistent:\$PATH $HS sys ext arr status 2>/dev/null; echo"
finish
