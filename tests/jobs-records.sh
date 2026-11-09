#!/usr/bin/env bash
# hs sys jobs record <id> / records (scripts/jobs.sh --record/--records, scripts/job-records.py): one record as JSON, the list
# newest first as tab-separated lines with "-" for empty, the --state filter, the limit, a bad id, no directory. No root, no systemd.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HS_JOBS_DIR="$T/jobs" HS_STATE_DIR="$T/state" HS_JOB_RATE=0
W="python3 $here/scripts/job-record.py"
J="bash $here/scripts/jobs.sh"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok:   $1"; else echo "FAIL: $1 (got: $3 | want: $2)"; fail=1; fi; }

$J --records >"$T/o" 2>&1; rc=$?
check "no directory: empty list, exit 0" "0:" "$rc:$(cat "$T/o")"

a=$($W new --slug alpha --desc "first job" --unit hs-job-alpha-1)
sleep 1
b=$($W new --slug beta --desc "second	job" --unit hs-job-beta-2)
$W run "$b"; $W step "$b" 2 5 "Copy data"; $W progress "$b" 10 100 files
$W run "$a"; $W finish "$a" 0

check "record is the JSON of get" "$($W get "$a")" "$($J --record "$a")"
check "record has the state" "ok" "$($J --record "$a" | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])')"
$J --record "no-such-id" >/dev/null 2>&1; check "a bad id fails" "1" "$?"
$J --record >/dev/null 2>&1; check "no id fails" "1" "$?"

rows=$($J --records)
check "two rows" "2" "$(grep -c '' <<<"$rows")"
check "newest first" "$b" "$(head -n1 <<<"$rows" | cut -f1)"
check "14 columns per row" "14" "$(head -n1 <<<"$rows" | awk -F'\t' '{print NF}')"
check "step and progress of a running job" "running	2	5	Copy data	10	100	files" "$(head -n1 <<<"$rows" | cut -f4,9-14)"
check "a tab in the description becomes a space" "second job" "$(head -n1 <<<"$rows" | cut -f3)"
check "empty fields are -" "-" "$(sed -n 2p <<<"$rows" | cut -f9)"
check "state and exit of the finished job" "ok	0" "$(sed -n 2p <<<"$rows" | cut -f4,8)"

check "state filter" "$a" "$($J --records --state ok | cut -f1)"
check "state filter without match is empty" "" "$($J --records --state failed)"
check "limit" "1" "$($J --records 1 | grep -c '')"
$J --records --bogus >/dev/null 2>&1; check "bad argument fails" "1" "$?"

printf 'not json' >"$HS_JOBS_DIR/20260101-000000-junk-abcd.json"
check "a broken file is skipped" "2" "$($J --records | grep -c '')"

# ADR 0018: waiting is a state, children lists the sub-jobs of one orchestration, oldest first
o=$($W new --slug orch --desc "orchestrator" --unit hs-job-orch-1 --kind orchestration); $W run "$o"
c1=$($W new --slug orch-one --desc "step one" --unit hs-job-orch-one-1 --parent "$o" --kind step); $W run "$c1"
sleep 1
c2=$($W new --slug orch-two --desc "step two" --unit hs-job-orch-two-1 --parent "$o" --kind step); $W run "$c2"
$W wait "$o" --seq 1 --key K --label Q --kind text
check "waiting is listed and can be filtered" "$o" "$($J --records --state waiting | cut -f1)"
check "children: the sub-jobs, oldest first" "$c1 $c2" "$($J --children "$o" | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
check "children: the columns of records" "14" "$($J --children "$o" | head -n1 | awk -F'\t' '{print NF}')"
check "children of a job without any is empty" "" "$($J --children "$a")"
$J --children nope >/dev/null 2>&1; check "children with a bad id fails" "1" "$?"
$J --children >/dev/null 2>&1; check "children without an id fails" "1" "$?"
check "the record JSON carries parent and kind" "$o step" "$($J --record "$c1" | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r["parent"], r["kind"])')"

exit $fail
