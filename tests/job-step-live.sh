#!/usr/bin/env bash
# A job step or progress update counts the change counter `reads:jobs-records` up (ADR 0005 rule 5) so the Jobs panel reads again, and the rate
# limit of the record writer holds for the counter too (no log row, one bump per second at most). No root, no systemd.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HS_JOBS_DIR="$T/jobs" HS_STATE_DIR="$T/state" HS_STATE_DB="$T/state/state.db" HS_JOB_RATE=60 HS_EVENT_NOROOT=1
mkdir -p "$T/state"   # topic-bump does nothing without the database folder
W="python3 $here/scripts/job-record.py"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok:   $1"; else echo "FAIL: $1 (got: $3 | want: $2)"; fail=1; fi; }
gen() { python3 -c 'import sqlite3,sys
c=sqlite3.connect(sys.argv[1]); r=c.execute("SELECT gen FROM topics WHERE topic=?",("reads:jobs-records",)).fetchone(); print(r[0] if r else 0)' "$HS_STATE_DB" 2>/dev/null || echo 0; }
rows() { python3 -c 'import sqlite3,sys
print(sqlite3.connect(sys.argv[1]).execute("SELECT count(*) FROM events").fetchone()[0])' "$HS_STATE_DB" 2>/dev/null || echo 0; }

id=$($W new --slug pool-sync --desc "hs pool sync" --unit u1 --source cli --initiator alice)
check "no bump before a step" "0" "$(gen)"
$W step "$id" 1 3 Copy
check "a step counts the counter up" "1" "$(gen)"
$W step "$id" 2 3 Check
check "a second step inside the rate limit does not" "1" "$(gen)"
$W progress "$id" 10 100 MB
check "progress has its own limit and counts up" "2" "$(gen)"
$W progress "$id" 20 100 MB
check "progress inside the limit does not" "2" "$(gen)"
$W step "$id" 3 3 Done
check "the last step is never limited" "3" "$(gen)"
check "no log row per step" "0" "$(rows)"
HS_JOB_NOBUMP=1 $W progress "$id" 100 100 MB
check "HS_JOB_NOBUMP switches the bump off" "3" "$(gen)"
HS_STATE_DB=/nonexistent/x/state.db $W step "$id" 3 3 Done; check "a missing database never fails the writer" "0" "$?"

# the Rust writer (stubbed here) does not bump: the shell wrapper does, once per second
cat >"$T/hobnix" <<'STUB'
#!/usr/bin/env bash
[ "$1" = job-record ] || exit 1
[ "${2:-}" = --probe ] && exit 0
exit 0
STUB
chmod +x "$T/hobnix"
before=$(gen)
out=$(HOBNIX_BIN="$T/hobnix" HS_JOB_RECORD= bash -c ". '$here/scripts/lib/job.sh'; hs_job_record step x 1 3 A; hs_job_record progress x 1 10 MB; hs_job_record step x 3 3 C; echo \$_HS_JOB_RECORD_USE")
check "the wrapper took the Rust writer" "rust" "$out"
check "the wrapper counts the counter up once per second with the Rust writer" "$((before + 1))" "$(gen)"
out=$(HOBNIX_BIN="$T/hobnix" HS_JOB_NOBUMP=1 bash -c ". '$here/scripts/lib/job.sh'; hs_job_record step x 1 3 A")
check "HS_JOB_NOBUMP holds for the wrapper too" "$((before + 1))" "$(gen)"
exit $fail
