#!/usr/bin/env bash
# The checks and the signing of the release workflow (.github/workflows/release.yml), kept in a script so they run in a test. Not an `hs`
# command. Run it inside a full checkout of hobnix/server (fetch-depth 0, tags fetched). Guide: docs/RELEASE-PROCESS.md, "Release from GitHub".
#
#   release-gate.sh check <version> [--sha <commit>]
#       <version> is vX.Y.Z (stable, hotfix) or vX.Y.Z-beta.N. Refuses unless: the commit (default HEAD) is the tip of origin/main and a merge
#       commit (the merged release or hotfix pull request); a beta instead: the tip of the milestone branch origin/X.Y (ADR 0007); `ci-ok` is green on it, or on its second parent (the pull request head: CI does
#       not run on a push to main); docs/RELEASE-NOTES-X.Y.md exists and names X.Y; the changelog entries validate; the tag does not exist;
#       the version is above the newest stable tag (a beta: above the earlier betas of its version, and its version not released yet);
#       main (a beta: the milestone branch) contains the newest stable tag.
#   release-gate.sh sign <version> [--sha <commit>]
#       Create the annotated tag, signed with the SSH private key in $RELEASE_SIGNING_KEY (the key text, never a file name, never logged), then
#       run the very check `hs update` runs (uc_verify of scripts/lib/update-channel.sh: a good signature by a key of
#       config/trusted-keys/server.allowed_signers, and the signed name equals the tag). If that fails the tag is deleted and the script fails.
#       A tag signed by GitHub's own key (web-flow) or any key that is not in the file never passes. Pushing is the caller's job.
#   release-gate.sh notes <version>
#       Print the path of the release notes file.
#
# Test knobs: HS_GATE_GH (the gh command, default gh), HS_GATE_REMOTE (default origin), HS_GATE_CI=skip (no CI check; refused when
# GITHUB_ACTIONS is set), GITHUB_REPOSITORY (owner/name for the CI check).
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
core=$(cd "$here/../.." && pwd)
export HS_LANG=en HS_PLAIN=1
# shellcheck source=scripts/lib/ui.sh
. "$core/scripts/lib/ui.sh"
# shellcheck source=scripts/lib/update-channel.sh
. "$core/scripts/lib/update-channel.sh"
remote=${HS_GATE_REMOTE:-origin}
gh=${HS_GATE_GH:-gh}
cmd=${1:-}; ver=${2:-}; sha=""
[ $# -gt 2 ] && { [ "${3:-}" = "--sha" ] && sha=${4:-} || fail "Unknown argument: ${3:-}"; }
[ "$cmd" != "-h" ] && [ "$cmd" != "--help" ] || { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

re='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-beta\.[1-9][0-9]*)?$'
[[ "$ver" =~ $re ]] || fail "Name a version: vX.Y.Z or vX.Y.Z-beta.N (got '${ver:-nothing}')."
beta=false; [[ "$ver" == *-beta.* ]] && beta=true
base_ver=${ver%%-*}                     # vX.Y.Z
mm=${base_ver#v}; mm=${mm%.*}           # X.Y
notes=docs/RELEASE-NOTES-$mm.md
repo_dir=$(git rev-parse --show-toplevel 2>/dev/null) || fail "Run this inside a checkout of hobnix/server."
cd "$repo_dir" || exit 1
sha=$(git rev-parse --verify -q "${sha:-HEAD}^{commit}") || fail "That commit is not here."

case $cmd in
notes) echo "$notes" ;;
check)
  src=main; $beta && src=$mm   # a beta is cut from its milestone branch (X.Y), a release or hotfix from main
  main=$(git rev-parse --verify -q "refs/remotes/$remote/$src^{commit}") || fail "$remote/$src is not here (fetch it, full history)."
  [ "$sha" = "$main" ] || fail "${sha:0:7} is not the tip of $remote/$src (${main:0:7}): a release is cut from $src as it is now."
  if $beta; then
    ok "${sha:0:7} is the tip of the milestone branch $src"
  else
    [ "$(git rev-list --parents -n1 "$sha" | wc -w)" -ge 3 ] || fail "${sha:0:7} is not a merge commit: main must end in the merged release or hotfix pull request (merge commit, no squash)."
    ok "${sha:0:7} is the tip of main and a merge commit"
  fi
  git rev-parse -q --verify "refs/tags/$ver" >/dev/null && fail "$ver exists already: a pushed tag is never moved; cut the next number."
  [ "$(git ls-remote --tags "$remote" "refs/tags/$ver" | wc -l)" = 0 ] || fail "$ver exists on $remote already."
  last=$(git tag -l 'v[0-9]*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1)
  if [ -n "$last" ]; then
    git merge-base --is-ancestor "$last^{commit}" "$sha" || fail "$src does not contain $last: every earlier release must be an ancestor."
    if $beta; then
      [ "$(printf '%s\n%s\n' "$last" "$base_ver" | sort -V | tail -n1)" = "$base_ver" ] && [ "$last" != "$base_ver" ] || fail "$base_ver is released already (newest stable $last): a beta must be for a later version."
    else
      [ "$(printf '%s\n%s\n' "$last" "$ver" | sort -V | tail -n1)" = "$ver" ] || fail "$ver is not above the newest stable tag $last."
    fi
  fi
  if $beta; then
    n=${ver##*-beta.}
    top=$(git tag -l "$base_ver-beta.*" | sed 's/.*-beta\.//' | sort -n | tail -n1)
    [ -z "$top" ] || [ "$n" -gt "$top" ] || fail "$ver is not above the earlier beta $base_ver-beta.$top."
  fi
  ok "$ver is the next version${last:+ after $last}"
  git cat-file -e "$sha:$notes" 2>/dev/null || fail "$notes is not on $src: the release has no notes (write them in the release pull request, a beta: on the milestone branch)."
  git show "$sha:$notes" | head -n 3 | grep -qF "$mm" || fail "The first lines of $notes do not name $mm: the notes belong to another release."
  ok "$notes names $mm"
  python3 -I "$core/scripts/lib/changelog.py" validate "$repo_dir" >/dev/null 2>&1 || fail "The changelog entries do not validate (python3 -I scripts/lib/changelog.py validate .)."
  ok "the changelog validates"
  if [ "${HS_GATE_CI:-}" = skip ]; then
    [ -z "${GITHUB_ACTIONS:-}" ] || fail "HS_GATE_CI=skip is not allowed on GitHub."
    note "ci-ok was not checked (HS_GATE_CI=skip)"
  else
    slug=${GITHUB_REPOSITORY:-}
    [ -n "$slug" ] || fail "GITHUB_REPOSITORY is not set: cannot ask for ci-ok."
    green=""
    for c in "$sha" "$(git rev-parse -q --verify "$sha^2" 2>/dev/null || true)"; do
      [ -n "$c" ] || continue
      concl=$($gh api "repos/$slug/commits/$c/check-runs" --jq '[.check_runs[] | select(.name == "ci-ok")] | sort_by(.started_at) | last | .conclusion // "none"' 2>/dev/null || echo unknown)
      [ "$concl" = success ] && { green=$c; break; }
    done
    [ -n "$green" ] || fail "ci-ok is not green on ${sha:0:7} or on the head of its pull request (last answer: ${concl:-none})."
    ok "ci-ok is green on ${green:0:7}"
  fi
  ;;
sign)
  [ -n "${RELEASE_SIGNING_KEY:-}" ] || fail "RELEASE_SIGNING_KEY is empty."
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/hs-gate.XXXXXX"); chmod 700 "$tmp"
  trap 'rm -rf "$tmp"' EXIT
  ( umask 077; printf '%s\n' "$RELEASE_SIGNING_KEY" > "$tmp/key" )
  ssh-keygen -y -f "$tmp/key" > "$tmp/key.pub" 2>/dev/null || fail "RELEASE_SIGNING_KEY is not an unencrypted OpenSSH private key."
  git -c gpg.format=ssh -c user.signingkey="$tmp/key" -c user.name="${GIT_COMMITTER_NAME:-Hobnix release}" -c user.email="${GIT_COMMITTER_EMAIL:-release@users.noreply.github.com}" \
    tag -s "$ver" "$sha" -m "Hobnix ${ver#v}" >/dev/null 2>&1 || fail "Signing failed."
  if ! uc_verify "$repo_dir" "$ver"; then
    git tag -d "$ver" >/dev/null 2>&1
    fail "The tag does not verify against config/trusted-keys/server.allowed_signers (${UC_VERIFY_OUT:-no reason given}): it was removed, nothing is pushed."
  fi
  ok "$ver is signed and passes the check hs update uses"
  ;;
*) fail "Unknown command: ${cmd:-none} (see --help)" ;;
esac
