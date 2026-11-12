#!/usr/bin/env bash
# scripts/dev/release-gate.sh: what the release workflow checks before it tags, and the signature check after signing (the check `hs update`
# uses, uc_verify). A local bare repository stands in for GitHub; a fake `gh` answers the ci-ok question.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
have git || { skip "needs git"; finish; exit 0; }
have ssh-keygen || { skip "needs ssh-keygen"; finish; exit 0; }
export HS_LANG=en HS_PLAIN=1 GITHUB_REPOSITORY=hobnix/server
GATE="bash $SCRIPTS/dev/release-gate.sh"
ssh-keygen -q -t ed25519 -N '' -f "$WORK/good" -C test >/dev/null
ssh-keygen -q -t ed25519 -N '' -f "$WORK/evil" -C test >/dev/null
printf '#!/bin/sh\necho "${FAKE_CI:-success}"\n' > "$WORK/gh"; chmod +x "$WORK/gh"
export HS_GATE_GH=$WORK/gh
git init -q --bare "$WORK/remote.git"
R=$WORK/repo; mkdir -p "$R"; cd "$R" || exit 1
git init -q -b main . && git config user.email t@t && git config user.name t && git config commit.gpgsign false
git remote add origin "$WORK/remote.git"
mkdir -p docs/changelog config/trusted-keys
cp "$ROOT"/docs/changelog/2026-10-28-edit-users-groups.toml docs/changelog/
printf 'release@test namespaces="git" %s\n' "$(cut -d' ' -f1,2 "$WORK/good.pub")" > config/trusted-keys/server.allowed_signers
git add -A && git commit -q -m base && git push -q origin main
# a release pull request: a branch, then a merge commit on main
mkrel() {   # mkrel <notes file text>: merges a release branch into main with a merge commit
  git checkout -q -b rel/x main; printf '%s\n' "$1" > docs/RELEASE-NOTES-0.1.md; git add -A; git commit -q -m "notes"
  git checkout -q main; git merge -q --no-ff -m "Merge release" rel/x; git branch -q -D rel/x; git push -q origin main
}
mkrel "# Hobnix 0.1.0 release notes"
gate() { $GATE "$@" 2>&1; }
sign() { RELEASE_SIGNING_KEY=$(cat "$WORK/${KEY:-good}") $GATE sign "$@" 2>&1; }

echo "-- check"
check_out "a good release passes" "ci-ok is green" gate check v0.1.0
git push -q origin main:refs/heads/0.1
check_out "a beta passes on the tip of its milestone branch (no merge commit needed)" "tip of the milestone branch" gate check v0.1.0-beta.1
check_out "a bad version is refused" "Name a version" gate check 0.1.0
check_out "a version with a prefix is refused" "Name a version" gate check v0.1.0-rc.1
check_out "ci that is not green is refused" "ci-ok is not green" env FAKE_CI=failure $GATE check v0.1.0
check_out "ci is not asked when skipped (not on GitHub)" "not checked" env -u GITHUB_ACTIONS HS_GATE_CI=skip $GATE check v0.1.0
check_out "skipping ci is refused on GitHub" "not allowed on GitHub" env HS_GATE_CI=skip GITHUB_ACTIONS=true $GATE check v0.1.0
check_out "a commit that is not the tip of main is refused" "not the tip" gate check v0.1.0 --sha HEAD~1
git checkout -q -b plain main; echo x > x; git add -A; git commit -q -m plain; git checkout -q main; git merge -q --ff-only plain; git push -q origin main
check_out "a main that ends in a plain commit is refused" "not a merge commit" gate check v0.1.0
git reset -q --hard HEAD~1; git push -q -f origin main
git checkout -q -b rel/y main; rm docs/RELEASE-NOTES-0.1.md; git add -A; git commit -q -m "no notes"; git checkout -q main; git merge -q --no-ff -m "Merge nonotes" rel/y; git push -q origin main
check_out "a release without notes is refused" "RELEASE-NOTES-0.1.md is not on main" gate check v0.1.0
git reset -q --hard HEAD~1; git push -q -f origin main
git checkout -q -b rel/z main; echo "# Hobnix 0.2.0" > docs/RELEASE-NOTES-0.1.md; git add -A; git commit -q -m other; git checkout -q main; git merge -q --no-ff -m "Merge other" rel/z; git push -q origin main
check_out "notes for another release are refused" "do not name 0.1" gate check v0.1.0
git reset -q --hard HEAD~1; git push -q -f origin main

echo "-- sign"
check_out "signs and passes the hs update check" "passes the check hs update uses" sign v0.1.0
check_eq "the tag is annotated and on main" "tag" "$(git cat-file -t v0.1.0)"
git push -q origin v0.1.0
check_out "an existing tag is refused" "exists already" gate check v0.1.0
check_out "an empty key is refused" "RELEASE_SIGNING_KEY is empty" env RELEASE_SIGNING_KEY= $GATE sign v0.1.1
KEY=evil sign v0.1.1 >"$WORK/evil.out"
check_out "a key that is not in server.allowed_signers is refused" "does not verify" cat "$WORK/evil.out"
check_eq "and its tag is deleted" "" "$(git tag -l v0.1.1)"
check_out "a key that is not a key is refused" "not an unencrypted OpenSSH" env RELEASE_SIGNING_KEY=garbage $GATE sign v0.1.1

echo "-- order of versions"
git checkout -q -b hot main; echo fix > fix.txt; git add -A; git commit -q -m fix; git checkout -q main; git merge -q --no-ff -m "Merge hotfix" hot; git push -q origin main
check_out "a hotfix tag is the next patch" "next version after v0.1.0" gate check v0.1.1
check_out "a lower version is refused" "not above the newest stable" gate check v0.0.9
git push -q origin main:refs/heads/0.1; git push -q origin main:refs/heads/0.2
check_out "a beta of a released version is refused" "released already" gate check v0.1.0-beta.2
check_out "a beta of the next version passes" "next version" gate check v0.2.0-beta.1
git checkout -q -b m2 main; echo m > m.txt; git add -A; git commit -q -m m2work; git push -q origin m2:refs/heads/0.2; git checkout -q main
check_out "a beta is refused when HEAD is not the tip of its milestone branch" "not the tip of origin/0[.]2" gate check v0.2.0-beta.1
git branch -q -D m2; git push -q origin main:refs/heads/0.2 --force
check_out "a beta without its milestone branch is refused" "origin/0[.]3 is not here" gate check v0.3.0-beta.1
git tag v0.2.0-beta.3 main; check_out "an older beta number is refused" "not above the earlier beta" gate check v0.2.0-beta.2
git tag -d v0.2.0-beta.3 >/dev/null
check_out "a version that is on the remote is refused" "exists already" gate check v0.1.0
finish
