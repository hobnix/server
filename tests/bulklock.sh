#!/usr/bin/env bash
# scripts/lib/bulklock.sh: a pool change (hs pool bulk replace/remove) holds the lock for hours; the
# timer's parity sync must skip quietly then (it used to fail on SnapRAID's own lock and send an alarm).
# Temp files only, no root.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"; kill $(jobs -p) 2>/dev/null' EXIT
export HS_LOCK=$T/lock HS_LOCK_ADMIN=$T/admin
LIB=$here/scripts/lib/bulklock.sh
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok:   $1"; else echo "FAIL: $1 (got: $3 | want: $2)"; fail=1; fi; }
job()   { bash -c ". '$LIB'; bulk_lock_job ${1:-1}; echo took-it"; }
admin() { bash -c ". '$LIB'; bulk_lock_admin ${2:-5}; sleep ${1:-3}"; }

echo "== a job with nothing running takes the lock"
out=$(job); check "takes it" "took-it" "$out"

echo "== a pool change holds it: the job skips with exit 0"
admin 4 & sleep 1
check "the marker exists while it runs" "yes" "$([ -e "$T/admin" ] && echo yes || echo no)"
out=$(job); rc=$?
check "exit 0 (no alarm)" "0" "$rc"
check "says why" "1" "$(grep -c 'pool change' <<<"$out")"
check "did not take the lock" "0" "$(grep -c took-it <<<"$out")"
out=$(admin 1 1 2>&1); rc=$?
check "a second pool change is refused while the first runs" "1" "$rc"
wait
check "the marker is gone when the pool change ends" "no" "$([ -e "$T/admin" ] && echo yes || echo no)"

echo "== a normal holder (the cache mover): the job waits, then gives up with exit 1"
flock "$T/lock" sleep 4 & sleep 1
out=$(job 1); rc=$?
check "exit 1 after the wait" "1" "$rc"
wait
out=$(job); check "free again afterwards" "took-it" "$out"

exit $fail
