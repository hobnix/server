#!/usr/bin/env bash
# One refresh vocabulary (docs/adr/0005-events.md rule 11, #294): every group AREA_GROUP in scripts/web-serve.py names must be a
# group the live-state topics (scripts/lib/live-topics.tsv, column 6) wake, and a `topic:` word of the registry. Until the web reads
# the groups from those files, this keeps the three lists in step.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
PY=${HS_PYTHON:-python3}
cat > "$WORK/groups.py" <<'PYEOF'
import ast, re, sys
tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())
area = next(n.value for n in tree.body if isinstance(n, ast.Assign) and getattr(n.targets[0], "id", "") == "AREA_GROUP")
web = set(ast.literal_eval(area).values())
live = set()
for line in open(sys.argv[2], encoding="utf-8"):
    if line.startswith("#") or not line.strip():
        continue
    live.update(g for g in line.rstrip("\n").split("\t")[5].split(",") if g not in ("-", "any"))
reg = set(re.findall(r"topic:([a-z-]+)", open(sys.argv[3], encoding="utf-8").read()))
print("web", len(web))
print("notlive", " ".join(sorted(web - live)))
print("notreg", " ".join(sorted(web - reg)))
PYEOF
out=$("$PY" -I "$WORK/groups.py" "$SCRIPTS/web-serve.py" "$SCRIPTS/lib/live-topics.tsv" "$SCRIPTS/lib/registry.tsv")
check "AREA_GROUP has groups" test "$(sed -n 's/^web //p' <<<"$out")" -gt 0
check_eq "every AREA_GROUP group is woken by a live topic" "notlive " "$(grep '^notlive' <<<"$out")"
check_eq "every AREA_GROUP group is a registry topic: word" "notreg " "$(grep '^notreg' <<<"$out")"
finish
