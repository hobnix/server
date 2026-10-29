#!/usr/bin/env bash
# hs sys fm ... (scripts/fm.sh, scripts/lib/fm.sh): the backend of the two-pane file manager. Folders stand in for the locations (HS_FM_TEST=1);
# nothing here runs on real mergerfs or ZFS (docs/PLAN-file-manager.md section 7 has the VM test plan). No root needed.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en HS_CALLER=ui
unset HS_GUIDED_TTY
have flock || { echo "flock is missing"; exit 77; }
T=$'\t'
B=$WORK/base
export HS_FM_TEST=1 HS_FM_SYNC=1 HS_FM_MARGIN=0 HS_FM_NO_RENAME=1 HS_STATE_DIR=$WORK/state HS_FM_DIR=$WORK/state/fm HS_DISKS_ROOT=$B/disks HS_DETACHED_ROOT=$B/detached \
  HS_FM_POOL_ROOT=$B/pool HS_FM_CACHE_ROOT=$B/cache HS_FM_TEMP_ROOT=$B/temp HS_FM_FAST_ROOT=$B/fast HS_BULK_TYPE_FILE=$WORK/bulk-type \
  HS_LOCK=$WORK/lock HS_LOCK_ADMIN=$WORK/admin HS_BULK_CLOSED=$WORK/state/bulk-closed HS_CAPABILITIES_FILE=$WORK/caps HS_LOCKED_MARKER=$WORK/locked-marker
echo snapraid > "$HS_BULK_TYPE_FILE"; echo storage > "$HS_CAPABILITIES_FILE"
mkdir -p "$HS_STATE_DIR/settings"; echo true > "$HS_STATE_DIR/settings/fileManagerWrite"     # the write switch is on for the tests below; "the write switch" block tests it off
mkdir -p "$B"/disks/data-04 "$B"/disks/data-05 "$B"/disks/data-06 "$B"/disks/data-07 "$B"/detached/data-08 "$B"/pool "$B"/cache "$B"/temp/usb "$B"/fast "$HS_STATE_DIR/recovering"
echo data-06 > "$HS_BULK_CLOSED"; : > "$HS_STATE_DIR/recovering/data-07"
D4=$B/disks/data-04; D5=$B/disks/data-05; D6=$B/disks/data-06; P=$B/pool
mkdir -p "$D4/shares/media/movies/Avatar" "$D4/shares/media/movies/Heat" "$D4/sensitive/vault" "$D4/lost+found" "$D5/shares/media" "$P/shares/media/movies" "$P/sensitive" "$B/cache/shares"
head -c 300000 /dev/urandom > "$D4/shares/media/movies/Avatar/Avatar.mkv"; echo poster > "$D4/shares/media/movies/Avatar/poster.jpg"
head -c 1000 /dev/urandom > "$D4/shares/media/movies/Heat/Heat.mkv"; echo key > "$D4/sensitive/vault/key"
echo "data" > "$D4/shares/media/readme.txt"
echo old > "$B/temp/usb/old.txt"; mkdir -p "$B/temp/usb/photos"; echo p > "$B/temp/usb/photos/a.jpg"
cp -a "$D4/shares/media/movies/Heat" "$P/shares/media/movies/Heat"

fm() { rc=0; out=$(timeout 60 bash "$SCRIPTS/fm.sh" "$@" </dev/null 2>&1) || rc=$?; }
# fmsel name... -- args: the names go on stdin, NUL separated
fmsel() { local s=(); while [ "$1" != -- ]; do s+=("$1"); shift; done; shift; rc=0; out=$(printf '%s\0' "${s[@]}" | timeout 60 bash "$SCRIPTS/fm.sh" "$@" 2>&1) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }
reason() { awk -F'\t' '$1 == "reason" { print $2; exit }' <<<"$out"; }
kv() { awk -F'\t' -v k="$1" '$1 == k { print $2; exit }' <<<"$out"; }

echo "-- locations"
fm locations
check_eq "locations: exit 0" 0 "$rc"
has "^status${T}ok$" && pass "locations: status ok" || fail "locations: $out"
loc() { grep -- "^loc${T}$1${T}" <<<"$out" | head -n1; }
l=$(loc disk:data-04); [ "$(echo "$l" | cut -f3,8,9,10,11)" = "disk${T}yes${T}-${T}bulk${T}data-04" ] && pass "an open disk is writable" || fail "data-04: $l"
l=$(loc disk:data-06); [ "$(echo "$l" | cut -f8)" = no ] && echo "$l" | cut -f9 | grep -q closed && pass "a closed disk: not writable, reason" || fail "data-06: $l"
l=$(loc disk:data-07); [ "$(echo "$l" | cut -f8)" = no ] && echo "$l" | cut -f9 | grep -q recovery && pass "a disk out for recovery: not writable, reason" || fail "data-07: $l"
l=$(loc disk:data-08); [ "$(echo "$l" | cut -f8)" = no ] && echo "$l" | cut -f9 | grep -q detached && pass "a detached disk: not writable, reason" || fail "data-08: $l"
l=$(loc disk:data-06); [ "$(echo "$l" | cut -f8,12)" = "no${T}yes" ] && pass "a closed disk takes no files but can still be emptied (modifiable yes)" || fail "data-06: $l"
l=$(loc disk:data-08); [ "$(echo "$l" | cut -f12)" = no ] && pass "a detached disk is not modifiable" || fail "data-08 mod: $l"
l=$(loc temp:usb); [ "$(echo "$l" | cut -f3,8)" = "temp${T}no" ] && pass "a temporary disk is a source only" || fail "temp: $l"
l=$(loc pool:bulk); echo "$l" | cut -f3,10 | grep -q "pool${T}bulk" && pass "pool:bulk" || fail "pool: $l"
[ -n "$(loc cache:bulk)" ] && [ -n "$(loc share:media)" ] && [ -n "$(loc pool:fast)" ] && pass "cache, share and fast pool are listed" || fail "ids: $out"
touch "$B/disks/data-05/.fm-readonly"
fm locations; l=$(loc disk:data-05); [ "$(echo "$l" | cut -f8)" = no ] && echo "$l" | cut -f9 | grep -q read-only && pass "a read-only mount is not writable" || fail "ro: $l"
rm -f "$B/disks/data-05/.fm-readonly"
touch "$HS_LOCKED_MARKER"
fm locations; has "^locked${T}yes$" && ! has "^loc${T}" && pass "storage locked: no locations, locked yes" || fail "locked: $out"
fm ls disk:data-04; check_eq "storage locked: ls refused" 1 "$rc"
fmsel Avatar -- plan copy --from disk:data-04 --path shares/media/movies --to disk:data-05 --to-path shares/media; check_eq "storage locked: plan refused" 1 "$rc"
rm -f "$HS_LOCKED_MARKER"
echo > "$HS_CAPABILITIES_FILE"; fm locations; check_eq "no capability storage: refused" 1 "$rc"; echo storage > "$HS_CAPABILITIES_FILE"

echo "-- pair (the same-files rule)"
fm pair disk:data-04 pool:bulk;     check_eq "disk and its pool: refused" 1 "$rc"; reason | grep -q "^Same files as data-04" && pass "reason names the disk" || fail "pair reason: $out"
fm pair pool:bulk disk:data-04;     check_eq "pool and its disk: refused (other direction)" 1 "$rc"
fm pair share:media disk:data-05;   check_eq "a share of the pool and a disk: refused" 1 "$rc"
fm pair disk:data-05 share:media;   check_eq "a disk and a share: refused" 1 "$rc"
fm pair disk:data-04 disk:data-05;  check_eq "two different disks: allowed" 0 "$rc"
fm pair disk:data-04 disk:data-04;  check_eq "inside one disk: allowed" 0 "$rc"
fm pair pool:bulk share:media;      check_eq "pool and share (same view): allowed" 0 "$rc"
fm pair cache:bulk pool:bulk;       check_eq "cache and pool: allowed" 0 "$rc"
fm pair disk:data-04 temp:usb;      check_eq "disk and a temporary disk: allowed" 0 "$rc"
fm pair disk:data-04 nonsense;      check_eq "an unknown location: refused" 1 "$rc"

echo "-- ls"
fm ls disk:data-04
has "^row${T}d${T}0${T}[0-9]*${T}shares${T}-${T}array${T}-$" && has "^row${T}d${T}0${T}[0-9]*${T}sensitive${T}-${T}array${T}-$" && pass "shares and sensitive at a disk root carry flag array" || fail "root ls: $out"
has "^row${T}d${T}0${T}[0-9]*${T}lost+found${T}-${T}system${T}-$" && pass "lost+found is a system entry" || fail "lost+found: $out"
has "^end$" && pass "ls ends with end" || fail "end: $out"
fm ls disk:data-04 --path shares/media
rows=$(grep -c "^row" <<<"$out"); check_eq "ls shares/media: 2 entries" 2 "$rows"
l1=$(grep "^row" <<<"$out" | head -n1 | cut -f2,5); check_eq "folders first" "d${T}movies" "$l1"
has "^row${T}f${T}5${T}[0-9]*${T}readme.txt${T}-${T}-${T}-$" && pass "a file row: type, bytes, mtime, name, disks, flags, busy" || fail "file row: $out"
mkdir -p "$D4/many"; for i in 01 02 03 04 05; do : > "$D4/many/f$i"; done; mkdir "$D4/many/dir1"
fm ls disk:data-04 --path many --limit 2
has "^cursor${T}2$" && grep -c "^row" <<<"$out" | grep -q '^2$' && has "dir1" && pass "paging: first page of 2, a cursor" || fail "page1: $out"
fm ls disk:data-04 --path many --limit 2 --cursor 2
has "^cursor${T}4$" && has "f02" && pass "paging: next page" || fail "page2: $out"
fm ls disk:data-04 --path many --limit 2 --cursor 4
has "^end$" && has "f05" && pass "paging: the last page ends" || fail "page3: $out"
fm ls disk:data-04 --path ../data-05; check_eq "ls refuses .." 1 "$rc"
ln -s "$B/disks/data-05" "$D4/many/escape"
fm ls disk:data-04 --path many/escape; check_eq "ls refuses a link that leaves the location" 1 "$rc"
fm ls disk:data-04 --path many
has "^row${T}l${T}[0-9]*${T}[0-9]*${T}escape${T}-${T}link${T}-$" && pass "a link is listed as l with flag link" || fail "link row: $out"
fm ls disk:data-04 --path lost+found; check_eq "ls refuses to open a system entry" 1 "$rc"
BAD=$(printf 'bad\001name'); : > "$D4/many/$BAD"; : > "$D4/many/$(printf 'inv\377alid')"; : > "$D4/many/tab$(printf '\t')x"
fm ls disk:data-04 --path many
has "bad.x01name${T}-${T}badname${T}-" && pass "a control character is escaped and flagged badname" || fail "badname: $(grep bad <<<"$out" | cat -A)"
has 'inv.xffalid' && has 'tab.x09x' && pass "invalid UTF-8 and a tab are escaped too" || fail "escape: $(cat -A <<<"$out")"
fm ls pool:bulk --path shares/media/movies
has "^row${T}d${T}0${T}[0-9]*${T}Heat${T}data-04${T}-${T}-$" && pass "the pool view says which disk holds an entry" || fail "disks column: $out"
cp -a "$D4/shares/media/movies/Heat" "$D5/shares/media/movies_heat_tmp" 2>/dev/null; mkdir -p "$D5/shares/media/movies"; mv "$D5/shares/media/movies_heat_tmp" "$D5/shares/media/movies/Heat"
fm ls pool:bulk --path shares/media/movies
has "Heat${T}data-04,data-05${T}" && pass "an entry on two disks lists both" || fail "two disks: $out"
rm -rf "$D5/shares/media/movies"
fm ls pool:bulk
! grep -q "^row${T}d.*${T}-${T}-${T}-$" <<<"$out" && grep "^row" <<<"$out" | cut -f7 | grep -vq '^array$' && fail "pool root entries are all array: $out" || pass "pool top level entries are array"
# busy marks: a live job on shares/media/movies/Heat
sleep 30 & bpid=$!
mkdir -p "$HS_FM_DIR/busy"; printf 'pid\t%s\nitem\tbulk\tshares/media/movies/Heat\tmove\t34\n' "$bpid" > "$HS_FM_DIR/busy/j1"
fm ls disk:data-04 --path shares/media/movies
has "Heat${T}-${T}-${T}move:34$" && has "Avatar${T}-${T}-${T}-$" && pass "busy: the item of a running job is marked (disk view)" || fail "busy disk: $out"
fm ls pool:bulk --path shares/media/movies
has "Heat${T}.*${T}move:34$" && pass "busy: also in the pool view (the same files)" || fail "busy pool: $out"
fm ls share:media --path movies
has "Heat${T}.*${T}move:34$" && pass "busy: also in the share view" || fail "busy share: $out"
fm ls disk:data-04 --path shares/media
has "movies${T}-${T}busyparent${T}-$" && pass "busy: the parent carries busyparent" || fail "busyparent: $out"
fm ls disk:data-04
has "shares${T}-${T}array,busyparent${T}-$" && pass "busyparent reaches the root" || fail "busyparent root: $out"
kill "$bpid" 2>/dev/null; wait "$bpid" 2>/dev/null || true
fm ls disk:data-04 --path shares/media/movies
has "Heat${T}-${T}-${T}-$" && pass "a dead job leaves no mark" || fail "stale busy: $out"
rm -f "$HS_FM_DIR/busy/j1"
if [ "$(id -u)" != 0 ]; then
  mkdir -p "$D4/many/locked"; chmod 000 "$D4/many/locked"
  fm ls disk:data-04 --path many; has "locked${T}-${T}noaccess" && pass "an unreadable folder is flagged noaccess" || fail "noaccess: $out"
  chmod 755 "$D4/many/locked"
else skip "noaccess flag (running as root)"; fi
rm -rf "$D4/many"

echo "-- plan: copy disk to disk"
fmsel Avatar Heat -- plan copy --from disk:data-04 --path shares/media/movies --to disk:data-05 --to-path shares/media
check_eq "plan copy: exit 0" 0 "$rc"
has "^status${T}ok$" && has "^heading${T}copy 2 item" && has "^step${T}+ copy 3 files in 2 folders" && pass "plan copy: status, heading, step" || fail "plan copy: $out"
check_eq "plan: files" 3 "$(kv files)"; check_eq "plan: folders" 2 "$(kv folders)"; check_eq "plan: conflicts" 0 "$(kv conflicts)"
check_eq "plan: parity no for a copy" no "$(kv parity)"; check_eq "plan: long no" no "$(kv long)"; check_eq "plan: no confirm" "" "$(kv confirm_name)"
[ "$(kv bytes)" -ge 301000 ] && [ -n "$(kv free_after)" ] && pass "plan: bytes and free_after" || fail "bytes: $out"

echo "-- refusals"
fmsel Avatar -- plan copy --from disk:data-04 --path shares/media/movies --to pool:bulk --to-path shares/media
check_eq "copy disk -> its pool: refused" 1 "$rc"; reason | grep -q "^Same files as data-04" && pass "reason: same files" || fail "reason: $out"
fmsel Avatar -- start copy --from disk:data-04 --path shares/media/movies --to pool:bulk --to-path shares/media/movies
check_eq "start copy disk -> its pool: refused too" 1 "$rc"
fmsel Heat -- plan copy --from pool:bulk --path shares/media/movies --to disk:data-04 --to-path shares/media
check_eq "copy pool -> a disk of it: refused" 1 "$rc"
fmsel Heat -- plan move --from share:media --path movies --to disk:data-05 --to-path shares/media
check_eq "move share -> a disk of its pool: refused" 1 "$rc"
fmsel Avatar -- plan move --from disk:data-04 --path shares/media/movies --to disk:data-04 --to-path shares/media
check_eq "inside one disk is allowed" 0 "$rc"
fmsel Avatar -- plan copy --from disk:data-04 --path shares/media/../../sensitive --to disk:data-05 --to-path shares/media; check_eq ".. in --path" 1 "$rc"
fmsel Avatar -- plan copy --from disk:data-04 --path shares/media/movies --to disk:data-05 --to-path shares/../sensitive; check_eq ".. in --to-path" 1 "$rc"
fmsel ../Avatar -- plan copy --from disk:data-04 --path shares/media/movies --to disk:data-05 --to-path shares/media; check_eq ".. as a name" 1 "$rc"
fmsel /etc/passwd -- plan copy --from disk:data-04 --path shares/media/movies --to disk:data-05 --to-path shares/media; check_eq "an absolute name" 1 "$rc"
fmsel Avatar/Avatar.mkv -- plan copy --from disk:data-04 --path shares/media/movies --to disk:data-05 --to-path shares/media; check_eq "a name with a slash" 1 "$rc"
fmsel "$(printf 'a\001b')" -- plan delete --from disk:data-04 --path shares/media; check_eq "a control character in a name" 1 "$rc"
fmsel Avatar Avatar -- plan copy --from disk:data-04 --path shares/media/movies --to disk:data-05 --to-path shares/media; check_eq "a name twice" 1 "$rc"
fmsel -- plan copy --from disk:data-04 --path shares/media/movies --to disk:data-05 --to-path shares/media; check_eq "an empty selection" 1 "$rc"
mkdir -p "$B/outside"; echo secret > "$B/outside/s.txt"; ln -s "$B/outside" "$D4/shares/media/out"
fmsel s.txt -- plan copy --from disk:data-04 --path shares/media/out --to disk:data-05 --to-path shares/media; check_eq "a link in --path that leaves the location" 1 "$rc"
fmsel out -- plan copy --from disk:data-04 --path shares/media --to disk:data-05 --to-path shares/media; check_eq "a link in the selection (copy)" 1 "$rc"; reason | grep -q link && pass "reason says link" || fail "link reason: $out"
fmsel out -- plan move --from disk:data-04 --path shares/media --to disk:data-05 --to-path shares/media; check_eq "a link in the selection (move)" 1 "$rc"
mkdir -p "$D5/shares/media"; ln -s "$B/outside" "$D5/shares/media/tgtlink"
fmsel Avatar -- plan copy --from disk:data-04 --path shares/media/movies --to disk:data-05 --to-path shares/media/tgtlink; check_eq "a target path through a link that leaves" 1 "$rc"
rm -f "$D4/shares/media/out" "$D5/shares/media/tgtlink"
fmsel shares -- plan delete --from disk:data-04 --path ""; check_eq "shares at a disk root cannot be selected" 1 "$rc"; reason | grep -q array && pass "reason: array" || fail "array: $out"
fmsel lost+found -- plan delete --from disk:data-04 --path ""; check_eq "lost+found cannot be selected" 1 "$rc"
fmsel shares -- plan copy --from disk:data-04 --path "" --to disk:data-05 --to-path ""; check_eq "nothing is put on the top of an array" 1 "$rc"
fmsel Avatar -- plan copy --from disk:data-04 --path shares/media/movies --to disk:data-05 --to-path ""; check_eq "a target at the top of a disk" 1 "$rc"
fmsel media -- plan delete --from disk:data-04 --path shares; check_eq "a share folder cannot be deleted from here" 1 "$rc"
fmsel media -- plan rename --from disk:data-04 --path shares --newname media2; check_eq "a share folder cannot be renamed from here" 1 "$rc"
fmsel Avatar -- plan copy --from disk:data-04 --path shares/media/movies --to disk:data-06 --to-path shares/media; check_eq "a closed disk is no target" 1 "$rc"
mkdir -p "$D6/shares/media"
fmsel Avatar -- plan copy --from disk:data-04 --path shares/media/movies --to disk:data-06 --to-path shares/media; check_eq "closed target (folder exists): still refused" 1 "$rc"; reason | grep -q closed && pass "reason: closed" || fail "closed: $out"
mkdir -p "$B/disks/data-07/shares/media"
fmsel Avatar -- plan copy --from disk:data-04 --path shares/media/movies --to disk:data-07 --to-path shares/media; check_eq "a disk out for recovery is no target" 1 "$rc"
fmsel old.txt -- plan copy --from temp:usb --path "" --to temp:usb --to-path photos; check_eq "a temporary disk is no target" 1 "$rc"
fmsel old.txt -- plan move --from temp:usb --path "" --to disk:data-05 --to-path shares/media; check_eq "a temporary disk cannot be moved from (read only)" 1 "$rc"
fmsel old.txt -- plan delete --from temp:usb --path ""; check_eq "nothing is deleted on a temporary disk" 1 "$rc"
fmsel old.txt -- plan copy --from temp:usb --path "" --to disk:data-05 --to-path shares/media; check_eq "copy from a temporary disk is fine" 0 "$rc"
fmsel Avatar -- plan copy --from disk:data-04 --path shares/media/movies --to disk:data-05 --to-path shares/nothing; check_eq "a missing target folder" 1 "$rc"
fmsel Avatar -- plan copy --from disk:data-04 --path shares/media/movies --to disk:data-99 --to-path shares/media; check_eq "an unknown target disk" 1 "$rc"
fmsel Nothing -- plan copy --from disk:data-04 --path shares/media/movies --to disk:data-05 --to-path shares/media; check_eq "a name that does not exist" 1 "$rc"
fmsel movies -- plan move --from disk:data-04 --path shares/media --to disk:data-05 --to-path shares/media --conflict overwrite; check_eq "overwrite together with move: refused" 1 "$rc"; reason | grep -qi overwrite && pass "reason names overwrite" || fail "ow+move: $out"
fmsel movies -- plan move --from disk:data-04 --path shares/media --to disk:data-05 --to-path shares/media --conflict newer; check_eq "newer (an overwrite) together with move: refused" 1 "$rc"
fmsel movies -- plan move --from disk:data-04 --path shares/media --to disk:data-04 --to-path shares/media; check_eq "move into the same folder: refused" 1 "$rc"
fmsel movies -- plan copy --from disk:data-04 --path shares/media --to disk:data-04 --to-path shares/media/movies/Heat; check_eq "a folder into itself: refused" 1 "$rc"
HS_FM_MARGIN=99999999999999 fmsel Avatar -- plan copy --from disk:data-04 --path shares/media/movies --to disk:data-05 --to-path shares/media; check_eq "not enough room: refused" 1 "$rc"; reason | grep -q "free" && pass "reason: free space" || fail "room: $out"
fmsel Avatar -- plan copy --from disk:data-04 --path shares/media/movies --to disk:data-05 --to-path shares/media --conflict nonsense; check_eq "an unknown conflict policy" 1 "$rc"
fmsel Avatar -- plan frobnicate --from disk:data-04 --path shares/media/movies; check_eq "an unknown operation" 1 "$rc"
rc=0; out=$(timeout 20 bash "$SCRIPTS/fm.sh" plan copy --from disk:data-04 --path shares/media/movies --to disk:data-05 --to-path shares/media </dev/null 2>&1) || rc=$?; check_eq "an empty stdin is an empty selection" 1 "$rc"

echo "-- the locks"
( exec 8>"$HS_LOCK"; flock -n 8; sleep 15 ) & lpid=$!
sleep 1
fmsel Avatar -- plan copy --from disk:data-04 --path shares/media/movies --to disk:data-05 --to-path shares/media
check_eq "the bulk lock is held: an array operation is refused" 1 "$rc"; reason | grep -q "bulk lock" && pass "reason names the lock" || fail "lock: $out"
fmsel old.txt -- plan copy --from temp:usb --path "" --to pool:fast --to-path ""
check_eq "an operation outside the array ignores the lock" 0 "$rc"
kill "$lpid" 2>/dev/null; wait "$lpid" 2>/dev/null || true
sleep 20 & cpid=$!
mkdir -p "$HS_FM_DIR/claims"; echo "$cpid" > "$HS_FM_DIR/claims/disk_data-04"
fmsel Avatar -- plan copy --from disk:data-04 --path shares/media/movies --to disk:data-05 --to-path shares/media
check_eq "one job per source disk: refused while one runs" 1 "$rc"
kill "$cpid" 2>/dev/null; wait "$cpid" 2>/dev/null || true
fmsel Avatar -- plan copy --from disk:data-04 --path shares/media/movies --to disk:data-05 --to-path shares/media
check_eq "a dead claim does not block" 0 "$rc"

echo "-- copy: start, conflicts, policies"
fmsel Avatar Heat -- start copy --from disk:data-04 --path shares/media/movies --to disk:data-05 --to-path shares/media
check_eq "start copy: exit 0" 0 "$rc"
has "^status${T}done$" && has "^unit${T}hs-job-fm-test-" && pass "start: status done + unit" || fail "start: $out"
unit=$(kv unit)
( cd "$D4/shares/media/movies" && find Avatar Heat -type f -exec md5sum {} + | sort -k2 ) > "$WORK/src.md5"
( cd "$D5/shares/media" && find Avatar Heat -type f -exec md5sum {} + | sort -k2 ) > "$WORK/dst.md5"
cmp -s "$WORK/src.md5" "$WORK/dst.md5" && pass "the copy is complete and identical" || fail "copy differs"
[ -d "$D4/shares/media/movies/Avatar" ] && pass "copy leaves the source" || fail "source gone"
[ "$(stat -c %Y "$D4/shares/media/movies/Avatar/poster.jpg")" = "$(stat -c %Y "$D5/shares/media/Avatar/poster.jpg")" ] && pass "modification time kept" || fail "mtime"
[ -z "$(find "$B" -name '.hs-fm-partial.*' 2>/dev/null)" ] && pass "no temporary file is left" || fail "partial left"
fm progress "$unit"
check_eq "progress: result done" done "$(kv result)"; check_eq "progress: files_done" 3 "$(kv files_done)"; check_eq "progress: files_total" 3 "$(kv files_total)"
for k in files_done files_total bytes_done bytes_total speed eta current phase result skipped failed; do awk -F'\t' -v k="$k" '$1 == k { f = 1 } END { exit !f }' <<<"$out" || fail "progress lacks $k"; done
check_eq "progress: skipped 0" 0 "$(kv skipped)"; check_eq "progress: failed 0" 0 "$(kv failed)"
[ "$(kv bytes_done)" = "$(kv bytes_total)" ] && pass "progress: all bytes done" || fail "bytes: $out"
fm progress hs-job-nonexistent; check_eq "progress: unknown job" 1 "$rc"
# conflicts: the same copy again
fmsel Avatar Heat -- plan copy --from disk:data-04 --path shares/media/movies --to disk:data-05 --to-path shares/media
check_eq "plan: conflicts counted" 3 "$(kv conflicts)"
fmsel Avatar Heat -- plan copy --from disk:data-04 --path shares/media/movies --to disk:data-05 --to-path shares/media --conflicts
n=$(grep -c "^conflict${T}" <<<"$out"); check_eq "--conflicts lists every conflict" 3 "$n"
has "^conflict${T}Avatar/Avatar.mkv${T}300000${T}300000${T}[0-9]*${T}[0-9]*$" && pass "conflict row: path, sizes, times" || fail "conflict row: $out"
fmsel Avatar Heat -- start copy --from disk:data-04 --path shares/media/movies --to disk:data-05 --to-path shares/media
unit=$(kv unit); fm progress "$unit"
check_eq "skip (default): 3 skipped" 3 "$(kv skipped)"; check_eq "skip: nothing failed" 0 "$(kv failed)"
has "^skip${T}Avatar/Avatar.mkv${T}" && pass "skip rows name the file and the reason" || fail "skip rows: $out"
echo changed > "$D5/shares/media/Heat/Heat.mkv"
fmsel Avatar Heat -- start copy --from disk:data-04 --path shares/media/movies --to disk:data-05 --to-path shares/media --conflict rename
[ -f "$D5/shares/media/Heat/Heat (1).mkv" ] && [ "$(cat "$D5/shares/media/Heat/Heat.mkv")" = changed ] && pass "rename: the new file gets a free name, the old one stays" || fail "rename policy: $(ls "$D5/shares/media/Heat")"
fmsel Avatar Heat -- start copy --from disk:data-04 --path shares/media/movies --to disk:data-05 --to-path shares/media --conflict overwrite
check_eq "overwrite without a confirmation: refused" 1 "$rc"; has "^reason${T}type the confirmation" && pass "overwrite asks for the typed target name" || fail "ow confirm: $out"
fmsel Avatar Heat -- plan copy --from disk:data-04 --path shares/media/movies --to disk:data-05 --to-path shares/media --conflict overwrite
check_eq "plan overwrite: confirm_name is the target name" media "$(kv confirm_name)"
fmsel Avatar Heat -- start copy --from disk:data-04 --path shares/media/movies --to disk:data-05 --to-path shares/media --conflict overwrite --confirm wrong
check_eq "overwrite with a wrong confirmation: refused" 1 "$rc"
[ "$(cat "$D5/shares/media/Heat/Heat.mkv")" = changed ] && pass "nothing was overwritten without the right confirmation" || fail "overwritten too early"
fmsel Avatar Heat -- start copy --from disk:data-04 --path shares/media/movies --to disk:data-05 --to-path shares/media --conflict overwrite --confirm media
cmp -s "$D4/shares/media/movies/Heat/Heat.mkv" "$D5/shares/media/Heat/Heat.mkv" && pass "overwrite with the confirmation replaces the file" || fail "overwrite did not happen"
echo older > "$D5/shares/media/Heat/Heat.mkv"; touch -d '2001-01-01' "$D5/shares/media/Heat/Heat.mkv"
echo newer > "$D5/shares/media/Avatar/poster.jpg"
fmsel Avatar Heat -- start copy --from disk:data-04 --path shares/media/movies --to disk:data-05 --to-path shares/media --conflict newer --confirm media
cmp -s "$D4/shares/media/movies/Heat/Heat.mkv" "$D5/shares/media/Heat/Heat.mkv" && [ "$(cat "$D5/shares/media/Avatar/poster.jpg")" = newer ] && pass "newer: replaced only when the source is newer" || fail "newer policy"
rm -rf "$D5/shares/media/Avatar" "$D5/shares/media/Heat"

echo "-- move"
fmsel Avatar -- plan move --from disk:data-04 --path shares/media/movies --to disk:data-05 --to-path shares/media
has "^step${T}- remove each file" && check_eq "plan move: parity yes (a move off a data disk)" yes "$(kv parity)" && has "^note${T}The SnapRAID parity is out of date" && pass "plan move: steps and the parity note" || fail "move plan: $out"
fmsel Avatar -- start move --from disk:data-04 --path shares/media/movies --to disk:data-05 --to-path shares/media
check_eq "start move: exit 0" 0 "$rc"; unit=$(kv unit)
[ ! -e "$D4/shares/media/movies/Avatar" ] && [ -f "$D5/shares/media/Avatar/Avatar.mkv" ] && pass "move: the folder is on the target, gone from the source" || fail "move result"
[ "$(md5sum < "$D5/shares/media/Avatar/Avatar.mkv")" = "$(grep ' Avatar/Avatar.mkv' "$WORK/src.md5" | cut -d' ' -f1)  -" ] && pass "move: the content is identical" || fail "move md5"
fm progress "$unit"; check_eq "move: result done" done "$(kv result)"
# move with an existing file: the source file stays
mkdir -p "$D4/shares/media/movies/Avatar"; echo mine > "$D4/shares/media/movies/Avatar/Avatar.mkv"; echo new > "$D4/shares/media/movies/Avatar/extra.txt"
fmsel Avatar -- start move --from disk:data-04 --path shares/media/movies --to disk:data-05 --to-path shares/media
[ -f "$D4/shares/media/movies/Avatar/Avatar.mkv" ] && [ "$(cat "$D4/shares/media/movies/Avatar/Avatar.mkv")" = mine ] && [ ! -e "$D4/shares/media/movies/Avatar/extra.txt" ] && [ -f "$D5/shares/media/Avatar/extra.txt" ] && pass "move: a skipped file stays on the source, the rest moves" || fail "move with conflict"
[ "$(wc -c < "$D5/shares/media/Avatar/Avatar.mkv")" = 300000 ] && pass "move: the file at the target is untouched" || fail "move overwrote"
rm -rf "$D4/shares/media/movies/Avatar"
# inside one filesystem: a rename
HS_FM_NO_RENAME=0 fmsel Heat -- plan move --from disk:data-04 --path shares/media/movies --to disk:data-04 --to-path shares/media
has "same filesystem, so a rename" && pass "plan: inside one filesystem a move is a rename" || fail "rename plan: $out"
HS_FM_NO_RENAME=0 fmsel Heat -- start move --from disk:data-04 --path shares/media/movies --to disk:data-04 --to-path shares/media
[ -f "$D4/shares/media/Heat/Heat.mkv" ] && [ ! -e "$D4/shares/media/movies/Heat" ] && pass "move inside one disk: renamed" || fail "rename move"
HS_FM_NO_RENAME=0 fmsel Heat -- start move --from disk:data-04 --path shares/media --to disk:data-04 --to-path shares/media/movies
[ -f "$D4/shares/media/movies/Heat/Heat.mkv" ] && pass "and back again" || fail "rename back"
# parity after
rm -f "$WORK/parity-ran"
mkdir -p "$D4/shares/media/p1"; echo x > "$D4/shares/media/p1/x"
HS_FM_PARITY_CMD="touch $WORK/parity-ran" fmsel p1 -- start move --from disk:data-04 --path shares/media --to disk:data-05 --to-path shares/media --parity-after
[ -e "$WORK/parity-ran" ] && pass "--parity-after starts the parity update when the move is done" || fail "parity-after"
rm -f "$WORK/parity-ran"; mkdir -p "$D4/shares/media/p2"; echo x > "$D4/shares/media/p2/x"
HS_FM_PARITY_CMD="touch $WORK/parity-ran" fmsel p2 -- start copy --from disk:data-04 --path shares/media --to disk:data-05 --to-path shares/media --parity-after
[ ! -e "$WORK/parity-ran" ] && pass "a copy leaves the parity alone" || fail "parity after copy"

echo "-- a job that is interrupted or does not verify"
mkdir -p "$WORK/stub" "$D4/shares/media/v1"; echo content > "$D4/shares/media/v1/f1"; echo content2 > "$D4/shares/media/v1/f2"
cat > "$WORK/stub/cp" <<'EOF'
#!/bin/sh
# a cp that dies half way: a partial file, a failure
for last; do :; done
echo half > "$last"
exit 1
EOF
chmod +x "$WORK/stub/cp"
PATH="$WORK/stub:$PATH" fmsel v1 -- start move --from disk:data-04 --path shares/media --to disk:data-05 --to-path shares/media
unit=$(kv unit); fm progress "$unit"
check_eq "a failing copy: result failed" failed "$(kv result)"; check_eq "a failing copy: failed count" 2 "$(kv failed)"
[ -f "$D4/shares/media/v1/f1" ] && [ -f "$D4/shares/media/v1/f2" ] && pass "a failing copy removes nothing from the source" || fail "source lost"
[ -z "$(find "$B" -name '.hs-fm-partial.*')" ] && [ ! -e "$D5/shares/media/v1/f1" ] && pass "a failing copy leaves no half file at the target" || fail "half file: $(find "$B" -name '.hs-fm-partial.*')"
cat > "$WORK/stub/cp" <<'EOF'
#!/bin/sh
# a cp that "succeeds" but writes a truncated file: the check must catch it
for last; do :; done
echo tr > "$last"
exit 0
EOF
PATH="$WORK/stub:$PATH" fmsel v1 -- start move --from disk:data-04 --path shares/media --to disk:data-05 --to-path shares/media
unit=$(kv unit); fm progress "$unit"
check_eq "a bad copy is not accepted" failed "$(kv result)"
[ -f "$D4/shares/media/v1/f1" ] && [ "$(cat "$D4/shares/media/v1/f1")" = content ] && pass "an unverified file is never removed from the source" || fail "unverified delete"
[ ! -e "$D5/shares/media/v1/f1" ] && [ -z "$(find "$B" -name '.hs-fm-partial.*')" ] && pass "and the bad copy is not left at the target" || fail "bad copy left"
rm -f "$WORK/stub/cp"
echo "-- cancel"
rm -rf "$D4/shares/media/c1" "$D5/shares/media/c1"; mkdir -p "$D4/shares/media/c1"
for i in 1 2 3 4 5 6 7 8; do echo "file $i" > "$D4/shares/media/c1/f$i"; done
cat > "$WORK/stub/cp" <<'EOF'
#!/bin/sh
sleep 1
exec /bin/cp "$@"
EOF
chmod +x "$WORK/stub/cp"
export -n HS_FM_SYNC; unset HS_FM_SYNC
PATH="$WORK/stub:$PATH" fmsel c1 -- start move --from disk:data-04 --path shares/media --to disk:data-05 --to-path shares/media
unit=$(kv unit); jpid=$(cat "$HS_FM_DIR/jobs/$unit.pid")
sleep 3
fm progress "$unit"; check_eq "a running job reports running" running "$(kv result)"
kill -TERM "$jpid"
for _ in $(seq 1 30); do kill -0 "$jpid" 2>/dev/null || break; sleep 0.5; done
fm progress "$unit"
check_eq "a cancelled job: result cancelled" cancelled "$(kv result)"
done_n=$(find "$D5/shares/media/c1" -type f 2>/dev/null | wc -l); left_n=$(find "$D4/shares/media/c1" -type f | wc -l)
[ "$done_n" -ge 1 ] && [ "$done_n" -lt 8 ] && [ $((done_n + left_n)) -eq 8 ] && pass "cancel: copied files stay, the rest is still at the source ($done_n moved, $left_n left)" || fail "cancel counts: $done_n / $left_n"
[ -z "$(find "$B" -name '.hs-fm-partial.*')" ] && pass "cancel leaves no half file" || fail "partial after cancel"
for f in "$D5"/shares/media/c1/f*; do [ "$(cat "$f")" = "file ${f##*/f}" ] || fail "cancelled copy wrong: $f"; done
[ ! -e "$HS_FM_DIR/busy/$(cat "$HS_FM_DIR/jobs/$unit.alias")" ] && pass "a finished job leaves no busy mark" || fail "busy mark left"
rm -f "$WORK/stub/cp"; export HS_FM_SYNC=1
[ -z "$(ls "$HS_FM_DIR/claims" 2>/dev/null | while read -r c; do kill -0 "$(cat "$HS_FM_DIR/claims/$c")" 2>/dev/null && echo "$c"; done)" ] && pass "no claim stays alive" || fail "claim alive"

echo "-- delete"
rm -rf "$D4/shares/media/d1"; mkdir -p "$D4/shares/media/d1/sub"; for i in 1 2 3; do echo x > "$D4/shares/media/d1/f$i"; done; echo y > "$D4/shares/media/d1/sub/g"
fmsel d1 -- plan delete --from disk:data-04 --path shares/media
check_eq "plan delete: confirm_name is the count" "delete 4 files" "$(kv confirm_name)"; check_eq "plan delete: parity yes" yes "$(kv parity)"
has "^warn${T}Delete is permanent" && pass "plan delete: a warning, permanent" || fail "delete warn: $out"
fmsel d1 -- start delete --from disk:data-04 --path shares/media
check_eq "start delete without confirmation: refused" 1 "$rc"; [ -d "$D4/shares/media/d1" ] && pass "nothing deleted" || fail "deleted without confirm"
fmsel d1 -- start delete --from disk:data-04 --path shares/media --confirm "delete 3 files"
check_eq "start delete with a wrong count: refused" 1 "$rc"; [ -d "$D4/shares/media/d1" ] && pass "still there" || fail "deleted with wrong confirm"
fmsel d1 -- start delete --from disk:data-04 --path shares/media --confirm "delete 4 files"
check_eq "start delete with the confirmation: ok" 0 "$rc"; [ ! -e "$D4/shares/media/d1" ] && pass "deleted" || fail "not deleted"
unit=$(kv unit); fm progress "$unit"; check_eq "delete: files_done" 4 "$(kv files_done)"; check_eq "delete: done" done "$(kv result)"
echo z > "$D4/shares/media/one.txt"
fmsel one.txt -- plan delete --from disk:data-04 --path shares/media; check_eq "one file" "delete 1 file" "$(kv confirm_name)"
printf 'a\n' > "$D6/shares/media/r.txt"
fmsel r.txt -- plan delete --from disk:data-06 --path shares/media; check_eq "delete on a closed disk is allowed (it frees room)" 0 "$rc"
fmsel r.txt -- plan delete --from disk:data-07 --path shares/media; check_eq "delete on a disk out for recovery: refused" 1 "$rc"

echo "-- rename and new folder"
fmsel one.txt -- plan rename --from disk:data-04 --path shares/media --newname two.txt; check_eq "plan rename" 0 "$rc"
fmsel one.txt -- start rename --from disk:data-04 --path shares/media --newname two.txt
[ -f "$D4/shares/media/two.txt" ] && [ ! -e "$D4/shares/media/one.txt" ] && pass "rename" || fail "rename"
fmsel two.txt -- plan rename --from disk:data-04 --path shares/media --newname readme.txt; check_eq "rename onto an existing name: refused" 1 "$rc"
fmsel two.txt -- plan rename --from disk:data-04 --path shares/media --newname "a/b"; check_eq "rename with a slash: refused" 1 "$rc"
fmsel two.txt -- plan rename --from disk:data-04 --path shares/media --newname ".."; check_eq "rename to ..: refused" 1 "$rc"
fmsel two.txt readme.txt -- plan rename --from disk:data-04 --path shares/media --newname z; check_eq "rename takes one item" 1 "$rc"
fmsel -- start mkdir --from disk:data-04 --path shares/media --newname brandnew
[ -d "$D4/shares/media/brandnew" ] && pass "new folder" || fail "mkdir: $out"
fmsel -- plan mkdir --from disk:data-04 --path shares/media --newname brandnew; check_eq "new folder that exists: refused" 1 "$rc"
fmsel -- plan mkdir --from disk:data-04 --path "" --newname loose; check_eq "new folder at the top of an array: refused" 1 "$rc"
fmsel -- plan mkdir --from disk:data-06 --path shares/media --newname x; check_eq "new folder on a closed disk: refused" 1 "$rc"
fmsel -- plan mkdir --from disk:data-04 --path shares/media --newname "x/y"; check_eq "new folder name with a slash: refused" 1 "$rc"

echo "-- the write switch (fileManagerWrite)"
fm locations; [ "$(kv write)" = yes ] && pass "locations: write yes while the switch is on" || fail "write row: $out"
echo false > "$HS_STATE_DIR/settings/fileManagerWrite"
fm locations; [ "$(kv write)" = no ] && pass "locations: write no while the switch is off" || fail "write row off: $out"
before=$(ls "$D4/shares/media" | tr '\n' ' ')
for o in "copy --to disk:data-05 --to-path shares/media" "move --to disk:data-05 --to-path shares/media" "delete" "rename --newname zzz"; do
  fmsel readme.txt -- start $o --from disk:data-04 --path shares/media --confirm "delete 1 file"
  check_eq "start ${o%% *} with the switch off: refused" 1 "$rc"
  reason | grep -q fileManagerWrite && pass "start ${o%% *}: the reason says how to switch it on" || fail "reason: $out"
done
fmsel -- start mkdir --from disk:data-04 --path shares/media --newname nope; check_eq "start mkdir with the switch off: refused" 1 "$rc"
[ ! -e "$D4/shares/media/nope" ] && [ "$before" = "$(ls "$D4/shares/media" | tr '\n' ' ')" ] && pass "nothing changed while the switch is off" || fail "files changed with the switch off"
fmsel readme.txt -- plan copy --from disk:data-04 --path shares/media --to disk:data-05 --to-path shares/media; check_eq "plan works with the switch off" 0 "$rc"
has "^warn${T}The file manager is read only" && pass "the plan warns that the switch is off" || fail "plan warn: $out"
fm ls disk:data-04 --path shares/media; check_eq "ls works with the switch off" 0 "$rc"
fm pair disk:data-04 disk:data-05; check_eq "pair works with the switch off" 0 "$rc"
echo true > "$HS_STATE_DIR/settings/fileManagerWrite"
fmsel readme.txt -- plan copy --from disk:data-04 --path shares/media --to disk:data-05 --to-path shares/media; has "^warn${T}The file manager is read only" && fail "warn stays with the switch on" || pass "no read-only warning with the switch on"

echo "-- audit and the pieces around it"
[ -s "$HS_FM_DIR/audit.log" ] && grep -q "^[0-9T:+-]*${T}ui${T}delete${T}disk:data-04:/shares/media${T}" "$HS_FM_DIR/audit.log" && pass "audit.log: one line per operation (time, who, op, source)" || fail "audit: $(tail -n3 "$HS_FM_DIR/audit.log" 2>/dev/null)"
grep -q "result" /dev/null; grep -q "${T}done$" "$HS_FM_DIR/audit.log" && grep -q "${T}failed$" "$HS_FM_DIR/audit.log" && grep -q "${T}cancelled$" "$HS_FM_DIR/audit.log" && pass "audit.log: results done, failed and cancelled" || fail "audit results"
for w in locations "pair <left> <right>" "ls <location>" "progress <unit>" "plan <op>" "start <op>"; do
  grep -q "^sys${T}sys fm $w${T}fm.sh${T}" "$SCRIPTS/lib/registry.tsv" || fail "registry row sys fm $w"
done
grep -c "^sys${T}sys fm " "$SCRIPTS/lib/registry.tsv" | grep -q '^6$' && pass "registry rows" || fail "registry rows count"
grep -q '("fm", "locations")' "$SCRIPTS/web-serve.py" && grep -q '"fm": \[' "$SCRIPTS/web-serve.py" && pass "web READS and CHANGES entries" || fail "web allowlists"

finish
