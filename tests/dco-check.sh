#!/usr/bin/env bash
# scripts/dev/dco-check.sh: which commits need a sign-off. And the steps of CONTRIBUTING.md that sign off a branch afterwards, run as
# written there. Throwaway repositories only. No root, no network.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

CHECK=$SCRIPTS/dev/dco-check.sh
GUIDE=$SCRIPTS/../CONTRIBUTING.md
export GIT_CONFIG_GLOBAL=$WORK/gitconfig GIT_CONFIG_NOSYSTEM=1
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
cd "$WORK" || exit 1   # nothing below reads the repository the test is run from
git config --global user.name "Per Son"
git config --global user.email "per@example.org"
git config --global init.defaultBranch develop
git config --global core.autocrlf false

commit() {   # commit <file> <git commit args...>: one new file, one commit
  local file=$1; shift
  echo "$file" > "$file"; git add "$file"; git commit -q "$@"
}
run() { RC=0; OUT=$(bash "$CHECK" "$@" 2>&1) || RC=$?; }

git init -q "$WORK/check"; cd "$WORK/check" || exit 1
# every git call below has to stay in the throwaway repository
[ "$(git rev-parse --git-dir)" = .git ] || { echo "FAIL not in the throwaway repository"; exit 1; }
commit start -m start
start=$(git rev-parse HEAD)
expect() {   # expect "what" exit-code commit-args...: one commit on top of the start, then the check
  local what=$1 code=$2; shift 2
  git reset -q --hard "$start"
  commit file "$@"
  run "$start"
  check_eq "$what" "$code" "$RC"
}

echo "sign-off"
expect "signed passes" 0 -s -m signed
expect "unsigned fails" 1 -m unsigned
check_match "and is named" 'UNSIGNED .* unsigned' "$OUT"
expect "a sign-off without an email fails" 1 -m "x" -m "Signed-off-by: Per Son"
expect "signed below a --- line passes" 0 -s -m "x" -m "---" -m "more text"

echo "bots"
for bot in "dependabot[bot] <49699333+dependabot[bot]@users.noreply.github.com>" \
           "github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>"; do
  expect "exempt: ${bot%% *}" 0 -m bump --author "$bot"
  check_match "counted as a bot: ${bot%% *}" '1 bot commit' "$OUT"
done
for other in "claude[bot] <1+claude[bot]@users.noreply.github.com>" \
             "claude[bot] <49699333+dependabot[bot]@users.noreply.github.com>" \
             "dependabot[bot] <per@example.org>" \
             "dependabot <49699333+dependabot[bot]@users.noreply.github.com>" \
             "renovate[bot] <29139614+renovate[bot]@users.noreply.github.com>" \
             "my github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>"; do
  expect "not exempt: $other" 1 -m work --author "$other"
done

echo "usage"
run
check_eq "no base" 2 "$RC"
run no-such-commit
check_eq "an unknown base" 2 "$RC"

echo "the sign-off steps of CONTRIBUTING.md"
tr -d '\r' < "$GUIDE" | awk '/tests\/dco-check\.sh runs the next block/ { want = 1; next }
     want && /^  ```bash$/ { on = 1; want = 0; next }
     on && /^  ```$/ { exit }
     on { sub(/^  /, ""); print }' > "$WORK/steps.sh"
check_match "the block is found" 'filter-branch' "$(cat "$WORK/steps.sh")"
steps() {   # steps <base>: the block with the base branch set
  RC=0; OUT=$(sed "s/^base=develop\$/base=$1/" "$WORK/steps.sh" | bash 2>&1) || RC=$?
}
history() { git log --topo-order --format='%T %an <%ae> %ad %s' "$1..HEAD"; }   # what has to stay of every commit

for base in develop main; do
  repo=$WORK/steps-$base
  git init -q --bare "$repo.git"
  git init -q "$repo"; cd "$repo" || exit 1
  [ "$(git rev-parse --git-dir)" = .git ] || { echo "FAIL not in the throwaway repository"; exit 1; }
  git remote add origin "$repo.git"
  echo one > shared; git add shared; git commit -q -m "base start"
  git branch -q -M "$base"
  git push -q -u origin "$base"
  git switch -q -c feature/x
  echo branch > shared; git commit -q -am "branch change" --author "claude[bot] <1+claude[bot]@users.noreply.github.com>"
  commit signed -s -m "signed already"
  commit other -m "signed by another" -m "Signed-off-by: Other One <other@example.org>"
  commit both -m "own sign-off is not last" -m "Signed-off-by: Per Son <per@example.org>
Signed-off-by: Other One <other@example.org>"
  # the base moves on, the branch merges it and solves the conflict in the merge
  git switch -q "$base"; echo base > shared; git commit -q -am "base change"; git push -q origin "$base"
  merged=$(git rev-parse HEAD)
  git switch -q feature/x
  git merge -q "$base" >/dev/null 2>&1; echo solved > shared; git add shared; git commit -q -m "merge the base"
  commit after -m "after the merge" -m "---" -m "text below a line"
  git push -q -u origin feature/x
  # the base moves again and the local copy of origin/<base> is stale until the steps fetch
  git switch -q "$base"; commit later -m "base later"; git push -q origin "$base"
  base_before=$(git rev-parse HEAD)
  git update-ref "refs/remotes/origin/$base" "$merged"
  git switch -q feature/x

  tree_before=$(git rev-parse 'HEAD^{tree}')
  merge=$(git rev-list --merges "$base..HEAD")
  merge_msg=$(git log -1 --format=%B "$merge")
  history_before=$(history "$base")
  run "$base"
  check_eq "$base: unsigned before the steps" 1 "$RC"

  steps "$base"
  check_eq "$base: the steps work" 0 "$RC"
  check_eq "$base: the tree of HEAD is unchanged" "$tree_before" "$(git rev-parse 'HEAD^{tree}')"
  check_eq "$base: trees, authors, dates and subjects are unchanged" "$history_before" "$(history "$base")"
  merge_now=$(git rev-list --merges "$base..HEAD")
  check_eq "$base: one merge commit" 1 "$(grep -c . <<<"$merge_now")"
  check_eq "$base: with two parents" 2 "$(git log -1 --format=%P "$merge_now" | wc -w | tr -d ' ')"
  check_eq "$base: its second parent is the same base commit" "$merged" "$(git rev-parse "$merge_now^2")"
  check_eq "$base: its message is unchanged" "$merge_msg" "$(git log -1 --format=%B "$merge_now")"
  check_eq "$base: five commits that are not merges" 5 "$(git rev-list --count --no-merges "$base..HEAD")"
  for sha in $(git rev-list --no-merges "$base..HEAD"); do
    check_eq "$base: signed once: $(git log -1 --format=%s "$sha")" 1 \
      "$(git log -1 --format=%B "$sha" | grep -cx 'Signed-off-by: Per Son <per@example.org>')"
  done
  check_eq "$base: the base branch is untouched" "$base_before $base_before" \
    "$(git rev-parse "$base") $(git rev-parse "origin/$base")"
  check_eq "$base: pushed" "$(git rev-parse HEAD)" "$(git --git-dir="$repo.git" rev-parse feature/x)"
  run "$base"
  check_eq "$base: the check passes after the steps" 0 "$RC"
  head=$(git rev-parse HEAD)
  steps "$base"
  check_eq "$base: a second run works" 0 "$RC"
  check_eq "$base: and changes nothing" "$head" "$(git rev-parse HEAD)"
done

finish
