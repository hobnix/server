#!/usr/bin/env bash
# Releases of the package repositories (hobnix/recipes, hobnix/extensions; docs/PLAN-packages.md). Run it INSIDE the checkout of one of them.
# Not an `hs` command.
#
#   bash <core>/scripts/dev/release.sh [patch|minor|major] [--yes] [--key <file.pub>]
#       Tag the repository: the next vX.Y.Z (default patch) on main, signed with the release key, verified against the core's
#       config/trusted-keys, then pushed. Refuses unless you are on main, the tree is clean, main equals origin/main and `pkg.py repo-check`
#       passes. Shows what goes into the release and asks you to type the tag, or pass --yes.
#   bash <core>/scripts/dev/release.sh bump <package> [patch|minor|major] [--pr]
#       Raise the version of one package (package.toml and index.toml agree, the rule of CONTRIBUTING.md), commit it on the current
#       branch (not main) and push the branch; --pr also opens the pull request.
#
# The key is $HS_RELEASE_KEY or ~/.ssh/hobnix_release.pub (the private key beside it, or in ssh-agent). Test knobs: --signers <file>
# (allowed-signers file instead of the core's), HS_RELEASE_REMOTE (default origin).
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
core=$(cd "$here/../.." && pwd)
export HS_LANG=${HS_LANG:-en}
# shellcheck source=scripts/lib/ui.sh
. "$core/scripts/lib/ui.sh"
remote=${HS_RELEASE_REMOTE:-origin}
key=${HS_RELEASE_KEY:-$HOME/.ssh/hobnix_release.pub}
signers="" yes=false pr=false mode="" what=tag pkg=""

while [ $# -gt 0 ]; do
  case $1 in
    patch|minor|major) mode=$1 ;;
    bump) what=bump; shift; pkg=${1:-} ;;
    --yes) yes=true ;;
    --pr) pr=true ;;
    --key) shift; key=${1:-} ;;
    --signers) shift; signers=${1:-} ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "Unknown argument: $1 (see --help)" ;;
  esac
  shift
done
mode=${mode:-patch}

git rev-parse --show-toplevel >/dev/null 2>&1 || fail "Run this inside the checkout of hobnix/recipes or hobnix/extensions."
cd "$(git rev-parse --show-toplevel)" || exit 1
[ -f index.toml ] || fail "There is no index.toml here: this is not a package repository."
if [ -d recipes ]; then repo=recipes; elif [ -d extensions ]; then repo=extensions; else fail "Neither recipes/ nor extensions/ is here."; fi

next_version() {   # next_version <x.y.z> <mode>
  local v=${1#v} m=$2 a b c
  IFS=. read -r a b c <<<"$v"
  case $m in
    major) echo "$((a + 1)).0.0" ;;
    minor) echo "$a.$((b + 1)).0" ;;
    *) echo "$a.$b.$((c + 1))" ;;
  esac
}
valid_semver() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

if [ "$what" = bump ]; then
  step "Raise the version of a package"
  [[ "$pkg" =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail "Name the package: release.sh bump <package> [patch|minor|major]"
  dir=$repo/$pkg
  [ -f "$dir/package.toml" ] || fail "There is no package $pkg in $repo/."
  branch=$(git branch --show-current)
  [ -n "$branch" ] && [ "$branch" != main ] || fail "Make a branch first (feature/<topic>); a version change goes in through a pull request."
  old=$(sed -n 's/^version = "\(.*\)"$/\1/p' "$dir/package.toml" | head -n1)
  valid_semver "$old" || fail "The version in $dir/package.toml is not x.y.z."
  new=$(next_version "$old" "$mode")
  sed -i "0,/^version = \".*\"\$/s//version = \"$new\"/" "$dir/package.toml"
  # the same version in the block [package.<name>] of index.toml
  awk -v n="[package.$pkg]" -v v="$new" '
    $0 == n { inblock = 1; print; next }
    /^\[/ { inblock = 0 }
    inblock && /^version = / { print "version = \"" v "\""; next }
    { print }' index.toml > index.toml.new && mv index.toml.new index.toml
  python3 -I "$core/scripts/pkg.py" repo-check . >/dev/null 2>&1 || { git checkout -- "$dir/package.toml" index.toml; fail "repo-check fails with the new version; nothing was changed."; }
  git add "$dir/package.toml" index.toml
  git commit -q -m "$pkg: $old -> $new" || fail "The commit failed."
  ok "$(t '%s: %s -> %s, committed on %s' "$pkg" "$old" "$new" "$branch")"
  git push -q -u "$remote" "$branch" || fail "The push failed."
  ok "$(t 'Branch %s pushed' "$branch")"
  if $pr; then
    command -v gh >/dev/null 2>&1 || fail "gh is not installed: open the pull request by hand."
    gh pr create --base main --title "$pkg: $old -> $new" --body "Raises the version of $pkg ($mode). package.toml and index.toml agree." || fail "gh could not open the pull request."
  else
    next_step "gh pr create --base main"
  fi
  exit 0
fi

# ── tag the repository ──
step "Check the repository"
[ "$(git branch --show-current)" = main ] || fail "Switch to main first: a release is always cut from main."
[ -z "$(git status --porcelain)" ] || fail "The tree has uncommitted changes."
git fetch -q "$remote" main --tags || fail "Could not fetch $remote."
[ "$(git rev-parse HEAD)" = "$(git rev-parse "$remote/main")" ] || fail "main differs from $remote/main: pull or push first."
python3 -I "$core/scripts/pkg.py" repo-check . >/dev/null 2>&1 || fail "pkg.py repo-check fails: the index does not match the folders."
ok "main is clean, equals $remote/main, and the index is consistent"

last=$(git tag -l 'v[0-9]*' --sort=-v:refname | head -n1)
last=${last:-v0.0.0}
valid_semver "${last#v}" || fail "The last tag $last is not vX.Y.Z."
tag=v$(next_version "$last" "$mode")
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && fail "$tag exists already."
[ -f "$key" ] || fail "The release key $key does not exist (HS_RELEASE_KEY or --key)."
[ -n "$signers" ] || signers=$core/config/trusted-keys/$repo.allowed_signers
[ -f "$signers" ] || fail "There is no allowed-signers file $signers."

step "What goes into the release"
kv "Repository" "$repo"
kv "Release" "$last -> $tag ($mode)"
kv "Commit" "$(git log -1 --format='%h %s' | cut -c1-70)"
kv "Key" "$key"
n=$(git rev-list --count "$last..HEAD" 2>/dev/null || echo "?")
note "$(t '%s commit(s) since %s' "$n" "$last")"
git log --format='%h %s' "$last..HEAD" 2>/dev/null | head -n 12 | trail

if ! $yes; then
  [ -t 0 ] || fail "Without a terminal pass --yes."
  confirm_name "$tag" "$(t 'the release')" || fail "Not confirmed: nothing was tagged."
fi

step "Sign, verify, push"
git -c gpg.format=ssh -c user.signingkey="$key" tag -s "$tag" -m "$repo $tag" || fail "Signing failed (is the key in ssh-agent, or unencrypted?)."
if ! git -c gpg.format=ssh -c gpg.ssh.allowedSignersFile="$signers" tag -v "$tag" >/dev/null 2>&1; then
  git tag -d "$tag" >/dev/null
  fail "The signature does not verify against $signers: the tag was removed again, nothing is pushed."
fi
ok "$(t '%s is signed and verifies against the trusted key' "$tag")"
if ! git push -q "$remote" "$tag"; then
  warn "The push failed. The tag exists locally: git push $remote $tag, or git tag -d $tag"
  exit 1
fi
ok "$(t '%s pushed' "$tag")"
next_step "hs pkg fetch   (on the server)"
