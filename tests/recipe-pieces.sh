#!/usr/bin/env bash
# The piece helpers of scripts/recipes/_lib.sh (stamps, pins, --check). No server needed.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1
run() {   # run <args...> -- <snippet>: the snippet runs with the helpers loaded
  local args=() ; while [ "$1" != -- ]; do args+=("$1"); shift; done; shift
  bash -c 'state=$1; ct=t; scripts=$2; shift 2; set -- "$@"; . "$2/recipes/_lib.sh" 2>/dev/null; '"$1" _ "$WORK" "$SCRIPTS" "${args[@]}"
}
S() { bash -c 'state=$1; ct=t; scripts=$2; shift 2; . "$scripts/recipes/_lib.sh"; '"$SNIP" _ "$WORK" "$SCRIPTS" "$@"; }
echo "-- stamps and pieces"
SNIP='piece app 1.2 App && echo current || echo stale'
check_eq "no stamp: stale" "stale" "$(S 2>/dev/null | tail -n1)"
SNIP='piece_done app 1.2; piece app 1.2 App && echo current || echo stale'
check_eq "after piece_done: current" "current" "$(S 2>/dev/null | tail -n1)"
SNIP='piece app 1.3 App && echo current || echo stale'
check_eq "a new pin: stale again" "stale" "$(S 2>/dev/null | tail -n1)"
echo "-- --check"
SNIP='piece app 1.3 App; piece other 2 Other; check_done'
out=$(S --check 2>&1); rc=$?
check_out "--check names the piece that would update" "would update +App [(]1.2 -> 1.3[)]" echo "$out"
check_eq "--check exits 1 when something would update" "1" "$(S --check >/dev/null 2>&1; echo $?)"
SNIP='piece_done app 1.3; piece_done other 2; piece app 1.3 App; piece other 2 Other; check_done'
check_eq "--check exits 0 when all is current" "0" "$(S --check >/dev/null 2>&1; echo $?)"
echo "-- fetch_pinned (curl is replaced by a copy)"
printf 'hello
' > "$WORK/src"; sum=$(sha256sum "$WORK/src" | cut -d' ' -f1)
SNIP='curl() { cp '"$WORK"'/src "$3"; }; fetch_pinned blob http://x/y '"$sum"' '"$WORK"'/dest 1; cat '"$WORK"'/dest'
check_out "downloads on the first run" "hello" S
SNIP='curl() { return 9; }; fetch_pinned blob http://x/y '"$sum"' '"$WORK"'/dest 1; echo kept'
check_out "does not download when current" "kept" S
rm -f "$WORK/hit"
SNIP='curl() { touch '"$WORK"'/hit; return 9; }; fetch_pinned blob http://x/y '"$sum"' '"$WORK"'/dest 2'
S >/dev/null 2>&1 || true
check "a new pin downloads again" test -e "$WORK/hit"
SNIP='curl() { echo evil > "$3"; }; fetch_pinned bad http://x/y '"$sum"' '"$WORK"'/dest2 1'
check_out "a wrong checksum installs nothing" "does not match" S
check "and leaves no file" test ! -e "$WORK/dest2"
finish
