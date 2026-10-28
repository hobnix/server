#!/usr/bin/env bash
# The export of the packages into the two package repositories (scripts/dev/export-package-repos.py) and the whole way back: a signed
# release tag in the exported repository, hs pkg repo add / fetch / install of a recipe and an extension from it. No network.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
have git || { skip "needs git"; finish; exit 0; }
have ssh-keygen || { skip "needs ssh-keygen"; finish; exit 0; }
export HS_LANG=en HS_PLAIN=1 HS_STATE_DIR=$WORK/state
mkdir -p "$HS_STATE_DIR"
PKG="python3 -I $SCRIPTS/pkg.py"
tab=$'\t'
OUT=$WORK/out
check "the export runs" python3 "$SCRIPTS/dev/export-package-repos.py" --out "$OUT"
check_eq "every recipe is in hobnix-recipes" "$(ls "$ROOT"/packages | wc -l)" "$(ls "$OUT/hobnix-recipes/recipes" | wc -l)"
check_eq "the two extensions are in hobnix-extensions" "games posters" "$(ls "$OUT/hobnix-extensions/extensions" | tr '\n' ' ' | sed 's/ $//')"
check "the recipes index matches its folders" $PKG repo-check "$OUT/hobnix-recipes"
check "the extensions index matches its folders" $PKG repo-check "$OUT/hobnix-extensions"
check_eq "the repository has exactly one commit" "1" "$(git -C "$OUT/hobnix-recipes" rev-list --count HEAD)"
if [ -n "${HS_LEAK_PATTERNS:-}" ]; then   # the author's names and domains: a file outside the repository (it would be the leak itself)
  check "and none of the author's names or secrets (leak-scan)" python3 "$SCRIPTS/dev/leak-scan.py" "$OUT/hobnix-recipes" --all-files --patterns "$HS_LEAK_PATTERNS"
else
  skip "leak-scan with the author's patterns needs HS_LEAK_PATTERNS"
fi
check_out "core recipes are flagged" 'core = true' grep -A8 'package.homepage' "$OUT/hobnix-recipes/index.toml"

echo "-- a mistake in the index is found"
cp -r "$OUT/hobnix-recipes" "$WORK/broken"
sed -i '0,/version = "1.0.0"/s//version = "9.9.9"/' "$WORK/broken/index.toml"
check_out "a version that differs from package.toml is named" "differs from package.toml" bash -c "$PKG repo-check $WORK/broken; true"

echo "-- release, add, fetch, install (on a server whose own tree has no packages: as it will be once they only come from repositories)"
mkdir -p "$WORK/empty/packages"; export HS_PACKAGES_ROOT=$WORK/empty
ssh-keygen -q -t ed25519 -N '' -f "$WORK/key" -C t >/dev/null
printf 'releaser@test namespaces="git" %s\n' "$(cut -d' ' -f1,2 "$WORK/key.pub")" > "$WORK/signers"
git -C "$OUT/hobnix-recipes" -c gpg.format=ssh -c user.signingkey="$WORK/key.pub" -c user.name=t -c user.email=t@t tag -s v1.0.0 -m release
git -C "$OUT/hobnix-extensions" -c gpg.format=ssh -c user.signingkey="$WORK/key.pub" -c user.name=t -c user.email=t@t tag -s v1.0.0 -m release
check "recipes repository added" $PKG repo add rtest "$OUT/hobnix-recipes" --key "$WORK/signers"
check "extensions repository added" $PKG repo add etest "$OUT/hobnix-extensions" --key "$WORK/signers"
check_out "fetch verifies both" "^rtest${tab}v1[.]0[.]0" $PKG fetch
check_out "a recipe installs from the repository" "homepage 1[.]0[.]0 from rtest" $PKG install homepage
check "its run.sh arrived" test -f "$HS_STATE_DIR/packages/current/homepage/run.sh"
check_out "an extension installs from the repository" "posters 1[.]0[.]0 from etest" $PKG install posters
check "the installed manifests validate" $PKG validate
check_out "hs pkg list shows both kinds" "^posters${tab}extension" $PKG list
finish
