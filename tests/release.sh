#!/usr/bin/env bash
# scripts/dev/release.sh: the next signed tag of a package repository (patch, minor, major), the refusals (not on main, dirty tree, a key that is
# not trusted), and `bump <package>` (package.toml and index.toml agree, a commit on a branch). A local bare repository stands in for GitHub.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
have git || { skip "needs git"; finish; exit 0; }
have ssh-keygen || { skip "needs ssh-keygen"; finish; exit 0; }
export HS_LANG=en HS_PLAIN=1
REL="bash $SCRIPTS/dev/release.sh"
ssh-keygen -q -t ed25519 -N '' -f "$WORK/good" -C test >/dev/null
ssh-keygen -q -t ed25519 -N '' -f "$WORK/evil" -C test >/dev/null
printf 'releaser@test namespaces="git" %s\n' "$(cut -d' ' -f1,2 "$WORK/good.pub")" > "$WORK/signers"
git init -q --bare "$WORK/remote.git"
R=$WORK/repo; mkdir -p "$R/recipes/demo"; cd "$R" || exit 1
git init -q -b main . && git config user.email t@t && git config user.name t && git config commit.gpgsign false
git remote add origin "$WORK/remote.git"
printf 'name = "demo"\nversion = "1.0.0"\nkind = "recipe"\ntitle = "Demo"\nrequires_core = ">=1"\naudience = "generic"\nneeds = []\nuses = []\ninput = "none"\nscript = "run.sh"\n' > recipes/demo/package.toml
printf '#!/usr/bin/env bash\n# kind: generic\n# needs: -\n# uses: -\n' > recipes/demo/run.sh
printf '[package.demo]\nversion = "1.0.0"\nkind = "recipe"\npath = "recipes/demo"\nrequires_core = ">=1"\n' > index.toml
git add -A && git commit -q -m first && git -c gpg.format=ssh -c user.signingkey="$WORK/good.pub" tag -s v1.0.0 -m first && git push -q origin main --tags
rel() { $REL "$@" --key "$WORK/good.pub" --signers "$WORK/signers" 2>&1; }
remote_tags() { git ls-remote --tags origin | grep -v '\^{}' | sed 's#.*refs/tags/##' | sort | paste -sd' ' -; }
commit() { echo "$1" >> note.txt; git add -A && git commit -q -m "$1" && git push -q origin main; }

echo "-- tags"
commit one
check_out "patch makes v1.0.1" "v1[.]0[.]1 pushed" rel patch --yes
check_eq "and it is on the remote" "v1.0.0 v1.0.1" "$(remote_tags)"
commit two
check_out "minor makes v1.1.0" "v1[.]1[.]0 pushed" rel minor --yes
commit three
check_out "major makes v2.0.0" "v2[.]0[.]0 pushed" rel major --yes
commit four
check_out "no mode means patch" "v2[.]0[.]1 pushed" rel --yes
check "the tag verifies against the trusted key" git -c gpg.format=ssh -c gpg.ssh.allowedSignersFile="$WORK/signers" tag -v v2.0.1

echo "-- refusals"
commit five
check_out "without a terminal and without --yes it refuses" "pass --yes" bash -c "$REL patch --key $WORK/good.pub --signers $WORK/signers </dev/null 2>&1; true"
check_out "a key that is not trusted is refused" "does not verify" bash -c "$REL patch --yes --key $WORK/evil.pub --signers $WORK/signers 2>&1; true"
check_eq "and its tag is gone, locally and on the remote" "v1.0.0 v1.0.1 v1.1.0 v2.0.0 v2.0.1" "$(remote_tags)"
check_eq "no tag v2.0.2 is left here" "" "$(git tag -l v2.0.2)"
echo dirty >> note.txt
check_out "a dirty tree is refused" "uncommitted" rel patch --yes
git checkout -q -- note.txt
git checkout -q -b feature/x
check_out "off main is refused" "Switch to main" rel patch --yes
git checkout -q main
echo local >> note.txt; git add -A; git commit -q -m unpushed
check_out "a main that differs from the remote is refused" "differs from" rel patch --yes
git reset -q --hard origin/main

echo "-- bump"
check_out "bump on main is refused" "Make a branch first" rel bump demo minor
git checkout -q -b feature/demo-bump
check_out "bump says what it did" "demo: 1[.]0[.]0 -> 1[.]1[.]0" rel bump demo minor
check_eq "package.toml has the new version" 'version = "1.1.0"' "$(grep '^version' recipes/demo/package.toml)"
check_eq "index.toml has it too" 'version = "1.1.0"' "$(grep '^version' index.toml)"
check_eq "and it is one commit" "demo: 1.0.0 -> 1.1.0" "$(git log -1 --format=%s)"
check_out "the branch is on the remote" "feature/demo-bump" git ls-remote --heads origin
check_out "a package that does not exist is refused" "no package" bash -c "$REL bump nope 2>&1; true"

echo "-- unbumped (pkg.py repo-unbumped: a folder changed since a tag without a version rise)"
PKG="python3 -I $SCRIPTS/pkg.py"
git checkout -q main && git reset -q --hard origin/main
mkpkg() {   # mkpkg <name>: a package folder and its index block at version 1.0.0
  mkdir -p "recipes/$1"; sed "s/demo/$1/" recipes/demo/package.toml > "recipes/$1/package.toml"; cp recipes/demo/run.sh "recipes/$1/run.sh"
  printf '\n[package.%s]\nversion = "1.0.0"\nkind = "recipe"\npath = "recipes/%s"\nrequires_core = ">=1"\n' "$1" "$1" >> index.toml
}
for n in chg same both pkgonly gone; do mkpkg "$n"; done
mkdir -p tests docs; echo t > tests/a.txt
git add -A && git commit -q -m base && git tag base
git checkout -q -b feature/unbumped
echo x >> recipes/chg/run.sh                          # changed, no bump: listed
echo x >> recipes/same/run.sh; $REL bump same >/dev/null 2>&1   # changed and raised in both files: not listed
echo x >> recipes/both/run.sh                         # changed, only package.toml raised: listed
sed -i 's/^version = "1.0.0"/version = "1.0.1"/' recipes/both/package.toml
echo x >> recipes/pkgonly/run.sh                      # changed, only index.toml raised: listed
sed -i '/^\[package.pkgonly\]/,/^version/s/^version = .*/version = "1.0.1"/' index.toml
git rm -rq recipes/gone                               # removed: not listed
sed -i '/^\[package.gone\]/,/^$/d;/^\[package.gone\]/,$d' index.toml
mkpkg fresh                                           # new since the tag: not listed
echo y >> tests/a.txt; echo y > docs/b.md             # outside the package folders: not listed
git add -A && git commit -q -m changes
out=$($PKG repo-unbumped base . 2>&1); rc=$?
check_eq "exit 1 when a package is unbumped" "1" "$rc"
check_eq "exactly chg, both and pkgonly are listed" "both chg pkgonly" "$(printf '%s\n' "$out" | cut -d: -f1 | sort | paste -sd' ' -)"
check_eq "one line per package" "3" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
git checkout -q -b feature/fixed
for n in chg both pkgonly; do
  sed -i 's/^version = ".*"/version = "1.2.0"/' "recipes/$n/package.toml"
  sed -i "/^\[package.$n\]/,/^version/s/^version = .*/version = \"1.2.0\"/" index.toml
done
git add -A && git commit -q -m "raise all"
check_eq "all raised in both files: nothing is listed" "" "$($PKG repo-unbumped base . 2>&1)"
check "and the exit is 0" $PKG repo-unbumped base .
check_out "an unknown tag is an error" "no index.toml" bash -c "$PKG repo-unbumped nope . 2>&1; true"
git checkout -q main
finish
