#!/usr/bin/env bash
# scripts/job-record.py reconcile and scripts/job-reconcile.sh (ADR 0004 decision 6, #133): records whose unit is gone become
# interrupted, live ones stay, finished ones stay, a second run changes nothing, one push for all. No root, no systemd (stub systemctl).
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
TW=$(cygpath -m "$T" 2>/dev/null || echo "$T")   # a path python understands on Windows too
export HS_JOBS_DIR="$T/jobs" HS_UPTIME_FILE="$T/uptime" HS_SYSTEMCTL="python3 $TW/systemctl.py" HS_JOB_NOTIFY="$T/notify"
mkdir -p "$HS_JOBS_DIR"
echo "3600.00 100.00" > "$HS_UPTIME_FILE"
# is-active: "active" for the unit hs-job-live, inactive (exit 3) for all others
cat > "$T/systemctl.py" <<'EOF'
import sys
if sys.argv[1:] == ["is-active", "hs-job-live"]:
    print("active")
else:
    print("inactive")
    sys.exit(3)
EOF
# stands in for notify.sh: one line per call
cat > "$HS_JOB_NOTIFY" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/pushes"
EOF
chmod +x "$HS_JOB_NOTIFY"
W="python3 $here/scripts/job-record.py"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok:   $1"; else echo "FAIL: $1 (got: $3 | want: $2)"; fail=1; fi; }
jf() { python3 -c 'import json,sys
v=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v=None if v is None else v.get(k)
print("null" if v is None else v)' "$HS_JOBS_DIR/$1.json" "$2"; }
mk() {   # id state unit started
  python3 - "$HS_JOBS_DIR" "$1" "$2" "$3" "$4" <<'EOF'
import json, sys
d, i, state, unit, started = sys.argv[1:6]
rec = {k: None for k in ("id", "slug", "description", "source", "initiator", "unit", "queued", "started", "ended",
                         "state", "exit", "step", "progress", "error", "result", "cancel", "version")}
rec.update(id=i, slug=i.split("-")[2], description="job " + i.split("-")[2], source="cli", unit=unit,
           queued="2020-01-01T00:00:00Z", started=started if started != "-" else None, state=state, version=1)
if state in ("ok", "failed", "cancelled"):
    rec["ended"] = "2020-01-01T00:10:00Z"; rec["exit"] = 0 if state == "ok" else 1
json.dump(rec, open("%s/%s.json" % (d, i), "w"))
EOF
}
A=20200101-000000-runa-aaaa; B=20200101-000001-queb-bbbb; C=20200101-000002-livc-cccc
D=20200101-000003-okd-dddd; E=20200101-000004-faie-eeee; F=20200101-000005-canf-ffff
mk $A running hs-job-a 2020-01-01T00:00:01Z
mk $B queued hs-job-b -
mk $C running hs-job-live 2020-01-01T00:00:01Z
mk $D ok hs-job-d 2020-01-01T00:00:01Z
mk $E failed hs-job-e 2020-01-01T00:00:01Z
mk $F cancelled hs-job-f 2020-01-01T00:00:01Z
touch "$HS_JOBS_DIR/$A.step.stamp" "$HS_JOBS_DIR/$A.progress.stamp"

out=$($W reconcile); rc=$?
check "reconcile exits 0" "0" "$rc"
check "running + unit gone is interrupted" "interrupted" "$(jf $A state)"
check "queued + unit gone is interrupted" "interrupted" "$(jf $B state)"
check "error category" "interrupted" "$(jf $A error.category)"
check "error message" "the job did not finish; the server restarted or the unit stopped" "$(jf $A error.message)"
check "exit stays null" "null" "$(jf $A exit)"
boot=$(python3 -c 'import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=3600)).strftime("%Y-%m-%dT%H:%M"))')
check "ended is the boot time (record started before it)" "1" "$(jf $A ended | grep -c "^${boot:0:15}")"
check "a live unit is left alone" "running" "$(jf $C state)"
check "ok untouched" "ok" "$(jf $D state)"
check "failed untouched" "failed" "$(jf $E state)"
check "cancelled untouched" "cancelled" "$(jf $F state)"
check "stale stamps removed" "0" "$(ls "$HS_JOBS_DIR" | grep -c stamp)"
check "file mode stays 0644" "644" "$(stat -c %a "$HS_JOBS_DIR/$A.json")"
# a job that began after this boot may sit between its record and its unit: not touched even when the unit is not active yet
G=20991231-000000-newg-gggg
mk $G running hs-job-new "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
$W reconcile >/dev/null
check "a record that began after boot is left alone" "running" "$(jf $G state)"
check "one line per interrupted job" "2" "$(grep -c . <<<"$out")"
check "no empty field in the lines" "0" "$(awk -F'\t' 'NF != 3 || $1 == "" || $2 == "" || $3 == ""' <<<"$out" | grep -c .)"
check "line content" "$A	runa	job runa" "$(grep "^$A" <<<"$out")"

before=$(cat "$HS_JOBS_DIR"/*.json | md5sum)
out2=$($W reconcile); rc=$?
check "second run exits 0" "0" "$rc"
check "second run prints nothing" "" "$out2"
check "second run changes nothing" "$before" "$(cat "$HS_JOBS_DIR"/*.json | md5sum)"

echo "{ not json" > "$HS_JOBS_DIR/20200101-000009-bad-zzzz.json"
mk 20200101-000006-newg-gggg running hs-job-g 2020-01-01T00:00:01Z
out3=$($W reconcile 2>"$T/err"); rc=$?
check "invalid JSON: exit 1" "1" "$rc"
check "invalid JSON: one line on stderr" "1" "$(grep -c . "$T/err")"
check "invalid JSON: the others are still done" "interrupted" "$(jf 20200101-000006-newg-gggg state)"
rm -f "$HS_JOBS_DIR/20200101-000009-bad-zzzz.json"

# the wrapper: two interrupted jobs, one push; none, no push
mk 20200101-000007-wra-hhhh running hs-job-h 2020-01-01T00:00:01Z
mk 20200101-000008-wrb-iiii queued hs-job-i -
bash "$here/scripts/job-reconcile.sh" >/dev/null 2>&1; rc=$?
check "wrapper exits 0" "0" "$rc"
check "wrapper sends exactly one push for two jobs" "1" "$(grep -c . "$T/pushes")"
check "the push names the count" "1" "$(grep -c '2 job(s) interrupted' "$T/pushes")"
bash "$here/scripts/job-reconcile.sh" >/dev/null 2>&1; rc=$?
check "wrapper exits 0 with nothing to do" "0" "$rc"
check "no second push" "1" "$(grep -c . "$T/pushes")"

# events: an interrupted record writes job.interrupted with the id as subject
mk 20200101-000010-evi-jjjj running hs-job-j 2020-01-01T00:00:01Z
HS_EVENT_NOROOT=1 HS_STATE_DB="$T/ev.db" bash "$here/scripts/job-reconcile.sh" >/dev/null 2>&1
check "job.interrupted is emitted with the id" "1" "$(HS_STATE_DB="$T/ev.db" python3 "$here/scripts/state-db.py" event-list 50 2>/dev/null | grep -c '20200101-000010-evi-jjjj')"

# ADR 0018: a waiting job whose unit is gone is interrupted and its question goes; a waiting job with a live unit stays
H=20200101-000020-wath-hhhh; I=20200101-000021-wati-iiii
mk $H waiting hs-job-h 2020-01-01T00:00:01Z
mk $I waiting hs-job-live 2020-01-01T00:00:01Z
python3 - "$HS_JOBS_DIR/$H.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); r["waiting"] = {"seq": 1, "key": "K", "label": "Q", "kind": "text"}; json.dump(r, open(sys.argv[1], "w"))
PY
out=$($W reconcile)
check "waiting + unit gone is interrupted" "interrupted" "$(jf $H state)"
check "the question is dropped" "null" "$(jf $H waiting)"
check "a waiting job with a live unit is left alone" "waiting" "$(jf $I state)"
check "the waiting one is reported" "1" "$(grep -c "^$H" <<<"$out")"

[ "$fail" = 0 ] && echo "job-reconcile: all ok"
exit "$fail"
