#!/usr/bin/env bash
# DCO check (CONTRIBUTING.md "Sign your commits"): every commit in BASE..HEAD carries a `Signed-off-by: Name <email>` trailer.
# Exempt: merge commits and commits by bots (author name or email ends in [bot], or dependabot / renovate).
# Usage: scripts/dev/dco-check.sh <base-sha> [head-sha]   (head defaults to HEAD). Exit 0 = all signed, 1 = unsigned commits, 2 = bad usage.
set -u
base=${1:-}; head=${2:-HEAD}
[ -n "$base" ] || { echo "usage: dco-check.sh <base-sha> [head-sha]" >&2; exit 2; }
git rev-parse -q --verify "$base^{commit}" >/dev/null || { echo "dco-check: unknown base commit: $base" >&2; exit 2; }
git rev-parse -q --verify "$head^{commit}" >/dev/null || { echo "dco-check: unknown head commit: $head" >&2; exit 2; }

bad=0 checked=0 exempt=0
while read -r sha; do
  [ -n "$sha" ] || continue
  who=$(git log -1 --format='%an <%ae>' "$sha")
  if printf '%s' "$who" | grep -qiE '\[bot\]|dependabot|renovate'; then exempt=$((exempt + 1)); continue; fi
  checked=$((checked + 1))
  if ! git log -1 --format=%B "$sha" | git interpret-trailers --parse | grep -qE '^Signed-off-by: .+ <[^<>[:space:]]+@[^<>[:space:]]+>$'; then
    echo "::error title=Missing DCO sign-off::$(git log -1 --format='%h %s' "$sha")"
    echo "UNSIGNED  $(git log -1 --format='%h  %an <%ae>  %s' "$sha")"
    bad=$((bad + 1))
  fi
done < <(git rev-list --no-merges "$base..$head")

if [ "$bad" -gt 0 ]; then
  cat <<MSG

DCO check failed: $bad commit(s) have no "Signed-off-by: Your Name <you@example.org>" line.
Hobnix asks every contributor to certify the Developer Certificate of Origin (https://developercertificate.org/) by signing off each commit.

Fix the last commit:      git commit --amend -s --no-edit
Fix every PR commit:      git rebase --signoff $base   (then: git push --force-with-lease)
Sign future commits:      git commit -s
Details: CONTRIBUTING.md, section "Sign your commits (DCO)".
MSG
  exit 1
fi
echo "DCO check passed: $checked commit(s) signed off, $exempt bot commit(s) exempt (merge commits are not checked)."
