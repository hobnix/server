#!/usr/bin/env bash
# hs sys system updates: the count of new commits from refs that are already fetched. No root, no network.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=ui
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

echo "-- registry row"
check "sys system updates row" grep -q "^sys.sys system updates.system-updates.sh.-." "$SCRIPTS/lib/registry.tsv"

echo "-- no checkout"
export HS_REPO=$WORK/none
mkdir -p "$HS_REPO"
check_eq "no checkout, no commits" "$(printf 'behind\t0\nahead\t0\nupstream\t-\nfetched\t-')" "$(bash "$SCRIPTS/system-updates.sh")"

echo "-- a checkout behind its upstream"
git init -q --bare "$WORK/origin.git"
git clone -q "$WORK/origin.git" "$WORK/repo" 2>/dev/null
git -C "$WORK/repo" checkout -q -b main 2>/dev/null
git -C "$WORK/repo" commit -q --allow-empty -m one
git -C "$WORK/repo" push -q -u origin main 2>/dev/null
git clone -q -b main "$WORK/origin.git" "$WORK/other" 2>/dev/null
git -C "$WORK/other" commit -q --allow-empty -m two
git -C "$WORK/other" commit -q --allow-empty -m three
git -C "$WORK/other" push -q origin main 2>/dev/null
export HS_REPO=$WORK/repo
check_eq "not fetched yet: nothing new is known" "0" "$(bash "$SCRIPTS/system-updates.sh" | awk -F'\t' '$1=="behind"{print $2}')"
git -C "$WORK/repo" fetch -q
l=$(bash "$SCRIPTS/system-updates.sh")
check_eq "two new commits after the fetch" "2" "$(awk -F'\t' '$1=="behind"{print $2}' <<<"$l")"
check_eq "nothing ahead" "0" "$(awk -F'\t' '$1=="ahead"{print $2}' <<<"$l")"
check_eq "the upstream branch" "origin/main" "$(awk -F'\t' '$1=="upstream"{print $2}' <<<"$l")"
check_out "four rows, fetched is a number" "^fetched	[0-9]+$" echo "$(grep '^fetched' <<<"$l")"
check_eq "the read fetched nothing" "2" "$(git -C "$WORK/repo" rev-list --count HEAD..origin/main)"

finish
