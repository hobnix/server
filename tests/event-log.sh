#!/usr/bin/env bash
# The event log (docs/adr/0005-events.md, rules 2 to 4): the widened state.db table `events`, the one writer
# `state-db.py emit`, retention, the reader `event-list`, scripts/lib/event.sh and the registered kinds. python3 stdlib only, no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
command -v python3 >/dev/null || { echo "python3 missing: skipped"; exit 0; }
wp() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
export HS_PLAIN=1 HS_LANG=en HS_CALLER=test HS_EVENT_NOROOT=1
mkdir -p "$WORK/d"
DBF=$WORK/d/state.db
export HS_STATE_DB=$(wp "$DBF")
SD=$SCRIPTS/state-db.py
sdb() { python3 "$SD" "$@"; }
q() { python3 -c 'import sqlite3,sys; sys.stdout.reconfigure(newline=chr(10)); c=sqlite3.connect(sys.argv[1]); print(chr(10).join("|".join(str(x) for x in r) for r in c.execute(sys.argv[2])))' "$HS_STATE_DB" "$1"; }

echo "-- a fresh database has the columns"
sdb emit storage.new S1 "first" >/dev/null
check_eq "columns" "id,time,kind,subject,text,source,level,payload,v" "$(q "SELECT group_concat(name) FROM pragma_table_info('events')")"
check_eq "user_version" "2" "$(q 'PRAGMA user_version')"

echo "-- an old database migrates"
OLD=$WORK/old.db
python3 - "$(wp "$OLD")" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.executescript("CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT, time INTEGER NOT NULL, kind TEXT NOT NULL, subject TEXT, text TEXT);"
                "INSERT INTO events (time, kind, subject, text) VALUES (100, 'new', 'S1', 'a'), (200, 'missing', 'S2', 'b');")
c.commit()
PY
HS_NOW=300 HS_STATE_DB=$(wp "$OLD") sdb emit job.ok unit-1 >/dev/null
HS_NOW=300 HS_STATE_DB=$(wp "$OLD") sdb emit job.ok unit-2 >/dev/null     # twice is fine
check_eq "old rows kept, defaults and level warn for missing" "new|storage|info|None|1
missing|storage|warn|None|1
ok|job|info|None|1
ok|job|info|None|1" "$(HS_STATE_DB=$(wp "$OLD") q 'SELECT kind, source, level, payload, v FROM events ORDER BY id')"

echo "-- emit"
export HS_STATE_DB=$(wp "$WORK/d/e.db")
HS_NOW=1000 sdb emit storage.worse S9 $'line one\nline two\tx' --level error --payload '{"a":1}'
check_eq "one row, flattened text, payload kept" "1|storage|worse|S9|error|line one line two x|{\"a\":1}|1000" \
  "$(q 'SELECT count(*), source, kind, subject, level, text, payload, time FROM events')"
HS_NOW=1000 sdb emit storage.new S8 t --payload '[1,2]'
HS_NOW=1000 sdb emit storage.new S7 t --payload 'nonsense'
check_eq "a payload that is not an object is dropped, the row stays" "None|None" "$(q "SELECT group_concat(payload), 'None' FROM events WHERE subject IN ('S8','S7')" | sed 's/^$/None/;s/^|/None|/')"
sdb emit nodot S1 2>/dev/null; check_eq "kind without a dot exits 2" "2" "$?"
sdb emit storage.new S1 --level loud 2>/dev/null; check_eq "bad level exits 2" "2" "$?"
check_eq "event-list line shape" "1	1000	storage	worse	S9	error	line one line two x	{\"a\":1}" "$(sdb event-list 10 --source storage --after 0 | awk -F'\t' '$1 == 1')"
check_eq "event-list --after" "2" "$(sdb event-list --after 1 | wc -l | tr -d ' ')"
check_eq "event-list --source" "0" "$(sdb event-list --source job | wc -l | tr -d ' ')"
check_eq "empty fields are -" "-" "$(sdb event-list 1 | cut -f8)"

echo "-- retention"
export HS_STATE_DB=$(wp "$WORK/d/r.db")
for i in 1 2 3 4 5 6 7 8; do HS_EVENT_KEEP=5 HS_NOW=$((2000000000 + i)) sdb emit job.ok "u$i"; done
check_eq "newest 5 stay" "u4,u5,u6,u7,u8" "$(q 'SELECT group_concat(subject) FROM (SELECT subject FROM events ORDER BY id)')"
HS_EVENT_DAYS=1 HS_NOW=$((2000000000 + 3 * 86400)) sdb emit job.ok fresh
check_eq "older than the age limit goes" "fresh" "$(q 'SELECT group_concat(subject) FROM events')"

echo "-- events and events-json for legacy rows are unchanged"
export HS_STATE_DB=$(wp "$WORK/d/l.db")
HS_NOW=50 sdb emit storage.new S1234567 "Disk (S/N S1234567) seen"
check_eq "events" "50	new	S1234567	Disk (S/N S1234567) seen" "$(sdb events)"
check_eq "events-json" '{"schema":1,"events":[{"time":50,"kind":"new","id":"...4567","text":"Disk (S/N ...4567) seen"}]}' "$(sdb events-json)"

echo "-- event_emit never fails the caller"
export HS_STATE_DB=$(wp "$WORK/d/f.db")
( . "$SCRIPTS/lib/event.sh"; event_emit job.ok x "t"; event_emit nodot x; echo "rc=$?" ) > "$WORK/o1" 2>&1
check_eq "bad kind still rc 0" "rc=0" "$(tail -n1 "$WORK/o1")"
check_eq "good kind wrote" "1" "$(q 'SELECT count(*) FROM events')"
( unset HS_EVENT_NOROOT; . "$SCRIPTS/lib/event.sh"; id() { echo 1000; }; event_emit job.ok y; echo "rc=$?" ) > "$WORK/o2" 2>&1
check_eq "not root: rc 0 and nothing written" "rc=0 1" "$(tail -n1 "$WORK/o2") $(q 'SELECT count(*) FROM events')"
( export HS_STATE_DB=$(wp "$WORK/no/such/dir/x.db"); HS_PYTHON=false; . "$SCRIPTS/lib/event.sh"; event_emit job.ok z; echo "rc=$?" ) > "$WORK/o3" 2>&1
check_eq "failing writer: rc 0" "rc=0" "$(tail -n1 "$WORK/o3")"

echo "-- every emitted kind is registered"
KINDS=$SCRIPTS/lib/event-kinds.tsv
bad=""
used=$( { grep -rhoE '(event_emit|hs event emit|state-db\.py emit|db emit)[[:space:]]+"?[a-z0-9]+\.[a-z0-9.-]+' "$SCRIPTS" "$ROOT/capabilities" 2>/dev/null \
          | grep -v '^ *#' | sed -E 's/.*[[:space:]]"?//'; } | sort -u)
for k in $used; do
  case "$k" in ext.*) continue ;; esac
  grep -q "^${k}	" "$KINDS" || bad="$bad $k"
done
check_eq "no unregistered kind" "" "$bad"
check_eq "kinds file has 4 columns" "" "$(grep -v '^#' "$KINDS" | awk -F'\t' 'NF != 4 {print $1}')"
check_eq "kind names are <area>.<what>, lower case" "" "$(grep -v '^#' "$KINDS" | cut -f1 | grep -vE '^[a-z][a-z0-9]*(\.[a-z0-9][a-z0-9-]*)+$' || true)"
check_eq "levels are info, warn or error" "" "$(grep -v '^#' "$KINDS" | awk -F'	' '$2 !~ /^(info|warn|error)$/ {print $1}')"
check_eq "payload keys are - or snake_case words" "" "$(grep -v '^#' "$KINDS" | awk -F'	' '$3 != "-" && $3 !~ /^[a-z][a-z0-9_]*\??(,[a-z][a-z0-9_]*\??)*$/ {print $1}')"
check_eq "no kind is listed twice" "" "$(grep -v '^#' "$KINDS" | cut -f1 | sort | uniq -d)"
echo "-- other sources stay out of the disk events"
export HS_STATE_DB=$(wp "$WORK/d/s.db")
HS_NOW=50 sdb emit storage.new S1 "disk"
HS_NOW=60 sdb emit job.failed unit-1 "backup to 10.0.0.5 failed"
check_eq "events lists storage only" "50	new	S1	disk" "$(sdb events)"
check_eq "events-json lists storage only" "1" "$(sdb events-json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["events"]))')"
check_eq "event-list lists both" "2" "$(sdb event-list | wc -l | tr -d ' ')"

echo "-- the level comes from event-kinds.tsv"
HS_NOW=70 sdb emit job.failed unit-2
HS_NOW=70 sdb emit storage.missing S2
HS_NOW=70 sdb emit nope.thing x
HS_NOW=70 sdb emit job.failed unit-3 "" --level info
check_eq "default levels" "unit-2 error,S2 warn,x info,unit-3 info" "$(sdb event-list 4 | awk -F'	' '{printf "%s%s %s", (NR > 1 ? "," : ""), $5, $6}')"

echo "-- NaN and Infinity are not JSON"
HS_NOW=80 sdb emit storage.new N1 t --payload '{"a":NaN}'
HS_NOW=80 sdb emit storage.new N2 t --payload '{"a":Infinity}'
check_eq "payload dropped, rows written" "N1 -
N2 -" "$(sdb event-list 2 | awk -F'	' '{print $5, $8}')"

echo "-- migration leaves no write lock and two starters do not collide"
O2=$WORK/old2.db
python3 - "$(wp "$O2")" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("PRAGMA journal_mode=WAL")   # an installed server is in WAL mode already
c.executescript("CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT, time INTEGER NOT NULL, kind TEXT NOT NULL, subject TEXT, text TEXT);"
                "INSERT INTO events (time, kind, subject, text) VALUES (100, 'missing', 'S2', 'b');")
c.commit()
PY
export HS_STATE_DB=$(wp "$O2")
for i in 1 2 3 4; do HS_NOW=300 sdb emit job.ok "p$i" 2>"$WORK/p$i.err" & done
wait
check_eq "four parallel first starts: no error output" "" "$(cat "$WORK"/p?.err)"
check_eq "all rows there" "5" "$(q 'SELECT count(*) FROM events')"
check_eq "no write lock left behind" "ok" "$(python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1], timeout=0); c.execute("BEGIN IMMEDIATE"); c.rollback(); print("ok")' "$HS_STATE_DB")"

echo "-- german texts and the i18n list"
for k in "No events yet." "Could not write the event %s (exit %s)" "Writing to the event log needs root: sudo hs event emit ..."; do
  check "German text: $k" grep -qF "$k	" "$SCRIPTS/lib/i18n/de.tsv"
done
check "event.sh is in the i18n CORE list" grep -q ' event lib/event"' "$ROOT/tests/i18n.sh"
check "sys event list is a GET read" python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert "get" in d["paths"]["/event/list"]' "$ROOT/docs/api/openapi.json"
finish
