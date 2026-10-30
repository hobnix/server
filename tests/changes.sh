#!/usr/bin/env bash
# hs changes and the changelog validator (scripts/lib/changelog.py) against a throwaway Git repository. No root, no network.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test
G="git -c user.name=t -c user.email=t@t -c commit.gpgsign=false"
REPO=$WORK/repo; STATE=$WORK/state; mkdir -p "$REPO/docs/changelog" "$STATE"
export HS_REPO=$REPO HS_STATE_DIR=$STATE
CL="python3 -I $SCRIPTS/lib/changelog.py"
C="bash $SCRIPTS/changes.sh"
TAB=$'\t'

entry() {   # entry <date> <slug> <type> <title> [extra toml lines...]
  local d=$1 s=$2 ty=$3 ti=$4; shift 4
  { printf 'date = "%s"\ntype = "%s"\ntitle = "%s"\n' "$d" "$ty" "$ti"; [ $# -eq 0 ] || printf '%s\n' "$@"; } > "$REPO/docs/changelog/$d-$s.toml"
}
commit() { ( cd "$REPO" && $G add -A && $G commit -q -m "$1" ); }
head_rev() { git -C "$REPO" rev-parse HEAD; }

printf '# Guide\n\n## Update with a safety net\n\ntext\n' > "$REPO/docs/guide.md"
mkdir -p "$REPO/docs"; git init -q "$REPO"

# validate: the good case and each rule
entry 2026-10-01 good feature "A good entry" 'docs = "guide#update-with-a-safety-net"' 'body = "one"'
check_out "validate: good entry" "^1 changelog entries ok" $CL validate "$REPO"
chk_bad() {   # chk_bad <what> <file part> <toml text>
  local f="$REPO/docs/changelog/$2.toml"
  printf '%s\n' "$3" > "$f"
  check_out "validate: $1" "$2.toml: " $CL validate "$REPO"
  $CL validate "$REPO" >/dev/null 2>&1 && fail "validate: $1 exits 1" || pass "validate: $1 exits 1"
  rm -f "$f"
}
chk_bad "bad type" 2026-10-02-bad 'date = "2026-10-02"
type = "oops"
title = "x"'
chk_bad "date mismatch" 2026-10-02-mismatch 'date = "2026-10-03"
type = "fix"
title = "x"'
chk_bad "unknown key" 2026-10-02-key 'date = "2026-10-02"
type = "fix"
title = "x"
extra = "y"'
chk_bad "missing guide" 2026-10-02-guide 'date = "2026-10-02"
type = "fix"
title = "x"
docs = "nope"'
chk_bad "bad anchor" 2026-10-02-anchor 'date = "2026-10-02"
type = "fix"
title = "x"
docs = "guide#nope"'
chk_bad "bad file name" 2026-10-02-Bad_Name 'date = "2026-10-02"
type = "fix"
title = "x"'
chk_bad "CR in the title" 2026-10-02-cr 'date = "2026-10-02"
type = "fix"
title = "a\rb"'
chk_bad "U+2028 in the title" 2026-10-02-ls 'date = "2026-10-02"
type = "fix"
title = "a b"'
chk_bad "form feed in the body" 2026-10-02-ff 'date = "2026-10-02"
type = "fix"
title = "x"
body = "a\fb"'
chk_bad "CR in the body" 2026-10-02-bcr 'date = "2026-10-02"
type = "fix"
title = "x"
body = "a\rb"'
check_out "validate: the real tree" "changelog entries ok" $CL validate "$ROOT"

# --list --all
entry 2026-10-05 second fix "Second" 'body = """
First paragraph.

Second paragraph.
"""'
entry 2026-10-05 alpha change "Alpha same day"
commit one
H=$(head_rev)
out=$($C --list --all)
check_eq "list --all: range line" "range${TAB}-${TAB}${H}${TAB}all" "$(sed -n 1p <<<"$out")"
check_eq "list --all: newest first" "2026-10-05-second 2026-10-05-alpha 2026-10-01-good" "$(grep '^entry' <<<"$out" | cut -f2 | tr '\n' ' ' | sed 's/ $//')"
check_eq "list --all: empty docs and body are -" "entry${TAB}2026-10-05-alpha${TAB}2026-10-05${TAB}change${TAB}Alpha same day${TAB}-${TAB}-" "$(grep 'alpha' <<<"$out")"
check_out "list --all: body newlines become \n" 'First paragraph\.\\n\\nSecond paragraph\.$' printf '%s\n' "$out"

# stamp with prev: commit B adds 2 entries
A=$H
entry 2026-10-06 b1 feature "B one"
entry 2026-10-07 b2 fix "B two"
commit two
printf 'rev=%s\nprev=%s\ndirty=0\n' "$(head_rev)" "$A" > "$STATE/last-rebuild-rev"
out=$($C --list)
check_eq "update: range line" "range${TAB}${A}${TAB}$(head_rev)${TAB}update" "$(sed -n 1p <<<"$out")"
check_eq "update: exactly the 2 new entries" "2026-10-07-b2 2026-10-06-b1" "$(grep '^entry' <<<"$out" | cut -f2 | tr '\n' ' ' | sed 's/ $//')"
check_eq "update: --count" "2" "$($C --count)"
check_out "update: human output" "Changes since the last update" $C
check_out "update: human table" "B two" $C
check_eq "from: same selection" "2" "$($C --count --from "${A:0:10}")"
# rolled back: the checkout (commit three) is ahead of the running revision (stamp rev), its entry is not running
B=$(head_rev)
entry 2026-10-08 c1 fix "C one, rolled back"
commit three
printf 'rev=%s\nprev=%s\n' "$B" "$A" > "$STATE/last-rebuild-rev"
out=$($C --list)
check_eq "rolled back: range ends at the running revision" "range${TAB}${A}${TAB}${B}${TAB}update" "$(sed -n 1p <<<"$out")"
check_eq "rolled back: the rolled-back entry is not listed" "2026-10-07-b2 2026-10-06-b1" "$(grep '^entry' <<<"$out" | cut -f2 | tr '\n' ' ' | sed 's/ $//')"
check_eq "rolled back: --count" "2" "$($C --count)"
printf 'rev=%s\nprev=%s\n' "$(head_rev)" "$(head_rev)" > "$STATE/last-rebuild-rev"
check_eq "nothing new: count 0" "0" "$($C --count)"
check_out "nothing new: message" "Nothing new since the last update" $C

# fallbacks
U=$(printf '0%.0s' {1..40})
out=$($C --list --from "$U")
check_eq "unknown --from: mode newest" "range${TAB}-${TAB}$(head_rev)${TAB}newest" "$(sed -n 1p <<<"$out")"
rm -f "$STATE/last-rebuild-rev"
check_eq "no stamp: mode newest" "newest" "$($C --list | sed -n 1p | cut -f4)"
check_out "no stamp: note" "No earlier update recorded" $C
for i in $(seq 1 12); do entry "2026-11-$(printf '%02d' "$i")" "n$i" feature "N $i"; done
commit many
check_eq "no stamp: at most 10 entries" "10" "$($C --count)"

# --since and bad arguments
check_eq "since filters by date" "2" "$($C --count --since 2026-11-11)"
check_eq "since: range line" "range${TAB}2026-11-11${TAB}$(head_rev)${TAB}since" "$($C --list --since 2026-11-11 | sed -n 1p)"
check_out "a bad --since" "not a date" $C --since 2026-13-45
check_out "a bad --since (text)" "not a date" $C --since yesterday
check_out "a bad --from" "not a revision" $C --from nonsense
check_out "an unknown option" "usage: hs changes" $C --nope
bash "$SCRIPTS/changes.sh" --nope >/dev/null 2>&1; check_eq "an unknown option exits 1" "1" "$?"

# no .git: head -, mode newest
NOGIT=$WORK/nogit; mkdir -p "$NOGIT"
check_eq "no .git: range line" "range${TAB}-${TAB}-${TAB}newest" "$(HS_REPO=$NOGIT HS_CHANGELOG_DIR=$REPO/docs/changelog $C --list | sed -n 1p)"

# the stamp: write_stamp keeps prev
check "rebuild.sh writes prev=" grep -q "prev=%s" "$SCRIPTS/rebuild.sh"

finish
