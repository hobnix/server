#!/usr/bin/env bash
# hs sys pkg plan|start (scripts/pkg-change.sh, the Marketplace of the web interface): the data rows (market, repos), install / update / remove,
# adding and removing a repository with its key on stdin, the typed names, the refusals. A local git repository with SSH-signed tags stands in for GitHub.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
have git || { skip "needs git"; finish; exit 0; }
have ssh-keygen || { skip "needs ssh-keygen"; finish; exit 0; }
export HS_LANG=en HS_PLAIN=1 HS_STATE_DIR=$WORK/state HS_PKG_ALLOW_LOCAL=1
mkdir -p "$HS_STATE_DIR"
tab=$'\t'
C="bash $SCRIPTS/pkg-change.sh"
PKGSH="bash $SCRIPTS/pkg.sh"
ssh-keygen -q -t ed25519 -N '' -f "$WORK/good" -C test >/dev/null
ssh-keygen -q -t ed25519 -N '' -f "$WORK/evil" -C test >/dev/null
GOOD=$(cut -d' ' -f1,2 "$WORK/good.pub"); EVIL=$(cut -d' ' -f1,2 "$WORK/evil.pub")
R=$WORK/repo; mkdir -p "$R/recipes/demo" "$R/recipes/corer"; cd "$R"
git init -q . && git config user.email t@t && git config user.name t && git config gpg.format ssh && git config commit.gpgsign false
release() {   # release <tag> <demo version> <key>
  for n in demo corer; do
    v=1.0.0; [ "$n" != demo ] || v=$2
    printf 'name = "%s"\nversion = "%s"\nkind = "recipe"\ntitle = "The %s package"\nrequires_core = ">=1"\naudience = "generic"\nneeds = []\nuses = []\ninput = "none"\nscript = "run.sh"\n' "$n" "$v" "$n" > "$R/recipes/$n/package.toml"
    printf '#!/usr/bin/env bash\n# kind: generic\n# needs: -\n# uses: -\necho %s %s\n' "$n" "$v" > "$R/recipes/$n/run.sh"
  done
  printf '[package.demo]\nversion = "%s"\nkind = "recipe"\npath = "recipes/demo"\ntitle = "The demo package"\nrequires_core = ">=1"\n\n[package.corer]\nversion = "1.0.0"\nkind = "recipe"\npath = "recipes/corer"\ntitle = "The corer package"\nrequires_core = ">=1"\ncore = true\n' "$2" > "$R/index.toml"
  git add -A && git commit -q -m "demo $2" && git -c user.signingkey="$3.pub" tag -s "$1" -m "release $2"
}
release v1.0.0 1.0.0 "$WORK/good"
cd "$ROOT"

echo "-- adding a repository"
check_out "plan: the name must be a word" "refused" bash -c "$C plan repo-add 'Bad Name' $R </dev/null; true"
check_out "plan: an address that is not https/ssh/git is refused" "address must be" bash -c "HS_PKG_ALLOW_LOCAL= $C plan repo-add test file:///tmp/x </dev/null; true"
check_out "plan: asks for the name to be typed" "^confirm_name${tab}test" $C plan repo-add test "$R"
check_out "plan: says the network is used" "^long${tab}yes" $C plan repo-add test "$R"
check_out "start without the typed name is refused" "type the name" bash -c "echo '$GOOD' | $C start repo-add test $R; true"
check_out "a line that is no key is refused" "not an SSH public key" bash -c "echo 'hello world' | $C start repo-add test $R --confirm test; true"
check_out "a key that did not sign the release: the repository is not kept" "not kept" bash -c "echo '$EVIL' | $C start repo-add test $R --confirm test; true"
check_eq "and it is not on the list" "0" "$($PKGSH --repos | grep -c "^test${tab}")"
check_out "the right key adds it" "^status${tab}done" bash -c "echo '$GOOD' | $C start repo-add test $R --confirm test"
check_out "the list shows it as signed and added" "^test${tab}.*${tab}signed${tab}added" $PKGSH --repos
check_out "the same name twice is refused" "already" bash -c "echo '$GOOD' | $C plan repo-add test $R; true"

echo "-- the market"
check_out "market lists demo as new" "^demo${tab}recipe${tab}test${tab}1[.]0[.]0${tab}-${tab}new${tab}no${tab}generic${tab}The demo package" $PKGSH --market
check_out "and the core flag of corer" "^corer${tab}recipe${tab}test${tab}1[.]0[.]0${tab}-${tab}new${tab}yes" $PKGSH --market

echo "-- install"
check_out "plan: a package of an added repository is red" "^confirm_name${tab}demo" $C plan install demo
check_out "plan: names the repository" "test" $C plan install demo
check_out "start without the typed name is refused" "type the name" bash -c "$C start install demo; true"
check_out "start with it installs" "^status${tab}done" $C start install demo --confirm demo
check "the files arrived" test -f "$HS_STATE_DIR/packages/current/demo/run.sh"
check_out "market: current" "^demo${tab}recipe${tab}test${tab}1[.]0[.]0${tab}1[.]0[.]0${tab}current" $PKGSH --market
check_out "installing again is refused" "installed already" bash -c "$C plan install demo; true"
check_out "an unknown package is refused" "no package" bash -c "$C plan install nope; true"

echo "-- update"
cd "$R"; release v1.1.0 1.1.0 "$WORK/good"; cd "$ROOT"
check_out "fetch (plan) says it uses the network" "^long${tab}yes" $C plan fetch test
check_out "fetch (start)" "^status${tab}done" $C start fetch test
check_out "market: update" "^demo${tab}recipe${tab}test${tab}1[.]1[.]0${tab}1[.]0[.]0${tab}update" $PKGSH --market
check_out "plan shows the change of the code" "^diff${tab}" $C plan update demo
check_out "and asks for the name" "^confirm_name${tab}demo" $C plan update demo
check_out "update without the name is refused" "type the name" bash -c "$C start update demo; true"
check_out "update with it" "^status${tab}done" $C start update demo --confirm demo
check_out "market: current again" "^demo${tab}recipe${tab}test${tab}1[.]1[.]0${tab}1[.]1[.]0${tab}current" $PKGSH --market
check_out "updating a current package is refused" "up to date" bash -c "$C plan update demo; true"

echo "-- remove"
check_out "a core package cannot be removed" "core package" bash -c "$C start install corer --confirm corer >/dev/null; $C plan remove corer; true"
check_out "remove plan" "^step${tab}forget" $C plan remove demo
check_out "remove" "^status${tab}done" $C start remove demo
check "the files are gone" test ! -e "$HS_STATE_DIR/packages/current/demo"
check_out "market: new again" "^demo${tab}recipe${tab}test${tab}1[.]1[.]0${tab}-${tab}new" $PKGSH --market
check_out "removing what is not installed is refused" "not installed" bash -c "$C plan remove demo; true"

echo "-- removing a repository"
check_out "a default repository stays" "default" bash -c "$C plan repo-remove recipes; true"
check_out "plan: red" "^confirm_name${tab}test" $C plan repo-remove test
check_out "without the name it is refused" "type the name" bash -c "$C start repo-remove test; true"
check_out "with it the repository goes" "^status${tab}done" $C start repo-remove test --confirm test
check_eq "and is off the list" "0" "$($PKGSH --repos | grep -c "^test${tab}")"
check_out "corer stays as an orphan" "^corer${tab}[?]${tab}test${tab}-${tab}1[.]0[.]0${tab}orphan" $PKGSH --market
sed -i '/^repo = /d;/^commit = /d;/^tag = /d' "$HS_STATE_DIR/packages/installed.toml"
check_out "an orphan without recorded provenance has a remove plan" "^step${tab}forget" $C plan remove corer
check_out "an orphan without recorded provenance can be removed" "^status${tab}done" $C start remove corer
check "the orphan's files are gone" test ! -e "$HS_STATE_DIR/packages/current/corer"
check "the orphan's record is gone" bash -c "! grep -q '^\\[package.corer\\]' '$HS_STATE_DIR/packages/installed.toml'"
finish
