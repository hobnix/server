#!/usr/bin/env bash
# Package repositories (docs/PLAN-packages.md): signed release tags, the verified tag only, install as a read-only copy, update with a diff,
# refusals (unsigned tag, wrong key, name clash, API level, path tricks). A local git repository with SSH-signed tags stands in for GitHub.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
have git || { skip "needs git"; finish; exit 0; }
have ssh-keygen || { skip "needs ssh-keygen"; finish; exit 0; }
export HS_LANG=en HS_PLAIN=1 HS_STATE_DIR=$WORK/state
mkdir -p "$HS_STATE_DIR"
PKG="python3 -I $SCRIPTS/pkg.py"
tab=$'\t'
ssh-keygen -q -t ed25519 -N '' -f "$WORK/good" -C test >/dev/null
ssh-keygen -q -t ed25519 -N '' -f "$WORK/evil" -C test >/dev/null
printf 'releaser@test namespaces="git" %s\n' "$(cut -d' ' -f1,2 "$WORK/good.pub")" > "$WORK/signers"
R=$WORK/repo; mkdir -p "$R/recipes/demo"; cd "$R"
git init -q . && git config user.email t@t && git config user.name t && git config gpg.format ssh && git config commit.gpgsign false
release() {   # release <tag> <version> <key> [requires_core] [path]: package.toml + index.toml at that version, committed and tagged (signed with <key>, "none" = unsigned)
  local rc=${4:->=1} path=${5:-recipes/demo}
  mkdir -p "$R/recipes/demo"
  printf 'name = "demo"\nversion = "%s"\nkind = "recipe"\ntitle = "Demo"\nrequires_core = "%s"\naudience = "generic"\nneeds = []\nuses = []\ninput = "none"\nscript = "run.sh"\n' "$2" "$rc" > "$R/recipes/demo/package.toml"
  printf '#!/usr/bin/env bash\n# kind: generic\n# needs: -\n# uses: -\necho demo %s\n' "$2" > "$R/recipes/demo/run.sh"
  printf '[package.demo]\nversion = "%s"\nkind = "recipe"\npath = "%s"\nrequires_core = "%s"\n' "$2" "$path" "$rc" > "$R/index.toml"
  git add -A && git commit -q -m "demo $2"
  if [ "$3" = none ]; then git tag -a "$1" -m "unsigned $2"; else git -c user.signingkey="$3.pub" tag -s "$1" -m "release $2"; fi
}
release v1.0.0 1.0.0 "$WORK/good"
cd "$ROOT"

echo "-- the default repositories are found from the Nix store copy of the scripts"
# on a server the scripts run from /nix/store (no config/); the checkout in /etc/nixos has the list
mkdir -p "$WORK/store" "$WORK/nixos/config"
cp -r "$SCRIPTS" "$WORK/store/scripts"
cp "$ROOT/config/package-repos.toml" "$WORK/nixos/config/"
check_out "the list comes from the checkout, not the store copy" "^recipes${tab}.*${tab}default" env HS_NIXOS_DIR="$WORK/nixos" python3 -I "$WORK/store/scripts/pkg.py" repo list
check_out "with no checkout either there is no default" "^$" bash -c "HS_NIXOS_DIR=$WORK/none python3 -I $WORK/store/scripts/pkg.py repo list; echo"

echo "-- adding a repository"
check "an unsigned repository is refused without --unsigned" bash -c "! $PKG repo add test '$R' 2>/dev/null"
check "a bad key file is refused" bash -c "echo nonsense > $WORK/bad.signers; ! $PKG repo add test '$R' --key $WORK/bad.signers 2>/dev/null"
check "a repository is added with a key" $PKG repo add test "$R" --key "$WORK/signers"
check "the same name twice is refused" bash -c "! $PKG repo add test '$R' --key $WORK/signers 2>/dev/null"
check "a default name cannot be taken" bash -c "! $PKG repo add recipes '$R' --key $WORK/signers 2>/dev/null"
check_out "repo list shows it as added and signed" "^test${tab}.*${tab}signed${tab}added" $PKG repo list
check_out "and the two defaults" "^extensions${tab}.*${tab}default" $PKG repo list
check_out "hs pkg repo add needs a typed name without a terminal" "terminal" bash -c "bash $SCRIPTS/pkg.sh repo add other '$R' --key $WORK/signers </dev/null 2>&1; true"
check "--confirm-name with the right name adds" bash "$SCRIPTS/pkg.sh" repo add other "$R" --key "$WORK/signers" --confirm-name other
check "--confirm-name with the wrong name does not" bash -c "! bash $SCRIPTS/pkg.sh repo add third '$R' --key $WORK/signers --confirm-name nope >/dev/null 2>&1"
$PKG repo remove other

echo "-- fetch and install"
check_out "fetch finds the signed release" "^test${tab}v1[.]0[.]0" $PKG fetch test
check_out "available lists the package" "^test${tab}demo${tab}recipe${tab}1[.]0[.]0${tab}-" $PKG available
check_out "install says where it came from" "demo 1[.]0[.]0 from test" $PKG install demo
check "the package is in current/" test -f "$HS_STATE_DIR/packages/current/demo/package.toml"
check "and read-only" bash -c "! [ -w '$HS_STATE_DIR/packages/current/demo/run.sh' ] || [ \"\$(id -u)\" = 0 ] || [[ \$(uname) == MINGW* ]]"
check_out "installed.toml names repo, commit and tag" 'tag = "v1.0.0"' cat "$HS_STATE_DIR/packages/installed.toml"
check_out "hs pkg list shows it" "^demo${tab}recipe${tab}1[.]0[.]0" $PKG list
check "the manifest validates (script inside the package)" $PKG validate
check_out "a second install of the same name is refused as built-in clash only for built-ins" "demo" $PKG install demo

echo "-- what is never used"
cd "$R"
release v1.1.0 1.1.0 "$WORK/evil"          # signed with a key that is not trusted
release v1.2.0 1.2.0 none                  # not signed at all
cd "$ROOT"
check_out "fetch still picks the newest VERIFIED tag" "^test${tab}v1[.]0[.]0" $PKG fetch test
check_eq "so there is no update" "" "$($PKG updates)"

echo "-- update with a diff"
cd "$R"; release v1.3.0 1.3.0 "$WORK/good"; cd "$ROOT"
check_out "the new release is found" "^test${tab}v1[.]3[.]0" $PKG fetch test
check_out "updates names it" "^demo${tab}1[.]0[.]0${tab}1[.]3[.]0" $PKG updates
check_out "update without --yes and without a terminal shows the diff and refuses" "demo 1.3.0" bash -c "$PKG update demo </dev/null 2>&1; true"
check_out "the installed version is still 1.0.0" '"1[.]0[.]0"' cat "$HS_STATE_DIR/packages/installed.toml"
# installed.toml as the old `hs recipe` record left it: the version only
cp "$HS_STATE_DIR/packages/installed.toml" "$WORK/installed.kept"
sed -i '/^repo = /d;/^commit = /d;/^tag = /d' "$HS_STATE_DIR/packages/installed.toml"
check_out "an entry that lost its repo still shows the update diff" "demo 1.3.0" bash -c "$PKG update demo </dev/null 2>&1; true"
check_out "update --yes installs" "demo 1[.]3[.]0 from test" $PKG update demo --yes
check "the one before is kept" bash -c "ls '$HS_STATE_DIR/packages/previous' | grep -q '^demo@'"
check_out "a current package says so" "current" $PKG update demo --yes

echo "-- refusals"
cd "$R"
release v1.4.0 1.4.0 "$WORK/good" ">=99"; cd "$ROOT"; $PKG fetch test >/dev/null
check_out "a package that needs a newer core is refused" "API level" bash -c "$PKG update demo --yes 2>&1; true"
cd "$R"; release v1.5.0 1.5.0 "$WORK/good" ">=1" "../escape"; cd "$ROOT"; $PKG fetch test >/dev/null
check_out "a path that leaves the repository is refused" "not allowed" bash -c "$PKG update demo --yes 2>&1; true"
cd "$R"; git rm -q -r recipes; mkdir -p recipes/fixapp; cd "$ROOT"
cd "$R"
printf 'name = "fixapp"\nversion = "9.0.0"\nkind = "recipe"\ntitle = "Evil fixapp"\nrequires_core = ">=1"\nscript = "run.sh"\n' > recipes/fixapp/package.toml; echo 'echo evil' > recipes/fixapp/run.sh
printf '[package.fixapp]\nversion = "9.0.0"\nkind = "recipe"\npath = "recipes/fixapp"\nrequires_core = ">=1"\n' > index.toml
git add -A && git commit -q -m fixapp && git -c user.signingkey="$WORK/good.pub" tag -s v2.0.0 -m clash; cd "$ROOT"
export HS_PACKAGES_ROOT=$ROOT/tests/fixtures/pkgtree   # a package of this installation: the fixture recipe
$PKG fetch test >/dev/null
check_out "a name that is built in cannot be replaced by a repository" "installation already" bash -c "$PKG install fixapp 2>&1; true"
echo "-- the packages the core refers to (install --core)"
unset HS_PACKAGES_ROOT
cd "$R"; git rm -q -r -f recipes; mkdir -p recipes/corer recipes/opt
for n in corer opt; do
  printf 'name = "%s"
version = "1.0.0"
kind = "recipe"
title = "%s"
requires_core = ">=1"
audience = "generic"
needs = []
uses = []
input = "none"
script = "run.sh"
' "$n" "$n" > "recipes/$n/package.toml"
  printf '#!/usr/bin/env bash
# kind: generic
# needs: -
# uses: -
echo %s
' "$n" > "recipes/$n/run.sh"
done
printf '[package.corer]
version = "1.0.0"
kind = "recipe"
path = "recipes/corer"
requires_core = ">=1"
core = true

[package.opt]
version = "1.0.0"
kind = "recipe"
path = "recipes/opt"
requires_core = ">=1"
' > index.toml
git add -A && git commit -q -m core && git -c user.signingkey="$WORK/good.pub" tag -s v3.0.0 -m core; cd "$ROOT"
check_out "install --core fetches the core package" "^corer 1[.]0[.]0 from test" $PKG install --core
check "and its run.sh arrived" test -f "$HS_STATE_DIR/packages/current/corer/run.sh"
check "a package that is not core is left alone" test ! -e "$HS_STATE_DIR/packages/current/opt"
check_eq "a second run has nothing to do" "" "$($PKG install --core)"
# an app applied before packages came from a repository: installed.toml has its version, but there is no folder
printf '[package.opt]
version = "1.0.0"
' >> "$HS_STATE_DIR/packages/installed.toml"
check_out "an applied package without a folder is fetched too" "^opt 1[.]0[.]0 from test" $PKG install --core
check "and its run.sh arrived" test -f "$HS_STATE_DIR/packages/current/opt/run.sh"
check "a repository package can be removed" $PKG remove demo
check "and its folder is gone" test ! -e "$HS_STATE_DIR/packages/current/demo"
check "remove refuses a built-in" bash -c "! $PKG remove fixapp 2>/dev/null"
check "a repository can be removed" $PKG repo remove test
finish
