#!/usr/bin/env bash
# hs live measure (ADR 0026 step 1): scripts/live_measure.py against a temp state.db with a stub web that answers the probes, and
# scripts/live-measure.sh argument checks. python3 stdlib only, no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
command -v python3 >/dev/null || { echo "python3 missing: skipped"; exit 0; }
wp() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
export HS_PLAIN=1 HS_LANG=en HS_CALLER=test
mkdir -p "$WORK/d"
export HS_STATE_DB=$(wp "$WORK/d/state.db") HS_STATE_DIR=$(wp "$WORK/d")
export HS_STATE_PY=$(wp "$SCRIPTS/state-db.py")
export HS_WEB_PROBE_FILE=$(wp "$WORK/probe.tsv")
export HS_MEASURE_LOST_S=2

echo "-- live measure"
# a state.db with the live tables, as hs-live-db leaves it
python3 - "$HS_STATE_DB" <<'PYEOF'
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
c.executescript("""
CREATE TABLE topics (topic TEXT PRIMARY KEY, gen INTEGER NOT NULL DEFAULT 0, time INTEGER NOT NULL DEFAULT 0);
CREATE TABLE live (topic TEXT PRIMARY KEY, payload TEXT NOT NULL, updated INTEGER NOT NULL);
CREATE TABLE heartbeat (name TEXT PRIMARY KEY, time INTEGER, every INTEGER, started INTEGER, beats INTEGER, docs INTEGER, fails INTEGER,
  bytes INTEGER, slow INTEGER, wait_ms INTEGER, read INTEGER);
CREATE TABLE reads (key TEXT PRIMARY KEY, updated INTEGER, ts_err INTEGER);
""")
t = int(time.time())
c.execute("INSERT INTO live VALUES ('status', 'abc', ?)", (t,))
c.execute("INSERT INTO heartbeat VALUES ('hs-live', ?, 5, ?, 1, 1, 0, 3, 0, 4, NULL)", (t, t))
c.commit()
PYEOF

# the stub web: tails the counter live:probe and writes the probe line, as Events.record_probe does
cat >"$WORK/stub.py" <<'PYEOF'
import os, sqlite3, sys, time
db, out = sys.argv[1], sys.argv[2]
seen = 0
end = time.time() + 30
while time.time() < end:
    try:
        c = sqlite3.connect(db, timeout=2)
        row = c.execute("SELECT gen FROM topics WHERE topic = 'live:probe'").fetchone()
        c.close()
    except sqlite3.Error:
        row = None
    if row and row[0] != seen:
        seen = row[0]
        with open(out, "a") as f:
            f.write("live:probe\t%d\t%d\t1\n" % (seen, int(time.time() * 1000)))
    time.sleep(0.1)
PYEOF
python3 "$WORK/stub.py" "$HS_STATE_DB" "$HS_WEB_PROBE_FILE" &
stub=$!

LM=$SCRIPTS/live_measure.py
python3 "$LM" --seconds 4 --probe-every 1 --mode db --out "$(wp "$WORK/res")" >"$WORK/out.txt" 2>&1
check_eq "exit code" "0" "$?"
kill "$stub" 2>/dev/null; wait "$stub" 2>/dev/null
check "the .md file exists" test -s "$WORK/res.md"
check "the .tsv file exists" test -s "$WORK/res.tsv"
labels="period minutes|mode|collector doc writes/min|collector failure writes/min|collector heartbeats/min|payload KiB/min|commits over 100 ms|mean commit ms|counter bumps/min (without probe)|old collector writes/min|state.db growth KiB|WAL growth KiB|state.db end KiB|WAL end KiB|probes sent|probes matched|probes lost|latency min ms|latency median ms|latency p95 ms|latency max ms|probe write median ms|probe write max ms|probes with a stream open|collector restarted during the run"
missing=""
IFS='|' read -ra want <<<"$labels"
for l in "${want[@]}"; do grep -qF "$l"$'\t' "$WORK/res.tsv" || missing="$missing [$l]"; done
check_eq "the tsv has every label" "" "$missing"
check_eq "no empty field in the tsv" "0" "$(awk -F'\t' 'NF != 2 || $1 == "" || $2 == "" {n++} END {print n + 0}' "$WORK/res.tsv")"
tsv() { awk -F'\t' -v k="$1" '$1 == k {print $2}' "$WORK/res.tsv"; }
sent=$(tsv "probes sent")
if [ "${sent:-0}" -ge 2 ]; then pass "probes sent >= 2 ($sent)"; else fail "probes sent: $sent"; fi
check_eq "all probes matched" "$sent" "$(tsv "probes matched")"
check_eq "the mode is in the result" "db" "$(tsv mode)"

echo "-- a missing probe file: every probe is lost"
rm -f "$WORK/probe.tsv"
python3 "$LM" --seconds 3 --probe-every 1 --mode db --out "$(wp "$WORK/lost")" >/dev/null 2>&1
check_eq "exit code (lost)" "0" "$?"
lsent=$(awk -F'\t' '$1 == "probes sent" {print $2}' "$WORK/lost.tsv")
check_eq "lost = sent" "$lsent" "$(awk -F'\t' '$1 == "probes lost" {print $2}' "$WORK/lost.tsv")"
check_eq "no latency" "-" "$(awk -F'\t' '$1 == "latency median ms" {print $2}' "$WORK/lost.tsv")"

echo "-- no state database"
HS_STATE_DB=$(wp "$WORK/none/state.db") python3 "$LM" --seconds 1 --probe-every 2 --out "$(wp "$WORK/none")" >/dev/null 2>&1
check_eq "exit 1 without a state database" "1" "$?"

echo "-- live-measure.sh arguments"
out=$(bash "$SCRIPTS/live-measure.sh" --minutes 0 2>&1); rc=$?
check_eq "--minutes 0: exit 1" "1" "$rc"
case "$out" in *"usage: hs live measure"*) pass "--minutes 0: usage line" ;; *) fail "--minutes 0: $out" ;; esac
check_eq "--probe-every 1: exit 1" "1" "$(bash "$SCRIPTS/live-measure.sh" --probe-every 1 >/dev/null 2>&1; echo $?)"
check_eq "--minutes without a value: exit 1, no hang" "1" "$(timeout 10 bash "$SCRIPTS/live-measure.sh" --minutes >/dev/null 2>&1; echo $?)"
finish
