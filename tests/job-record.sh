#!/usr/bin/env bash
# scripts/job-record.py (the job record writer, ADR 0004) and its use in hs_job: new/run/step/progress/finish/get,
# field names, atomic write, rate limit, retention, no argv in the file, a bad directory. No root, no systemd.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HS_JOBS_DIR="$T/jobs" HS_STATE_DIR="$T/state" HS_JOB_RATE=60   # long: the rate limit test must not depend on how fast python starts
W="python3 $here/scripts/job-record.py"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok:   $1"; else echo "FAIL: $1 (got: $3 | want: $2)"; fail=1; fi; }
# jq-free JSON reader: field path like step.n; prints "null" for an absent value
jf() { python3 -c 'import json,sys
v=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v=None if v is None else v.get(k)
print("null" if v is None else v)' "$HS_JOBS_DIR/$1.json" "$2"; }

id=$($W new --slug "pool-sync" --desc "hs pool sync" --unit hs-job-pool-sync-120000 --source cli --initiator alice)
check "new prints an id of the right shape" "1" "$(grep -cE '^[0-9]{8}-[0-9]{6}-pool-sync-[a-z]{4}$' <<<"$id")"
check "a new record is queued" "queued" "$(jf "$id" state)"
check "unit stored" "hs-job-pool-sync-120000" "$(jf "$id" unit)"
check "initiator stored" "alice" "$(jf "$id" initiator)"
check "version is 1" "1" "$(jf "$id" version)"
check "fields are exactly the ADR list" "id,slug,description,source,initiator,unit,queued,started,ended,state,exit,step,progress,error,result,cancel,version" \
  "$(python3 -c 'import json,sys; print(",".join(json.load(open(sys.argv[1]))))' "$HS_JOBS_DIR/$id.json")"
check "absent values are null" "null" "$(jf "$id" started)"
check "directory mode 0755" "755" "$(stat -c %a "$HS_JOBS_DIR")"
check "file mode 0644" "644" "$(stat -c %a "$HS_JOBS_DIR/$id.json")"

$W run "$id"
check "run sets running" "running" "$(jf "$id" state)"
check "run sets started" "1" "$(jf "$id" started | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$')"

$W step "$id" 1 3 "Copy data"
check "step n" "1" "$(jf "$id" step.n)"
check "step of" "3" "$(jf "$id" step.of)"
check "step text" "Copy data" "$(jf "$id" step.text)"

$W progress "$id" 10 100 files
$W progress "$id" 20 100 files   # inside the rate window: ignored
check "progress is rate limited" "10" "$(jf "$id" progress.done)"
$W progress "$id" 100 100 files  # the last one always goes through
check "progress DONE == TOTAL is not limited" "100" "$(jf "$id" progress.done)"
check "progress unit" "files" "$(jf "$id" progress.unit)"

$W finish "$id" 0
check "finish 0 is ok" "ok" "$(jf "$id" state)"
check "finish stores exit" "0" "$(jf "$id" exit)"
check "finish sets ended" "1" "$(jf "$id" ended | grep -c '^20')"
check "ok has no error" "null" "$(jf "$id" error)"
check "get prints valid JSON" "ok" "$($W get "$id" | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])')"
check "no temporary file is left" "0" "$(find "$HS_JOBS_DIR" -name '*.tmp' | wc -l)"

id2=$($W new --slug bad --desc "bad one" --unit u --source web --initiator "")
$W run "$id2"; $W finish "$id2" 3
check "finish 3 is failed" "failed" "$(jf "$id2" state)"
check "failed error category" "exit" "$(jf "$id2" error.category)"
check "failed error message" "exit status 3" "$(jf "$id2" error.message)"
check "empty initiator is null" "null" "$(jf "$id2" initiator)"
check "ids differ" "1" "$([ "$id" != "$id2" ] && echo 1 || echo 0)"


# errors: one line on stderr, exit 1
err=$($W get "20200101-000000-nope-abcd" 2>&1 >/dev/null); rc=$?
check "get of a missing record exits 1" "1" "$rc"
check "the error is one line" "1" "$(printf '%s\n' "$err" | wc -l)"
echo '{not json' > "$HS_JOBS_DIR/20200101-000000-junk-abcd.json"
$W get 20200101-000000-junk-abcd >/dev/null 2>&1; check "bad JSON exits 1" "1" "$?"
touch "$T/afile"
HS_JOBS_DIR="$(cygpath -m "$T" 2>/dev/null || echo "$T")/afile/sub" $W new --slug x --desc d --unit u --source cli --initiator "" >/dev/null 2>&1
check "an unusable directory exits 1" "1" "$?"

# retention: beyond the newest 200 and older than 30 days goes; old but within 200 stays
export HS_JOBS_DIR="$T/ret"; mkdir -p "$HS_JOBS_DIR"
for i in $(seq 1 205); do printf '{}' > "$HS_JOBS_DIR/20200101-0000$(printf %02d $((i % 100)))-r$i-abcd.json"; done
find "$HS_JOBS_DIR" -name '*.json' -exec touch -d '60 days ago' {} +
for i in $(seq 1 5); do touch -d "$((i + 40)) days ago" "$HS_JOBS_DIR/20200101-0000$(printf %02d $((i % 100)))-r$i-abcd.json"; done
$W new --slug fresh --desc d --unit u --source cli --initiator "" >/dev/null
check "retention keeps the newest 200" "200" "$(ls "$HS_JOBS_DIR"/*.json | wc -l)"
export HS_JOBS_DIR="$T/ret2"; mkdir -p "$HS_JOBS_DIR"
for i in $(seq 1 10); do printf '{}' > "$HS_JOBS_DIR/20200101-000000-k$i-abcd.json"; done
find "$HS_JOBS_DIR" -name '*.json' -exec touch -d '60 days ago' {} +
$W new --slug fresh --desc d --unit u --source cli --initiator "" >/dev/null
check "old records within the newest 200 stay" "11" "$(ls "$HS_JOBS_DIR"/*.json | wc -l)"

# hs_job with a stand-in systemd-run
export HS_JOBS_DIR="$T/hj"
mkdir -p "$T/bin"
cat > "$T/bin/systemd-run" <<'FAKE'
#!/usr/bin/env bash
E=()
while [ $# -gt 0 ]; do
  case "$1" in -E) E+=("$2"); shift 2 ;; --*) shift ;; *) break ;; esac
done
[ -z "${FAKE_SYSTEMD_RUN_FAIL:-}" ] || exit 1
# like the real thing: the unit gets only what -E gives it, not the caller's environment
# Windows python needs a few host variables to start at all; none of them is a HS_ variable
keep=(); for v in SYSTEMROOT WINDIR USERPROFILE LOCALAPPDATA APPDATA TEMP TMP HOME; do [ -z "${!v:-}" ] || keep+=("$v=${!v}"); done
exec env -i "PATH=$PATH" ${keep[@]+"${keep[@]}"} ${E[@]+"${E[@]}"} "$@"
FAKE
chmod +x "$T/bin/systemd-run"
export PATH="$T/bin:$PATH"
run() { bash -c ". '$here/scripts/lib/job.sh'; $1" 2>&1; }
out=$(run 'unit=$(hs_job "my-slug" "a good job" -- bash -c "exit 0"); echo "unit=$unit"')
unit=$(grep -oE 'hs-job-my-slug-[0-9]{6}' <<<"$out" | head -n1)
f=$(ls "$HS_JOBS_DIR"/*-my-slug-*.json 2>/dev/null | head -n1); rid=$(basename "${f:-x}" .json)
check "hs_job writes a record with the unit" "$unit" "$(jf "$rid" unit)"
check "the record ends ok" "ok" "$(jf "$rid" state)"
check "the description is stored" "a good job" "$(jf "$rid" description)"
run 'hs_job bad "a bad job" -- bash -c "exit 3"' >/dev/null
f=$(ls "$HS_JOBS_DIR"/*-bad-*.json 2>/dev/null | head -n1); rid=$(basename "${f:-x}" .json)
check "a failing job ends failed" "failed" "$(jf "$rid" state)"
# the command line and the caller's environment never reach the record
SECRETVAR=hunter2 run 'hs_job sec "only text" -- bash -c "echo hunter2 >/dev/null"' >/dev/null
f=$(ls "$HS_JOBS_DIR"/*-sec-*.json 2>/dev/null | head -n1)
check "the record exists for the secret test" "1" "$([ -n "$f" ] && echo 1 || echo 0)"
check "no command argument in any record" "0" "$(grep -l hunter2 "$HS_JOBS_DIR"/*.json 2>/dev/null | wc -l)"
# the unit writes to the same directory as hs_job even though its environment is cleaned (ended is set by the unit)
check "the unit reached the same directory" "ok" "$(jf "$(basename "$f" .json)" state)"
# systemd-run fails: hs_job returns 1 and the record ends failed
FAKE_SYSTEMD_RUN_FAIL=1 run 'hs_job nostart "never starts" -- true; echo "rc=$?"' >"$T/nostart.out"
check "a failed start returns 1" "1" "$(grep -c 'rc=1' "$T/nostart.out")"
f=$(ls "$HS_JOBS_DIR"/*-nostart-*.json 2>/dev/null | head -n1)
check "a failed start ends the record failed" "failed" "$(jf "$(basename "${f:-x}" .json)" state)"
out=$(run 'hs_job_step 1 2 x; hs_job_progress 1 2 y; echo fine')
check "the helpers are no-ops without HS_JOB_ID" "fine" "$out"

# cancellation (ADR 0004 decisions 3-5)
export HS_JOBS_DIR="$T/cj"
c1=$($W new --slug cj --desc "old" --unit hs-job-cj-100000 --initiator bob); sleep 1
c2=$($W new --slug cj --desc "new" --unit hs-job-cj-100000 --initiator bob); sleep 1
c3=$($W new --slug cj --desc "done" --unit hs-job-cj-100000 --initiator bob)
$W run "$c1"; $W run "$c2"; $W run "$c3"; $W finish "$c3" 0
check "find-unit picks the newest running record" "$c2" "$($W find-unit hs-job-cj-100000)"
check "find-unit accepts the .service name" "$c2" "$($W find-unit hs-job-cj-100000.service)"
$W find-unit hs-nothing 2>"$T/fu.err"; rc=$?
check "find-unit without a record exits 1" "1" "$rc"
check "find-unit says it in one line" "1" "$(wc -l <"$T/fu.err" | tr -d ' ')"
$W cancel "$c2" --by alice --safe no
check "cancel sets cancelled" "cancelled" "$(jf "$c2" state)"
check "cancel sets ended" "1" "$(jf "$c2" ended | grep -c '^20')"
check "cancel stores who" "alice" "$(jf "$c2" cancel.requested_by)"
check "cancel stores safe false" "False" "$(jf "$c2" cancel.safe)"
check "cancel stores the time" "1" "$(jf "$c2" cancel.at | grep -c '^20')"
check "cancel has no error" "null" "$(jf "$c2" error)"
check "find-unit now picks the older running record" "$c1" "$($W find-unit hs-job-cj-100000)"
before=$(cat "$HS_JOBS_DIR/$c3.json")
$W cancel "$c3" --by alice --safe yes 2>"$T/c.err"; rc=$?
check "cancel of an ok record exits 1" "1" "$rc"
check "cancel of an ok record changes nothing" "$before" "$(cat "$HS_JOBS_DIR/$c3.json")"
check "the refusal is one line" "1" "$(wc -l <"$T/c.err" | tr -d ' ')"
$W cancel "$c1" --safe yes
check "an empty --by is null" "null" "$(jf "$c1" cancel.requested_by)"
check "cancel stores safe true" "True" "$(jf "$c1" cancel.safe)"
ended=$(jf "$c2" ended)
$W finish "$c2" 143
check "finish after cancel keeps cancelled" "cancelled" "$(jf "$c2" state)"
check "finish after cancel stores exit" "143" "$(jf "$c2" exit)"
check "finish after cancel keeps cancel" "alice" "$(jf "$c2" cancel.requested_by)"
check "finish after cancel keeps ended" "$ended" "$(jf "$c2" ended)"
check "cancelled exits 0 for a cancelled record" "0" "$($W cancelled "$c2"; echo $?)"
check "cancelled exits 1 for an ok record" "1" "$($W cancelled "$c3"; echo $?)"
cx=$($W new --slug cj --desc "cx" --unit hs-job-cj-200000); $W run "$cx"
keep=(); for v in SYSTEMROOT WINDIR USERPROFILE LOCALAPPDATA APPDATA TEMP TMP HOME PATH; do [ -z "${!v:-}" ] || keep+=("$v=${!v}"); done
hjc() { env -i ${keep[@]+"${keep[@]}"} "$@" bash -c ". '$here/scripts/lib/job.sh'; hs_job_cancelled; echo \$?"; }
check "hs_job_cancelled is 1 without HS_JOB_ID" "1" "$(hjc HS_JOBS_DIR="$HS_JOBS_DIR")"
check "hs_job_cancelled is 1 for a running job" "1" "$(hjc HS_JOBS_DIR="$HS_JOBS_DIR" HS_JOB_ID="$cx")"
$W cancel "$cx" --by x --safe yes
check "hs_job_cancelled is 0 for a cancelled job" "0" "$(hjc HS_JOBS_DIR="$HS_JOBS_DIR" HS_JOB_ID="$cx")"

# an older binary (no `job-record`) must not swallow the records: hs_job falls back to Python
mkdir -p "$T/oldbin"
printf '#!/usr/bin/env bash
echo "hobnix: unknown subcommand: job-record" >&2
exit 1
' > "$T/oldbin/hobnix"; chmod +x "$T/oldbin/hobnix"
export HS_JOBS_DIR="$T/old"
HOBNIX_BIN="$T/oldbin/hobnix" run 'hs_job oldbin "old binary job" -- bash -c "exit 0"' >/dev/null
f=$(ls "$HS_JOBS_DIR"/*-oldbin-*.json 2>/dev/null | head -n1); rid=$(basename "${f:-x}" .json)
check "an old binary falls back to the Python writer" "ok" "$(jf "$rid" state)"

# events (docs/adr/0005-events.md rule 9): hs_job_record writes job.<state> after the record changed; finish after a cancel adds none
export HS_EVENT_NOROOT=1 HS_STATE_DB="$T/ev.db" HS_JOB_RECORD=python HS_JOBS_DIR="$T/jobs"
hr() { bash -c ". '$here/scripts/lib/job.sh'; hs_job_record \"\$@\"" _ "$@"; }
evs() { python3 "$here/scripts/state-db.py" event-list 50 2>/dev/null; }
eid=$(hr new --slug ev --desc "event job" --unit hs-job-ev-1 --source cli)
hr run "$eid"; hr finish "$eid" 0
check "queued, running and ok are emitted with the id as subject" "3" "$(evs | grep -c "$eid")"
check "job.queued" "1" "$(evs | grep "$eid" | grep -c 'job.queued')"
check "job.ok" "1" "$(evs | grep "$eid" | grep -c 'job.ok')"
fid=$(hr new --slug evf --desc "bad job" --unit hs-job-evf-1 --source cli); hr run "$fid"; hr finish "$fid" 7
check "job.failed is emitted" "1" "$(evs | grep "$fid" | grep -c 'job.failed')"
hr finish "$fid" 1
check "a second finish emits nothing" "1" "$(evs | grep "$fid" | grep -c 'job.failed')"
cid=$(hr new --slug evc --desc "stopped job" --unit hs-job-evc-1 --source cli); hr run "$cid"
hr cancel "$cid" --by alice --safe yes; hr finish "$cid" 143
check "finish after cancel keeps cancelled" "cancelled" "$(jf "$cid" state)"
check "finish after cancel emits no event" "0" "$(evs | grep "$cid" | grep -c 'job.failed')"
hr uncancel "$cid" 2>/dev/null; check "uncancel on a finished cancel is refused" "cancelled" "$(jf "$cid" state)"
uid=$(hr new --slug evu --desc "kept job" --unit hs-job-evu-1 --source cli); hr run "$uid"
hr cancel "$uid" --by alice --safe yes; hr uncancel "$uid"
check "uncancel puts running back" "running" "$(jf "$uid" state)"
check "uncancel clears the cancel block and ended" "null null" "$(jf "$uid" cancel) $(jf "$uid" ended)"
BAD_EV=$(HS_STATE_DB=/nonexistent/x/ev.db hr new --slug evb --desc "no log" --unit hs-job-evb-1 --source cli >/dev/null; echo "rc=$?")
check "an unwritable event log changes nothing for the job" "1" "$(grep -c 'rc=0' <<<"$BAD_EV")"

exit $fail
