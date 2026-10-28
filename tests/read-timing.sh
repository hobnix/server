#!/usr/bin/env bash
# scripts/read-timing.sh (hs timing): the reads of the interface, timed. A fake dispatcher with chosen delays: no root, no server.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en
unset HS_CALLER
cat > "$WORK/hs" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/calls"
case "$*" in
  "sys users list") sleep 1.2 ;;
  "sys ct list") sleep 0.3 ;;
  "sys backup snapshots") exit 3 ;;
esac
FAKE
chmod +x "$WORK/hs"
export HS_BIN=$WORK/hs
T() { bash "$SCRIPTS/read-timing.sh" "$@"; }

echo "-- list"
out=$(T --list)
check_eq "every read is listed once" "22" "$(wc -l <<<"$out" | tr -d ' ')"
check_eq "the slowest comes first" "users list" "$(head -n1 <<<"$out" | cut -f3)"
check_out "seconds with milliseconds" "^1\.[0-9]{3}	0	users list$" echo "$out"
check_out "a failing read shows its exit status" "	3	backup snapshots$" echo "$out"
check_out "the second slowest" "^0\.[0-9]{3}	0	ct list$" echo "$(sed -n 2p <<<"$out")"

echo "-- what is called"
check "only sys reads" test "$(grep -vc '^sys ' "$WORK/calls")" = 0
check "no plan, start or report" test "$(grep -Ec ' (plan|start|report)( |$)' "$WORK/calls")" = 0
check_out "the doctor is a read" "sys system doctor" cat "$WORK/calls"

echo "-- the table for people"
out=$(T)
check_out "a count of failed reads" "Reads that failed: 1" echo "$out"
check_out "a count of slow reads" "Slower than 1 s: 1" echo "$out"
check_out "the table has the commands" "hs sys users list" echo "$out"
check_out "the closing note" "All reads one after the other" echo "$out"

echo "-- options"
: > "$WORK/calls"
T --list --repeat 2 >/dev/null
check_eq "--repeat 2 runs every read twice" "44" "$(wc -l < "$WORK/calls" | tr -d ' ')"
check_eq "a bad count is refused" "1" "$(T --repeat x >/dev/null 2>&1; echo $?)"
check_eq "an unknown option is refused" "1" "$(T --bogus >/dev/null 2>&1; echo $?)"

finish
