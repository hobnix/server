#!/usr/bin/env bash
# Change counters (docs/adr/0005-events.md rule 5): the table `topics` of state.db, `state-db.py topic-bump` (names, @group, --all), the
# collector's bump in `read-put`, and scripts/lib/live.sh live_refresh counting up without Redis. python3 stdlib only, no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
command -v python3 >/dev/null || { echo "python3 missing: skipped"; exit 0; }
wp() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
export HS_PLAIN=1 HS_LANG=en HS_CALLER=test
mkdir -p "$WORK/d"
export HS_STATE_DB=$(wp "$WORK/d/state.db")
SD=$SCRIPTS/state-db.py
sdb() { python3 "$SD" "$@"; }
q() { python3 -c 'import sqlite3,sys; sys.stdout.reconfigure(newline=chr(10)); c=sqlite3.connect(sys.argv[1]); print(chr(10).join("|".join(str(x) for x in r) for r in c.execute(sys.argv[2])))' "$HS_STATE_DB" "$1"; }
gens() { q "SELECT group_concat(topic || '=' || gen, ',') FROM (SELECT * FROM topics ORDER BY topic)"; }

printf 'status\tstatus\t15\trun\t-\tany\nshares\tshares\t30\trun\t-\tstorage\nct\tct list\t30\trun\t-\tinstances\n' >"$WORK/topics.tsv"
export HS_LIVE_TOPICS=$(wp "$WORK/topics.tsv")

echo "-- topic-bump"
sdb topic-bump status >/dev/null; check_eq "first bump" "status=1" "$(gens)"
sdb topic-bump status shares >/dev/null; check_eq "second bump" "shares=1,status=2" "$(gens)"
sdb topic-bump @storage >/dev/null; check_eq "group = its topics and any" "shares=2,status=3" "$(gens)"
sdb topic-bump --all >/dev/null; check_eq "all" "ct=1,shares=3,status=4" "$(gens)"
sdb topic-bump 'bad;name' >/dev/null; check_eq "bad name ignored" "ct=1,shares=3,status=4" "$(gens)"
check_eq "exit code" "0" "$(sdb topic-bump nobody-home >/dev/null; echo $?)"

echo "-- the collector bumps reads:<key> only when the output changed"
printf 'a' | sdb read-put "monitor disks"
check_eq "new output" "1" "$(q "SELECT gen FROM topics WHERE topic='reads:monitor disks'")"
printf 'a' | sdb read-put "monitor disks"
check_eq "same output" "1" "$(q "SELECT gen FROM topics WHERE topic='reads:monitor disks'")"
printf 'b' | sdb read-put "monitor disks"
check_eq "other output" "2" "$(q "SELECT gen FROM topics WHERE topic='reads:monitor disks'")"

echo "-- live_refresh counts up without Redis"
unset HS_LIVE_LOG
export HS_LIVE_SOCKET=$WORK/none.sock
( . "$SCRIPTS/lib/live.sh"; live_refresh ct )
check_eq "live_refresh" "2" "$(q "SELECT gen FROM topics WHERE topic='ct'")"
HS_LIVE_LOG=$WORK/log bash -c ". '$SCRIPTS/lib/live.sh'; live_refresh ct"
check_eq "test knob does not count" "2" "$(q "SELECT gen FROM topics WHERE topic='ct'")"
finish
