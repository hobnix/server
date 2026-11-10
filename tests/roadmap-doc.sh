#!/usr/bin/env bash
# docs/roadmap.md: the generated blocks (scripts/roadmap-gen.py) come from the project board and TODO.md. The board is not fetched here:
# a small fixture stands in. No root, no server, no network.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
GEN="python3 $SCRIPTS/roadmap-gen.py"
DOC="$SCRIPTS/../docs/roadmap.md"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

cat >"$T/board.json" <<'JSON'
{"items":[
 {"title":"Epic: One","status":"In Progress","priority":"P0","milestone":{"title":"0.1 — First"},"content":{"number":1,"repository":"hobnix/server","url":"https://github.com/hobnix/server/issues/1"}},
 {"title":"Done thing | with pipe","status":"Done","milestone":{"title":"0.1 — First"},"content":{"number":2,"repository":"hobnix/server","url":"https://github.com/hobnix/server/issues/2"}},
 {"title":"Unplanned","status":"Backlog","content":{"number":3,"repository":"hobnix/server","url":"https://github.com/hobnix/server/issues/3"}}
]}
JSON
cat >"$T/TODO.md" <<'MD'
## A. First
1. [x] Finished thing.
2. [~] (merged #1) Half done: the rest follows
3. [ ] Later
MD

echo "-- the committed page has its markers and no raw HTML"
check "board block markers" grep -q "BEGIN board" "$DOC"
check "todo block markers" grep -q "BEGIN todo" "$DOC"
check "names the board as the source" grep -q "The source is the GitHub project board" "$DOC"
check_eq "no raw HTML" "" "$(grep -E '<(p|br|div|span|details|img|a|table)[ >/]' "$DOC" || true)"

echo "-- write and check"
cp "$DOC" "$T/roadmap.md"
check "write from a fixture" $GEN write --board "$T/board.json" --todo "$T/TODO.md" --doc "$T/roadmap.md"
check "a fresh page is current" $GEN check --board "$T/board.json" --todo "$T/TODO.md" --doc "$T/roadmap.md"
check_out "a milestone is a heading" "### 0.1 — First" cat "$T/roadmap.md"
check_out "an issue without a milestone is listed" "### No milestone" cat "$T/roadmap.md"
# milestones are in the order of their versions, not of their text: 0.2 before 0.10
python3 - "$T/board.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
for n, ms in ((7, "0.10 — Tenth"), (8, "0.2 — Second")):
    d["items"].append({"title": "T%d" % n, "status": "Backlog", "milestone": {"title": ms},
                       "content": {"number": n, "repository": "hobnix/server", "url": "https://github.com/hobnix/server/issues/%d" % n}})
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False)
PY
$GEN write --board "$T/board.json" --todo "$T/TODO.md" --doc "$T/roadmap.md" >/dev/null
check_eq "milestones are sorted by version" "0.1 0.2 0.10" "$(grep -oE '^### [0-9.]+' "$T/roadmap.md" | cut -d' ' -f2 | paste -sd' ')"
check_out "done issues are listed in one line" 'Done: .#2' cat "$T/roadmap.md"
check_out "a TODO item is listed with its state" "| A2 | in progress | Half done |" cat "$T/roadmap.md"
sed -i 's/Epic: One/Epic: Renamed/' "$T/board.json"
if $GEN check --board "$T/board.json" --todo "$T/TODO.md" --doc "$T/roadmap.md" >/dev/null 2>&1; then fail "a changed board was not noticed"; else pass "a stale page is detected"; fi

finish
