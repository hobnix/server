#!/usr/bin/env bash
# Audit history (hobnix/server#167): the dispatcher records "who did what" for commands with the flag `changes`, never the arguments,
# and `hs audit` / `hs sys audit` list it. A copy of the dispatcher with a fake registry, a throwaway state.db. python3 stdlib, no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
command -v python3 >/dev/null || { echo "python3 missing: skipped"; exit 0; }
wp() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
export HS_PLAIN=1 HS_LANG=en HS_EVENT_NOROOT=1 HS_LIVE_LOG=/dev/null
export HS_STATE_DB=$(wp "$WORK/state.db")

fake=$WORK/fake; mkdir -p "$fake/lib"
for f in hs.sh capability.sh registry-load.sh ui.sh i18n.sh setting.sh live.sh audit.sh event.sh event-kinds.tsv; do cp "$SCRIPTS/lib/$f" "$fake/lib/"; done
cp "$SCRIPTS/state-db.py" "$SCRIPTS/audit.sh" "$fake/"
printf 'echo "ran:$*"\n[ "${1:-}" != boom ]\n' > "$fake/x.sh"
printf 'user\tthing do\tx.sh\t-\t-\t-\ttopic:system,changes\nuser\tthing show\tx.sh\t-\t-\t-\ttopic:system,reads\nuser\tthing hook\tx.sh\t-\t-\t-\tnohelp,topic:system,changes\nuser\tthing <name> set\tx.sh\tset\t-\t-\ttopic:system,changes\n' > "$fake/lib/registry.tsv"
F="bash $fake/lib/hs.sh"
export HS_CALLER=test HS_AUDIT_FORCE=1
A() { python3 "$fake/state-db.py" audit-list "$@"; }

echo "-- recorded"
SUDO_USER=alice $F thing do --password=hunter2 >/dev/null
SUDO_USER=alice $F thing do boom >/dev/null || true
$F thing show >/dev/null
$F thing hook >/dev/null
SUDO_USER=bob $F thing web1 set --token=abc >/dev/null
out=$(A)
check_eq "a changing command is recorded with actor, result and the words typed" "alice	ok	0	thing do" "$(sed -n 1p <<<"$out" | cut -f3-)"
check_eq "a failing one is recorded as failed with its exit code" "alice	failed	1	thing do" "$(sed -n 2p <<<"$out" | cut -f3-)"
check_eq "a reading command and a nohelp row are not recorded" "3" "$(wc -l <<<"$out" | tr -d ' ')"
check_eq "a value in the path is part of the words" "bob	ok	0	thing web1 set" "$(sed -n 3p <<<"$out" | cut -f3-)"
if grep -qE 'hunter2|abc|--token|--password' "$HS_STATE_DB"; then fail "an argument value reached the database"; else pass "no argument value reached the database"; fi

echo "-- actors"
check_eq "a timer" "timer" "$(HS_CALLER=timer $F thing do >/dev/null; A 1 | cut -f3)"
check_eq "the web interface" "web" "$(HS_CALLER=ui $F thing do >/dev/null; A 1 | cut -f3)"
check_eq "HS_ACTOR wins and is made safe" "ann_x" "$(HS_ACTOR='ann x' $F thing do >/dev/null; A 1 | cut -f3)"
check_eq "HS_CALLER=test is not logged without the force knob" "$(A | wc -l)" "$(env -u HS_AUDIT_FORCE $F thing do >/dev/null; A | wc -l)"
check_eq "HS_AUDIT_OFF logs nothing" "$(A | wc -l)" "$(HS_AUDIT_OFF=1 $F thing do >/dev/null; A | wc -l)"
check_eq "the exit code of the command stays" "1" "$($F thing do boom >/dev/null; echo $?)"

echo "-- listing"
check_eq "N limits, newest last" "1" "$(A 1 | wc -l | tr -d ' ')"
check_eq "hs sys audit is the same list" "$(A 2)" "$(bash "$fake/audit.sh" 2)"
check_eq "an empty database lists nothing" "" "$(HS_STATE_DB=$(wp "$WORK/none.db") A)"
check_eq "no event kind is missing in the catalogue" "2" "$(grep -c '^audit\.' "$SCRIPTS/lib/event-kinds.tsv")"
check_out "the real registry has both rows" "audit.sh" grep -E '^(user	audit|sys	sys audit)	' "$SCRIPTS/lib/registry.tsv"

finish
