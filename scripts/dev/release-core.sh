#!/usr/bin/env bash
# Releases of the core (hobnix/server): milestone branch sync, signed tag, checks. Guide: docs/RELEASE-PROCESS.md.
# Not an `hs` command. Works from any checkout or worktree of the repository and never switches its branch (it uses origin/* refs and,
# where a merge is needed, a temporary worktree). The package repositories keep scripts/dev/release.sh.
#
#   release-core.sh status
#       Where develop, main and the milestone branches stand, the newest tag, and what is not merged forward. Changes nothing.
#   release-core.sh sync [--from develop] [--to 0.2] [--pr] [--yes]
#       Merge origin/<from> into origin/<to> (merge commit) on a branch chore/sync-<from>-into-<to>-<rev> and push it; --pr opens the pull
#       request. Does nothing when <to> already holds <from>. Stops on a conflict and leaves nothing behind.
#   release-core.sh tag <vX.Y.Z> [--yes] [--key <file.pub>] [--signers <file>] [--no-ci-check]
#       Sign the tip of origin/main as <vX.Y.Z>, verify the signature against config/trusted-keys/server.allowed_signers (as it is on
#       origin/main), push the tag. Refuses a prerelease tag, a tag that exists, a tag not above the newest stable tag,
#       a main that does not contain the newest stable tag, a red or missing ci-ok on the commit. The push starts the ISO build.
#   release-core.sh verify <vX.Y.Z>
#       Fetch tags; check the signature, that the tag is on origin/main and that it names itself. Changes nothing.
#   release-core.sh follow-check [<vX.Y.Z>] [--after]
#       Run ON A SERVER (it reads `hs sys release show`, changes nothing): is the stable channel set, does it point at the tag, is the
#       tag signed, has the server installed it. --after also demands that it has.
#
# Key: $HS_RELEASE_KEY or ~/.ssh/hobnix_release.pub (private key beside it, or in ssh-agent). The core's key is not the packages' key.
# Test knobs: HS_RELEASE_REMOTE (default origin), HS_RELEASE_BASE (default main), HS_RELEASE_SHOW (command that prints `hs sys release show`).
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
core=$(cd "$here/../.." && pwd)
export HS_LANG=${HS_LANG:-en}
# shellcheck source=scripts/lib/ui.sh
. "$core/scripts/lib/ui.sh"
remote=${HS_RELEASE_REMOTE:-origin}
base=${HS_RELEASE_BASE:-main}
key=${HS_RELEASE_KEY:-$HOME/.ssh/hobnix_release.pub}
signers="" yes=false pr=false ci_check=true after=false from="" to="" cmd=${1:-}
[ $# -eq 0 ] || shift
arg=""
while [ $# -gt 0 ]; do
  case $1 in
    --yes) yes=true ;;
    --pr) pr=true ;;
    --after) after=true ;;
    --no-ci-check) ci_check=false ;;
    --key) shift; key=${1:-} ;;
    --signers) shift; signers=${1:-} ;;
    --from) shift; from=${1:-} ;;
    --to) shift; to=${1:-} ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) fail "Unknown argument: $1 (see --help)" ;;
    *) [ -z "$arg" ] || fail "Too many arguments: $1"; arg=$1 ;;
  esac
  shift
done
[ -n "$cmd" ] || { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
[ "$cmd" = "-h" ] || [ "$cmd" = "--help" ] && { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

stable_re='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
ref_ok() { git rev-parse -q --verify "$1^{commit}" >/dev/null 2>&1; }
confirm() {   # confirm <name> <what>: --yes, or type the name
  $yes && return 0
  [ -t 0 ] || fail "Without a terminal pass --yes."
  confirm_name "$1" "$2" || fail "Not confirmed: nothing was changed."
}
fetch() { git fetch -q "$remote" --tags --prune 2>/dev/null || fail "Could not fetch $remote."; }
newest_stable() { git tag -l 'v[0-9]*' | grep -E "$stable_re" | sort -V | tail -n1; }
repo_slug() {   # owner/name of a GitHub remote, empty for anything else
  git remote get-url "$remote" 2>/dev/null | sed -nE 's#^(https://github\.com/|git@github\.com:)([^/]+/[^/]+?)(\.git)?$#\2#p' | sed 's/\.git$//'
}

if [ "$cmd" = follow-check ]; then
  show=${HS_RELEASE_SHOW:-hs sys release show}
  want=$arg
  [ -z "$want" ] || [[ "$want" =~ $stable_re ]] || fail "Name a stable tag: vX.Y.Z"
  out=$($show 2>&1) || fail "$(t 'Could not run: %s' "$show")"
  get() { printf '%s\n' "$out" | awk -F'\t' -v k="$1" '$1 == k { print $2; exit }'; }
  bad=0
  chk() { if [ "$1" = ok ]; then ok "$2"; else warn "$2"; bad=1; fi; }
  step "Is this server set up to follow the stable channel?"
  channel=$(get channel); installed=$(get installed); ref=$(get ref); state=$(get state); signed=$(get signed)
  kv "Channel" "${channel:--}"; kv "Installed" "${installed:--}"; kv "Would install" "${ref:--}"; kv "State" "${state:--}"; kv "Signed" "${signed:--}"
  [ "$channel" = stable ] && chk ok "Channel is stable" || chk no "Channel is $channel, not stable: hs config set updateChannel stable"
  if [[ "$ref" =~ $stable_re ]]; then chk ok "Stable offers a release tag ($ref)"; else chk no "Stable offers no release tag yet (ref: ${ref:--}, state: ${state:--}): was the tag pushed, and did hs update fetch it?"; fi
  [ -z "$want" ] || [ "$ref" = "$want" ] && chk ok "Stable points at ${want:-a tag}" || chk no "Stable points at ${ref:--}, expected $want"
  [ "$signed" = yes ] && chk ok "The tag is signed with a trusted key" || chk no "The tag is not verified (signed: ${signed:--})"
  step "Has the server installed it?"
  followed=no
  if [ "$state" = current ] && [[ "$installed" =~ $stable_re ]] && { [ -z "$want" ] || [ "$installed" = "$want" ]; }; then followed=yes; fi
  if [ "$followed" = yes ]; then ok "Installed version is ${installed}: the server follows stable"
  elif [ "$state" = update ]; then note "Not yet: run hs update --preview, then hs update"; $after && bad=1
  else note "Not followed (installed: ${installed:--}, state: ${state:--})"; $after && bad=1; fi
  [ $bad -eq 0 ] || exit 1
  exit 0
fi

git rev-parse --show-toplevel >/dev/null 2>&1 || fail "Run this inside a checkout of hobnix/server."
cd "$(git rev-parse --show-toplevel)" || exit 1
git remote get-url "$remote" >/dev/null 2>&1 || fail "There is no remote $remote."

case $cmd in
status)
  fetch
  step "Branches"
  for b in "$base" develop; do
    ref_ok "$remote/$b" || { warn "$remote/$b does not exist"; continue; }
    kv "$b" "$(git log -1 --format='%h %s' "$remote/$b" | cut -c1-60)"
  done
  git for-each-ref --format='%(refname:short)' "refs/remotes/$remote/hotfix/" | while read -r r; do kv "${r#"$remote"/}" "$(git log -1 --format='%h %s' "$r" | cut -c1-60)"; done
  git for-each-ref --format='%(refname:short)' "refs/remotes/$remote/" | sed "s#^$remote/##" | grep -E '^[0-9]+\.[0-9]+$' | while read -r m; do kv "$m (milestone)" "$(git log -1 --format='%h %s' "$remote/$m" | cut -c1-60)"; done
  step "Tags"
  last=$(newest_stable)
  kv "Newest stable" "${last:-none}"
  if [ -n "$last" ]; then
    if git merge-base --is-ancestor "$last" "$remote/$base" 2>/dev/null; then ok "$last is on $base"; else warn "$last is not on $base"; fi
    kv "$base after tag" "$(git rev-list --count "$last..$remote/$base") commit(s)"
  fi
  step "What is not merged forward"
  if ref_ok "$remote/$base" && ref_ok "$remote/develop"; then
    n=$(git rev-list --count "$remote/develop..$remote/$base")
    if [ "$n" = 0 ]; then ok "develop holds everything on $base"; else warn "$n commit(s) on $base are not on develop: merge $base back into develop (docs/RELEASE-PROCESS.md)"; fi
  fi
  git for-each-ref --format='%(refname:short)' "refs/remotes/$remote/" | sed "s#^$remote/##" | grep -E '^[0-9]+\.[0-9]+$' | while read -r m; do
    n=$(git rev-list --count "$remote/$m..$remote/develop"); k=$(git rev-list --count "$remote/$m..$remote/$base")
    if [ "$n" = 0 ] && [ "$k" = 0 ]; then ok "$m holds develop and $base"; else warn "$m is missing $n commit(s) of develop and $k of $base: release-core.sh sync --to $m"; fi
  done
  ;;
sync)
  src=${from:-develop}; dst=${to:-0.2}
  fetch
  ref_ok "$remote/$src" || fail "$remote/$src does not exist."
  ref_ok "$remote/$dst" || fail "$remote/$dst does not exist."
  n=$(git rev-list --count "$remote/$dst..$remote/$src")
  if [ "$n" = 0 ]; then ok "$dst already holds $src"; exit 0; fi
  step "Merge $src into $dst"
  kv "Missing on $dst" "$n commit(s)"
  git log --format='%h %s' "$remote/$dst..$remote/$src" | head -n 10 | trail
  confirm "$dst" "the branch that receives"
  br=chore/sync-${src//\//-}-into-${dst//\//-}-$(git rev-parse --short "$remote/$src")
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/hs-sync.XXXXXX")
  cleanup() { git worktree remove --force "$tmp" >/dev/null 2>&1; rm -rf "$tmp"; }
  trap cleanup EXIT
  git worktree add -q -b "$br" "$tmp" "$remote/$dst" >/dev/null 2>&1 || fail "Could not make a temporary worktree (does $br exist?)."
  if ! git -C "$tmp" -c user.name="${GIT_AUTHOR_NAME:-$(git config user.name)}" -c user.email="${GIT_AUTHOR_EMAIL:-$(git config user.email)}" merge -q --no-ff -m "Merge $src into $dst" "$remote/$src" >/dev/null 2>&1; then
    git -C "$tmp" merge --abort >/dev/null 2>&1
    cleanup; trap - EXIT; git branch -q -D "$br" >/dev/null 2>&1
    fail "The merge conflicts. Resolve it by hand in a worktree: git merge $remote/$src on a branch from $remote/$dst. Nothing was pushed."
  fi
  git push -q -u "$remote" "$br" || fail "The push failed."
  ok "$br pushed"
  if $pr; then
    command -v gh >/dev/null 2>&1 || fail "gh is not installed: open the pull request by hand."
    gh pr create --base "$dst" --head "$br" --title "Merge $src into $dst" --body "Keeps $dst in step with $src. Merge with a merge commit, no squash." || fail "gh could not open the pull request."
  else
    next_step "gh pr create --base $dst --head $br   (merge with a merge commit)"
  fi
  ;;
tag)
  tag=$arg
  [[ "$tag" =~ $stable_re ]] || fail "Name a stable tag: vX.Y.Z. (Prerelease tags are not cut by this script.)"
  fetch
  ref_ok "$remote/$base" || fail "$remote/$base does not exist."
  git rev-parse -q --verify "refs/tags/$tag" >/dev/null && fail "$tag exists already: a pushed tag is never moved; cut the next one."
  last=$(newest_stable)
  if [ -n "$last" ] && [ "$(printf '%s\n%s\n' "$last" "$tag" | sort -V | tail -n1)" != "$tag" ]; then fail "$tag is not above the newest stable tag $last."; fi
  sha=$(git rev-parse "$remote/$base")
  [ -z "$last" ] || git merge-base --is-ancestor "$last^{commit}" "$sha" || fail "$remote/$base does not contain $last: main must keep every earlier release as an ancestor."
  [ -f "$key" ] || fail "The release key $key does not exist (HS_RELEASE_KEY or --key)."
  if [ -z "$signers" ]; then
    signers=$(mktemp "${TMPDIR:-/tmp}/hs-signers.XXXXXX")
    git show "$remote/$base:config/trusted-keys/server.allowed_signers" > "$signers" 2>/dev/null || { rm -f "$signers"; fail "$remote/$base has no config/trusted-keys/server.allowed_signers."; }
    trap 'rm -f "$signers"' EXIT
  fi
  [ -s "$signers" ] || fail "The allowed-signers file is empty."
  if $ci_check; then
    slug=$(repo_slug)
    if [ -n "$slug" ] && command -v gh >/dev/null 2>&1; then
      concl=$(gh api "repos/$slug/commits/$sha/check-runs" --jq '[.check_runs[] | select(.name == "ci-ok")] | sort_by(.started_at) | last | .conclusion // "none"' 2>/dev/null || echo unknown)
      [ "$concl" = success ] || fail "ci-ok on ${sha:0:7} is '$concl', not success. Wait for CI (--no-ci-check skips this check)."
      ok "ci-ok is green on ${sha:0:7}"
    else
      note "ci-ok was not checked (no GitHub remote or no gh): look at the pull request before you go on"
    fi
  fi
  minor=${tag#v}; minor=${minor%.*}
  git cat-file -e "$sha:docs/RELEASE-NOTES-$minor.md" 2>/dev/null || warn "docs/RELEASE-NOTES-$minor.md is not on $base: the release gets generated notes"
  step "What goes into the release"
  kv "Release" "${last:-none} -> $tag"
  kv "Commit" "$(git log -1 --format='%h %s' "$sha" | cut -c1-70)"
  kv "Key" "$key"
  danger "The push starts the ISO build and publishes the release. A pushed tag is never moved."
  confirm "$tag" "the release"
  git -c gpg.format=ssh -c user.signingkey="$key" tag -s "$tag" "$sha" -m "Hobnix ${tag#v}" || fail "Signing failed (is the key in ssh-agent, or unencrypted?)."
  if ! git -c gpg.format=ssh -c gpg.ssh.allowedSignersFile="$signers" tag -v "$tag" >/dev/null 2>&1; then
    git tag -d "$tag" >/dev/null
    fail "The signature does not verify against server.allowed_signers: the tag was removed again, nothing is pushed."
  fi
  ok "$tag is signed and verifies against the trusted key"
  if ! git push -q "$remote" "$tag"; then
    warn "The push failed. The tag exists locally: git push $remote $tag, or git tag -d $tag"
    exit 1
  fi
  ok "$tag pushed"
  next_step "gh run watch --repo ${slug:-hobnix/server}; then release-core.sh verify $tag"
  ;;
verify)
  tag=$arg
  [[ "$tag" =~ $stable_re ]] || fail "Name a stable tag: vX.Y.Z"
  fetch
  git rev-parse -q --verify "refs/tags/$tag" >/dev/null || fail "$tag is not here."
  signers=${signers:-$(mktemp "${TMPDIR:-/tmp}/hs-signers.XXXXXX")}
  if [ ! -s "$signers" ]; then
    git show "$remote/$base:config/trusted-keys/server.allowed_signers" > "$signers" 2>/dev/null || fail "$remote/$base has no server.allowed_signers."
    trap 'rm -f "$signers"' EXIT
  fi
  bad=0
  if git -c gpg.format=ssh -c gpg.ssh.allowedSignersFile="$signers" tag -v "$tag" >/dev/null 2>&1; then ok "$tag: good signature"; else warn "$tag: the signature does not verify"; bad=1; fi
  if git merge-base --is-ancestor "$tag^{commit}" "$remote/$base"; then ok "$tag is on $base"; else warn "$tag is not on $base"; bad=1; fi
  [ "$(git cat-file -t "$tag")" = tag ] && ok "$tag is an annotated tag" || { warn "$tag is not annotated"; bad=1; }
  [ $bad -eq 0 ] || exit 1
  ;;
*) fail "Unknown command: $cmd (see --help)" ;;
esac
