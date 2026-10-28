#!/usr/bin/env bash
# hs disk <member> move (scripts/disk-move.sh, routed by disk-change.sh): a folder from one data disk to another, disk to disk. Folders stand in for
# mounted disks (HS_MOVE_TEST=1); rsync is the real one. No root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en HS_CALLER=ui
unset HS_GUIDED_TTY
T=$'\t'
export HS_BULK_BASE=$WORK/base HS_STATE_DIR=$WORK/state HS_MOVE_TEST=1 HS_LOCK=$WORK/lock HS_LOCK_ADMIN=$WORK/admin HS_BULK_CLOSED=$WORK/state/bulk-closed
B=$HS_BULK_BASE
mkdir -p "$B"/data-04 "$B"/data-05 "$B"/data-06 "$B"/data-07 "$HS_STATE_DIR"
echo data-06 > "$HS_BULK_CLOSED"
S=$B/data-04/shares/media/movies
mkdir -p "$S/Avatar" "$S/Heat" "$B/data-04/sensitive/secret"
head -c 300000 /dev/urandom > "$S/Avatar/Avatar.mkv"; echo poster > "$S/Avatar/poster jpg"; head -c 1000 /dev/urandom > "$S/Heat/Heat.mkv"
echo s > "$B/data-04/sensitive/secret/key"
( cd "$B/data-04" && find shares -type f -exec md5sum {} + | sort -k2 ) > "$WORK/before.md5"
run() { rc=0; out=$(timeout 60 bash "$SCRIPTS/disk-move.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }
runc() { rc=0; out=$(timeout 60 bash "$SCRIPTS/disk-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }

echo "-- plan"
run plan data-04 --path shares/media/movies/Avatar
check_eq "plan: exit 0" 0 "$rc"
has "^status${T}ok$" && has "^heading${T}move shares/media/movies/Avatar (.*) from data-04 to data-0[57]$" && has "^step${T}copy the files from data-04 to data-0[57] with the same path" && has "^long${T}no$" \
  && pass "plan: status, heading, steps, short" || fail "plan: $out"
has "^target${T}data-0[57]$" && pass "a closed disk (data-06) is never picked" || fail "target: $out"
run plan data-04 --path shares/media/movies/Avatar --to data-05
has "^target${T}data-05$" && pass "--to names the target" || fail "--to: $out"
runc plan move data-04 --path shares/media/movies/Avatar --to data-05
check_eq "disk-change.sh routes move" 0 "$rc"

echo "-- refusals"
run plan data-04 --path shares/media/movies/Avatar --to data-06
check_eq "a closed target" 1 "$rc"; has "is closed" && pass "says closed" || fail "closed: $out"
run plan data-04 --path shares/media/movies/Avatar --to data-04
check_eq "the same disk" 1 "$rc"
run plan data-04 --path shares/media/nothing
check_eq "a path that does not exist" 1 "$rc"
run plan data-04 --path ../data-05/shares
check_eq "no .. in the path" 1 "$rc"
run plan data-04 --path shares/../../etc
check_eq "no .. in the middle" 1 "$rc"
run plan data-04 --path /etc/passwd
check_eq "no absolute path" 1 "$rc"
run plan data-04 --path lost+found
check_eq "only shares/ and sensitive/" 1 "$rc"
run plan data-04
check_eq "a path is needed" 1 "$rc"
run plan data-99 --path shares/x
check_eq "an unknown disk" 1 "$rc"
run plan sda --path shares/x
check_eq "only data-NN" 1 "$rc"
ln -s "$B/data-05" "$B/data-04/shares/media/link"
run plan data-04 --path shares/media/link
check_eq "a link is refused" 1 "$rc"
mkdir -p "$HS_STATE_DIR/recovering"; : > "$HS_STATE_DIR/recovering/data-07"
run plan data-04 --path shares/media/movies/Avatar --to data-07
check_eq "a disk out for a recovery is no target" 1 "$rc"
rm -f "$HS_STATE_DIR/recovering/data-07"

echo "-- ls (for the interface)"
run ls data-04
[ "$out" = "$(printf 'd\t\tshares\nd\t\tsensitive')" ] && pass "no path: shares and sensitive" || fail "ls top: $out"
run ls data-04 --path shares/media/movies
[ "$out" = "$(printf 'd\t\tAvatar\nd\t\tHeat')" ] && pass "folders of a folder" || fail "ls: $out"
run ls data-04 --path shares/media/movies/Avatar
has "^f${T}300000${T}Avatar.mkv$" && has "^f${T}[0-9]*${T}poster jpg$" && pass "files with size, names with spaces" || fail "ls files: $out"
run ls data-04 --path ../x
check_eq "ls refuses .." 1 "$rc"

echo "-- the move (start --now)"
mkdir -p "$B/data-05/shares/media/movies/Avatar"; echo "other copy" > "$B/data-05/shares/media/movies/Avatar/poster jpg"   # already there: never overwritten
run start data-04 --path shares/media/movies/Avatar --to data-05 --now
check_eq "start --now: exit 0" 0 "$rc"
has "^status${T}done$" && has "^left${T}1$" && pass "done, one file stayed (the name exists on the target)" || fail "start: $out"
[ -f "$B/data-05/shares/media/movies/Avatar/Avatar.mkv" ] && cmp -s "$B/data-05/shares/media/movies/Avatar/Avatar.mkv" <(cd "$B" && cat data-05/shares/media/movies/Avatar/Avatar.mkv) \
  && pass "the file is on the target at the same path" || fail "no file on the target"
[ "$(md5sum < "$B/data-05/shares/media/movies/Avatar/Avatar.mkv")" = "$(grep ' shares/media/movies/Avatar/Avatar.mkv$' "$WORK/before.md5" | cut -d' ' -f1)  -" ] && pass "same content (md5)" || fail "md5 differs"
[ ! -e "$S/Avatar/Avatar.mkv" ] && pass "the moved file is gone from the source disk" || fail "still on the source"
[ "$(cat "$B/data-05/shares/media/movies/Avatar/poster jpg")" = "other copy" ] && pass "an existing file on the target is not overwritten" || fail "overwritten!"
[ -f "$S/Avatar/poster jpg" ] && pass "the skipped file stays on the source" || fail "skipped file lost"
[ -f "$S/Heat/Heat.mkv" ] && pass "other folders are untouched" || fail "Heat lost"
run start data-04 --path shares/media/movies/Heat --to data-05 --now
has "^left${T}0$" && [ ! -e "$S/Heat" ] && [ -f "$B/data-05/shares/media/movies/Heat/Heat.mkv" ] && pass "a folder that moves completely leaves nothing behind" || fail "Heat: $out"
run start data-04 --path sensitive/secret/key --to data-05 --now
[ -f "$B/data-05/sensitive/secret/key" ] && [ ! -e "$B/data-04/sensitive/secret/key" ] && pass "a single file in sensitive/ moves with its folders" || fail "file move: $out"

echo "-- the pieces around it"
grep -q '^user	disk <disk> move	disk-move.sh' "$SCRIPTS/lib/registry.tsv" && grep -q '^sys	sys disk ls <member>	disk-move.sh' "$SCRIPTS/lib/registry.tsv" && pass "registry rows" || fail "registry rows"
grep -q 'r"^move$"' "$SCRIPTS/web-serve.py" && grep -q '("disk", "ls")' "$SCRIPTS/web-serve.py" && pass "web CHANGES and READS allowlists" || fail "web allowlists"

finish
