#!/usr/bin/env bash
# scripts/dev/release-core.sh: milestone sync, signed core tag and its refusals, verify, follow-check. A local bare
# repository stands in for GitHub (so the ci-ok check is skipped), a fake `hs sys release show` stands in for a server.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
have git || { skip "needs git"; finish; exit 0; }
have ssh-keygen || { skip "needs ssh-keygen"; finish; exit 0; }
export HS_LANG=en HS_PLAIN=1
REL="bash $SCRIPTS/dev/release-core.sh"
ssh-keygen -q -t ed25519 -N '' -f "$WORK/good" -C test >/dev/null
ssh-keygen -q -t ed25519 -N '' -f "$WORK/evil" -C test >/dev/null
printf 'release@test namespaces="git" %s\n' "$(cut -d' ' -f1,2 "$WORK/good.pub")" > "$WORK/signers"
git init -q --bare "$WORK/remote.git"
R=$WORK/repo; mkdir -p "$R"; cd "$R" || exit 1
git init -q -b main . && git config user.email t@t && git config user.name t && git config commit.gpgsign false
git remote add origin "$WORK/remote.git"
mkdir -p docs; echo notes > docs/RELEASE-NOTES-0.1.md
git add -A && git commit -q -m base && git push -q origin main
git push -q origin main:develop; git push -q origin main:0.2
rel() { $REL "$@" 2>&1; }
tags() { git ls-remote --tags origin | grep -v '\^{}' | sed 's#.*refs/tags/##' | sort | paste -sd' ' -; }
land() {   # land <branch> <text>: a commit on a remote branch
  git fetch -q origin; git checkout -q -B tmp "origin/$1"; echo "$2" >> "f-$1.txt" 2>/dev/null || echo "$2" >> "f-${1//\//-}.txt"
  git add -A; git commit -q -m "$2"; git push -q origin "tmp:$1"; git checkout -q main
}

echo "-- sync"
check_out "in step: nothing to do" "already holds" rel sync --yes
land develop "fix one"
check_out "status says 0.2 is behind" "0[.]2 is missing 1" rel status
check_out "sync pushes a merge branch" "chore/sync-develop-into-0.2-.* pushed" rel sync --yes
br=$(git ls-remote --heads origin 'chore/sync-*' | sed 's#.*refs/heads/##' | head -n1)
check_eq "the merge is a merge commit holding develop" "2" "$(git fetch -q origin && git log -1 --format=%p "origin/$br" | wc -w)"
check_eq "the checkout was not moved" "main" "$(git branch --show-current)"
check_eq "no temporary worktree is left" "1" "$(git worktree list | wc -l)"
git push -q origin ":refs/heads/$br"
land 0.2 "feature on 0.2"; land develop "conflict"; echo a > clash.txt
git fetch -q origin; git checkout -q -B tmp origin/develop; echo develop > clash.txt; git add -A; git commit -q -m c1; git push -q origin tmp:develop
git checkout -q -B tmp origin/0.2; echo milestone > clash.txt; git add -A; git commit -q -m c2; git push -q origin tmp:0.2; git checkout -q main
check_out "a conflict stops and says so" "conflicts" rel sync --yes
check_eq "and pushed no branch" "" "$(git ls-remote --heads origin 'chore/sync-*')"

echo "-- tag"
check_out "a bad name is refused" "Name a release tag" rel tag 0.1.0 --yes
check_out "a malformed beta name is refused" "Name a release tag" rel tag v0.1.0-beta.0 --yes
git fetch -q origin; git checkout -q -B tmp origin/main
mkdir -p config/trusted-keys; cp "$WORK/signers" config/trusted-keys/server.allowed_signers; git add -A; git commit -q -m "release 0.1"; git push -q origin tmp:main; git checkout -q main
check_out "a key that is not trusted is refused" "does not verify" rel tag v0.1.0 --yes --key "$WORK/evil.pub"
check_eq "and no tag is left, here or there" "" "$(tags)$(git tag -l)"
check_out "a missing key is refused" "does not exist" rel tag v0.1.0 --yes --key "$WORK/none.pub"
check_out "tags v0.1.0 on main" "v0[.]1[.]0 pushed" rel tag v0.1.0 --yes --key "$WORK/good.pub"
check_eq "it is on the remote" "v0.1.0" "$(tags)"
check_out "it verifies, is on main and annotated" "good signature" rel verify v0.1.0 --signers "$WORK/signers"
check_out "the same tag again is refused" "exists already" rel tag v0.1.0 --yes --key "$WORK/good.pub"
check_out "a lower tag is refused" "not above" rel tag v0.0.9 --yes --key "$WORK/good.pub"
check_out "a beta for the released version is refused" "released already" rel tag v0.1.0-beta.1 --yes --key "$WORK/good.pub"
check_out "a beta without release notes on main is refused" "RELEASE-NOTES-0[.]2[.]md is not on" rel tag v0.2.0-beta.1 --yes --key "$WORK/good.pub"
git fetch -q origin; git checkout -q -B tmp origin/main; mkdir -p docs; echo "# 0.2" > docs/RELEASE-NOTES-0.2.md; git add -A; git commit -q -m "notes 0.2"; git push -q origin tmp:main; git checkout -q main
check_out "a beta is accepted and pushed" "v0[.]2[.]0-beta[.]1 pushed" rel tag v0.2.0-beta.1 --yes --key "$WORK/good.pub"
check_out "it names the prerelease and no ISO" "gh release create .*--prerelease.*RELEASE-NOTES-0[.]2[.]md" rel tag v0.2.0-beta.3 --yes --key "$WORK/good.pub"
check_out "a beta number not above the earlier ones is refused" "not above the earlier beta" rel tag v0.2.0-beta.2 --yes --key "$WORK/good.pub"
check_eq "only the pushed betas are on the remote" "v0.1.0 v0.2.0-beta.1 v0.2.0-beta.3" "$(tags)"
check_out "a beta verifies" "good signature" rel verify v0.2.0-beta.3 --signers "$WORK/signers"
git tag -d v0.1.0 >/dev/null; git fetch -q origin --tags
check_out "a tag off main fails verify" "not on main" bash -c "git checkout -q -B t2 origin/develop && git -c gpg.format=ssh -c user.signingkey=$WORK/good.pub tag -s v0.1.1 -m x && git checkout -q main; $REL verify v0.1.1 --signers $WORK/signers; true"
git tag -d v0.1.1 >/dev/null
check_out "status shows the release" "Newest stable +v0[.]1[.]0" rel status
check_out "and that main is not on develop yet" "not on develop" rel status

echo "-- follow-check"
fake() { printf '#!/bin/sh\nprintf "channel\\t%s\\ninstalled\\t%s\\noffer\\tstable\\t%s\\tupdate\\nref\\t%s\\nstate\\t%s\\nsigned\\t%s\\n"\n' "$1" "$2" "$3" "$3" "$4" "$5" > "$WORK/show"; chmod +x "$WORK/show"; }
fc() { HS_RELEASE_SHOW="$WORK/show" $REL follow-check "$@"; }
fake stable abc1234 v0.1.0 update yes
check_out "before the update: ready, not yet followed" "Not yet: run hs update" fc v0.1.0
check "--after fails before the update" bash -c "! HS_RELEASE_SHOW=$WORK/show $REL follow-check v0.1.0 --after >/dev/null 2>&1"
fake stable v0.1.0 v0.1.0 current yes
check_out "after the update: followed" "follows stable" fc v0.1.0 --after
fake beta v0.1.0 v0.1.0 current yes
check_out "the wrong channel is reported" "not stable" fc v0.1.0
fake stable abc1234 - none -
check_out "no tag offered is reported" "no release tag yet" fc v0.1.0
fake stable abc1234 v0.1.0 update no
check_out "an unsigned tag is reported" "not verified" fc v0.1.0
fake stable v0.0.9 v0.0.9 current yes
check_out "a different tag than expected is reported" "expected v0.1.0" fc v0.1.0
finish
