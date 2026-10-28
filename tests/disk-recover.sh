#!/usr/bin/env bash
# hs disk <member> recover (scripts/disk-recover.sh, routed by disk-change.sh): what is searched, where the files go, how they are sorted and named,
# what is refused. No root and no real disk: fake photorec and ffprobe, a plain file as the device, folders as mounted data disks (HS_RECOVER_TEST=1).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en HS_CALLER=ui
unset HS_GUIDED_TTY
T=$'\t'
export HS_BULK_BASE=$WORK/base HS_STATE_DIR=$WORK/state HS_RECOVER_TEST=1 HS_RECOVER_TICK=1 HS_LOCK=$WORK/lock HS_LOCK_ADMIN=$WORK/admin
mkdir -p "$HS_BULK_BASE/data-04" "$HS_BULK_BASE/data-03" "$HS_STATE_DIR"
truncate -s 64M "$WORK/disk.img"; export HS_RECOVER_DEV=$WORK/disk.img

# a fake photorec: writes what the real one writes (recup_dir.N/f<number>.<ext> under /d), records its command line
cat > "$WORK/photorec" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/photorec-calls"
while [ $# -gt 0 ]; do [ "$1" = /d ] && { d=$2; break; }; shift; done
mkdir -p "${d}recup_dir.1" "${d}recup_dir.2"
head -c 5000 /dev/urandom > "${d}recup_dir.1/f0000001.mkv"     # a video with tags
head -c 5000 /dev/urandom > "${d}recup_dir.1/f0000002.mkv"     # a video ffprobe cannot read
head -c 3000 /dev/urandom > "${d}recup_dir.1/f0000003.jpg"
head -c 3000 /dev/urandom > "${d}recup_dir.2/f0000004.mp3"
head -c 3000 /dev/urandom > "${d}recup_dir.2/f0000005.pdf"
head -c 3000 /dev/urandom > "${d}recup_dir.2/f0000006.xyz"
sleep 2
FAKE
cat > "$WORK/ffprobe" <<'FAKE'
#!/usr/bin/env bash
f=${@: -1}
case "$f" in
  *f0000001.mkv) printf 'duration=125.4\nTAG:title=Heat: Director'"'"'s Cut\n' ;;
  *f0000004.mp3) printf 'duration=61.0\nTAG:title=Song\nTAG:artist=Band\n' ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$WORK/photorec" "$WORK/ffprobe"
export HS_PHOTOREC=$WORK/photorec HS_FFPROBE=$WORK/ffprobe
run() { rc=0; out=$(timeout 60 bash "$SCRIPTS/disk-recover.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }
runc() { rc=0; out=$(timeout 60 bash "$SCRIPTS/disk-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }

echo "-- plan"
run plan data-04
check_eq "plan: exit 0" 0 "$rc"
has "^status${T}ok$" && has "^heading${T}recover deleted files from data-04" && has "^confirm_name${T}data-04$" && has "^long${T}yes$" && has "^target${T}data-03$" \
  && pass "plan: status, heading, the typed name, long, the target" || fail "plan: $out"
has "^step${T}.*read-only" && has "^warn${T}Services that read /bulk" && has "^note${T}The names and folders of deleted files are gone" && pass "plan: steps and what to expect" || fail "plan text: $out"
run plan data-04 --to data-03
has "^target${T}data-03$" && pass "plan: --to names the target" || fail "--to: $out"
runc plan recover data-04
check_eq "disk-change.sh routes recover" 0 "$rc"
has "^status${T}ok$" && pass "via hs sys disk plan" || fail "route: $out"

echo "-- refusals"
run plan data-04 --to data-04
check_eq "the target cannot be the same disk" 1 "$rc"
has "^status${T}refused$" && pass "refused with a status" || fail "same: $out"
run plan data-04 --to data-99
check_eq "a target that is not mounted" 1 "$rc"
run plan sda
check_eq "only data-NN" 1 "$rc"
run plan ../data-04
check_eq "no path tricks" 1 "$rc"
run plan data-04 --types everything
check_eq "types are media or all" 1 "$rc"
HS_PHOTOREC=/nonexistent/photorec run plan data-04
check_eq "no photorec: refused" 1 "$rc"
has "photorec is not installed" && pass "says so" || fail "no photorec: $out"
HS_RECOVER_DEV=$WORK/nodisk run plan data-04
check_eq "a disk that is not found" 1 "$rc"
has "unlock" && pass "mentions unlocking" || fail "not found: $out"
run start data-04 --to data-03
check_eq "start needs the typed name" 1 "$rc"
has "type the name to confirm: data-04" && pass "names the word" || fail "no confirm: $out"
run start data-04 --to data-03 --confirm data-03
check_eq "the wrong name is refused" 1 "$rc"
[ ! -e "$HS_STATE_DIR/recovering/data-04" ] && pass "nothing was marked" || fail "marked anyway"

echo "-- the job (start --now)"
run start data-04 --to data-03 --types media --confirm data-04 --now
check_eq "start --now: exit 0" 0 "$rc"
has "^status${T}done$" && pass "status done" || fail "start: $out"
[ -f "$HS_STATE_DIR/recovering/data-04" ] && pass "the disk is marked out for a recovery" || fail "no marker"
runfolder=$(ls -d "$HS_BULK_BASE"/data-03/shares/recovered/data-04-* 2>/dev/null | head -n1)
[ -n "$runfolder" ] && pass "output is on the other disk (shares/recovered/data-04-<date>)" || fail "no output folder"
[ ! -e "$HS_BULK_BASE/data-04/shares/recovered" ] && pass "nothing was written to the source disk" || fail "output on the source"
call=$(cat "$WORK/photorec-calls")
case "$call" in *"/cmd $WORK/disk.img"*"partition_none"*"fileopt,everything,disable,jpg,enable"*"mkv,enable"*"wholespace,search"*) pass "photorec: whole space of the device, only the media types";; *) fail "photorec call: $call";; esac
case "$call" in *"/d $runfolder/raw/"*) pass "photorec writes below raw/ of the run folder";; *) fail "photorec output: $call";; esac
ls "$runfolder/videos" | grep -q "^Heat_ Director_s Cut-0000001-2m05s.mkv$" && pass "a video is named by its title and length" || fail "videos: $(ls "$runfolder/videos" "$runfolder/videos/unreadable" 2>&1 | tr '\n' ' ')"
[ -f "$runfolder/videos/unreadable/f0000002.mkv" ] && pass "a video ffprobe cannot read is kept apart" || fail "unreadable video"
[ -f "$runfolder/photos/f0000003.jpg" ] && pass "photos go to photos/" || fail "photos"
ls "$runfolder/music" | grep -q "^Band - Song-0000004-1m01s.mp3$" && pass "music is named by artist and title" || fail "music: $(ls "$runfolder/music" | tr '\n' ' ')"
[ -f "$runfolder/documents/f0000005.pdf" ] && [ -f "$runfolder/other/f0000006.xyz" ] && pass "documents and other kinds are sorted" || fail "documents/other"
[ -z "$(find "$runfolder/raw" -type f 2>/dev/null)" ] && pass "raw/ holds nothing after sorting" || fail "raw not empty"
has "^files${T}6$" && pass "the count of files is reported" || fail "count: $out"

echo "-- a second recovery of a disk that is out, and the types"
rm -rf "$HS_BULK_BASE"/data-03/shares/recovered
run start data-04 --to data-03 --types all --confirm data-04 --now
check_eq "again: exit 0" 0 "$rc"
tail -n1 "$WORK/photorec-calls" | grep -q "fileopt,everything,enable,wholespace" && pass "--types all enables every kind" || fail "all: $(tail -n1 "$WORK/photorec-calls")"

echo "-- finish"
runc plan recover-finish data-04
check_eq "finish plan while out" 0 "$rc"
runc start recover-finish data-04
check_eq "finish: exit 0" 0 "$rc"
[ ! -e "$HS_STATE_DIR/recovering/data-04" ] && pass "the mark is gone, bulk-mount.sh takes the disk again" || fail "marker stays"
runc plan recover-finish data-04
check_eq "finish when it is not out" 1 "$rc"
has "not out of the pool" && pass "says so" || fail "finish refused: $out"

echo "-- the pieces around it"
grep -q 'recdir/${l#bulk-}' "$SCRIPTS/bulk-mount.sh" && pass "bulk-mount.sh leaves a disk that is out for a recovery alone" || fail "bulk-mount.sh"
grep -q '^user	disk <disk> recover	disk-recover.sh' "$SCRIPTS/lib/registry.tsv" && pass "registry row" || fail "registry row"
grep -q 'r"^recover$"' "$SCRIPTS/web-serve.py" && pass "web CHANGES allowlist" || fail "web CHANGES"

finish
