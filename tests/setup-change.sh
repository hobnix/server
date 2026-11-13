#!/usr/bin/env bash
# hs sys setup plan|start wizard-done (scripts/setup-change.sh): refused unless the first-run wizard is open; a temp flag file, no server.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi
export HS_FIRST_RUN_FILE=$WORK/first-run.json HS_PYTHON=python3
S="bash $SCRIPTS/setup-change.sh"

echo "-- hs sys setup wizard-done"
out=$($S plan wizard-done 2>&1 || true)
check_out "without a flag the plan is refused" "status.refused" echo "$out"
check_out "and says the wizard is not open" "reason.The first-run wizard is not open" echo "$out"
printf '%s' '{"state":"done","user":"adminuser","done":1,"wizard":"open"}' > "$HS_FIRST_RUN_FILE"
out=$($S plan wizard-done 2>&1); rc=$?
check "an open wizard: the plan exits 0" test "$rc" = 0
check_out "and says ok" "status.ok" echo "$out"
check_out "with a heading and the long line" "long.no" echo "$out"
out=$($S start wizard-done 2>&1)
check_out "start answers done" "status.done" echo "$out"
check_eq "the wizard reads done now" done "$(python3 "$SCRIPTS/first_run.py" wizard)"
out=$($S start wizard-done 2>&1 || true)
check_out "a second start is refused" "status.refused" echo "$out"
out=$($S plan nonsense 2>&1 || true)
check_out "an unknown action is refused" "status.refused" echo "$out"
finish
