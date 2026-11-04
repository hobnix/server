#!/usr/bin/env bash
# One refresh vocabulary (docs/adr/0005-events.md rule 11, #294): every group scripts/lib/live-areas.tsv names (the area -> group table
# scripts/web-serve.py loads as AREA_GROUP) must be a group the live-state topics (scripts/lib/live-topics.tsv, column 6) wake, and a
# `topic:` word of the registry.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
PY=${HS_PYTHON:-python3}
cat > "$WORK/groups.py" <<'PYEOF'
import re, sys
areas, live_file, reg_file = sys.argv[1:4]
web = set()
for line in open(areas, encoding="utf-8"):
    if line.startswith("#") or not line.strip():
        continue
    web.add(line.rstrip("\n").split("\t")[1])
live = set()
for line in open(live_file, encoding="utf-8"):
    if line.startswith("#") or not line.strip():
        continue
    live.update(g for g in line.rstrip("\n").split("\t")[5].split(",") if g not in ("-", "any"))
reg = set(re.findall(r"topic:([a-z-]+)", open(reg_file, encoding="utf-8").read()))
print("web", len(web))
print("notlive", " ".join(sorted(web - live)))
print("notreg", " ".join(sorted(web - reg)))
PYEOF
run() { "$PY" -I "$WORK/groups.py" "$1" "$SCRIPTS/lib/live-topics.tsv" "$SCRIPTS/lib/registry.tsv"; }
out=$(run "$SCRIPTS/lib/live-areas.tsv")
check "live-areas.tsv has groups" test "$(sed -n 's/^web //p' <<<"$out")" -gt 0
check_eq "every area group is woken by a live topic" "notlive " "$(grep '^notlive' <<<"$out")"
check_eq "every area group is a registry topic: word" "notreg " "$(grep '^notreg' <<<"$out")"
# negative: an unknown group is reported
printf 'ct\tnosuchgroup\n' > "$WORK/bad.tsv"
bad=$(run "$WORK/bad.tsv")
check_eq "an unknown group is found" "notlive nosuchgroup" "$(grep '^notlive' <<<"$bad")"
# the web loads the same table
check_eq "web-serve.py loads live-areas.tsv" "instances" "$("$PY" -I -c "
import importlib.util,sys
s=importlib.util.spec_from_file_location('w',sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.area_refresh('ct').lstrip('@'))" "$SCRIPTS/web-serve.py")"
finish
