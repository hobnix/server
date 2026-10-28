#!/usr/bin/env bash
# scripts/reads-collect.sh + the table `reads` of the state database (state-db.py read-put|read-get|reads): the collector runs the slow reads of the web
# interface, keeps their output, skips what is fresh, keeps the old output when a read fails, and does nothing while the storage is locked.
# A stand-in for the hs dispatcher; python3 stdlib only, no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
command -v python3 >/dev/null || { echo "python3 missing: skipped"; exit 0; }
wp() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
if command -v cygpath >/dev/null 2>&1; then export HS_TEST_BASH=$(cygpath -m "$BASH"); fi
export HS_PLAIN=1 HS_LANG=en HS_CALLER=test HS_STATE_DIR=$(wp "$WORK/state") HS_LOCKED_MARKER=$(wp "$WORK/no-marker")
mkdir -p "$WORK/state"
T=$'\t'
S="bash $SCRIPTS/state.sh"
CALLS=$WORK/calls; : > "$CALLS"
# the stand-in for `hs sys <words>`: prints something per read, counts the calls, fails for "bad read"
cat > "$WORK/hs-stub" <<STUB
#!/usr/bin/env bash
[ "\$1" = sys ] || exit 9
shift
echo "\$*" >> "$CALLS"
case "\$*" in
  "bad read") exit 3 ;;
  "half read") printf 'partial\n'; exit 1 ;;
  *) printf 'out of %s\tx\n' "\$*" ;;
esac
STUB
chmod +x "$WORK/hs-stub"
printf '# comment\nct list\t10\nshares overview\t30\nbad read\t10\nhalf read\t10\n' > "$WORK/list.tsv"
export HS_COLLECTED_FILE=$WORK/list.tsv HS_BIN=$WORK/hs-stub
C="bash $SCRIPTS/reads-collect.sh"

echo "-- the table"
printf 'hello\tworld\n' | $S read-put "monitor disks" --ms 120 --rc 0
check_eq "read-get gives the output back" "hello${T}world" "$($S read-get "monitor disks")"
$S read-get nothing >/dev/null 2>&1; check_eq "no output: exit 1" 1 "$?"
printf 'second\n' | $S read-put "monitor disks" --ms 90
check_eq "a second put replaces the first" "second" "$($S read-get "monitor disks")"
check_eq "reads lists key, age, ms, rc, bytes" "monitor disks${T}0${T}90${T}0${T}7" "$($S reads | sed 's/\t[0-9]*\t90/\t0\t90/')"
printf 'x' | $S read-put "Bad;Key" >/dev/null 2>&1; check_eq "a key with odd characters is refused" 1 "$?"
printf 'x' | $S read-put "a b c d e" >/dev/null 2>&1; check_eq "a key of five words is refused" 1 "$?"

echo "-- the collector"
$C
check_eq "every read of the list ran once (fresh ones are not read again)" "bad read
ct list
half read
shares overview" "$(sort "$CALLS")"
check_eq "the output is kept" "out of ct list${T}x" "$($S read-get "ct list")"
check_eq "a failed read without output is not kept" 1 "$($S read-get "bad read" >/dev/null 2>&1; echo $?)"
check_eq "a failed read with output is kept, with its exit code" "partial" "$($S read-get "half read")"
check_eq "...and the exit code is in the list" "1" "$($S reads | awk -F'\t' '$1 == "half read" { print $4 }')"
: > "$CALLS"; $C
check_eq "a second run right away reads only what failed" "bad read" "$(sort "$CALLS")"
: > "$CALLS"; $C --all
check_eq "--all reads everything again" "4" "$(grep -c . "$CALLS")"

echo "-- --list"
out=$($C --list)
check_out "names the key, the interval and the age" "^ct list${T}10${T}[0-9]" echo "$out"
check_out "a read that was never kept has age -1" "^bad read${T}10${T}-1" echo "$out"

echo "-- --status"
out=$($C --status)
check_out "a kept read: key, interval, age, ms, exit code, bytes" "^ct list${T}10${T}[0-9]+${T}[0-9]+${T}0${T}[0-9]+\$" echo "$out"
check_out "a read that was never kept: age -1, dashes after it" "^bad read${T}10${T}-1${T}-${T}-${T}-\$" echo "$out"
check_eq "the failed read keeps its exit code" "1" "$(awk -F'\t' '$1 == "half read" { print $5 }' <<<"$out")"
check_eq "as many lines as the list" "4" "$(grep -c . <<<"$out")"

echo "-- the storage is locked"
: > "$CALLS"; touch "$WORK/locked"
HS_LOCKED_MARKER=$(wp "$WORK/locked") $C --all
check_eq "nothing runs" "0" "$(grep -c . "$CALLS")"

echo "-- no list"
rm -f "$WORK/list.tsv"; : > "$CALLS"
$C; check_eq "no list: exit 0, nothing runs" "0:0" "$?:$(grep -c . "$CALLS")"

echo "-- the list of the repo"
awk -F'\t' '!/^#/ && NF { print $1 }' "$SCRIPTS/lib/collected-reads.tsv" | while read -r k; do echo "$k"; done > "$WORK/keys"
check "the list has the reads that wait most" grep -qx "monitor disks" "$WORK/keys"
check_eq "every line has a number of seconds" "" "$(awk -F'\t' '!/^#/ && NF && $2 !~ /^[0-9]+$/ { print $1 }' "$SCRIPTS/lib/collected-reads.tsv")"
finish
