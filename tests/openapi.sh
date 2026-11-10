#!/usr/bin/env bash
# The OpenAPI document of the `hs sys` contract (docs/api/openapi.json, scripts/openapi-gen.py) matches the registry and docs/api/sys.toml.
# No root, no server (needs python3 with tomllib).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
GEN="python3 $SCRIPTS/openapi-gen.py"
T=$'\t'

echo "-- the committed document is current"
check "docs/api/openapi.json is up to date (else: python3 scripts/openapi-gen.py write)" $GEN check

echo "-- a new sys row makes it stale"
cp "$SCRIPTS/lib/registry.tsv" "$WORK/reg.tsv"
printf 'sys\tsys zz-test probe\tjobs.sh\t--list\tprobe\t-\t\n' >> "$WORK/reg.tsv"
rc=0; err=$($GEN check --registry "$WORK/reg.tsv" 2>&1 >/dev/null) || rc=$?
check_eq "check exits 1 with an extra row" "1" "$rc"
check_out "check says stale" "stale" echo "$err"

echo "-- docs/api/sys.toml has no entry without a row"
bad=$(python3 - "$ROOT" <<'EOF'
import sys, tomllib
root = sys.argv[1]
rows = set()
for line in open(root + "/scripts/lib/registry.tsv", encoding="utf-8"):
    c = line.rstrip("\n").split("\t")
    if c[0] == "sys":
        rows.add(c[1].split(" ", 1)[1])
for k in tomllib.load(open(root + "/docs/api/sys.toml", "rb")):
    if k not in rows:
        print(k)
EOF
)
check_eq "every sys.toml key is a core sys row" "" "$bad"

echo "-- the document parses and agrees with the registry"
got=$(python3 - "$ROOT" <<'EOF'
import json, sys
root = sys.argv[1]
d = json.load(open(root + "/docs/api/openapi.json", encoding="utf-8"))
ops = sum(len(v) for v in d["paths"].values())
rows = sum(1 for l in open(root + "/scripts/lib/registry.tsv", encoding="utf-8") if l.startswith("sys\t"))
level = open(root + "/scripts/lib/api-level", encoding="utf-8").read().strip()
print("ok" if ops == rows and d["info"]["version"] == level else "operations %d, rows %d, version %s, api-level %s" % (ops, rows, d["info"]["version"], level))
EOF
)
check_eq "one operation per sys row, version equals api-level" "ok" "$got"

echo "-- the status words the scripts print are in the document"
got=$(python3 - "$ROOT" <<'EOF'
import glob, json, re, sys
root = sys.argv[1]
found = set()
for f in glob.glob(root + "/scripts/*-change.sh"):
    found |= set(re.findall(r"""['"]status\\t([a-z_-]+)""", open(f, encoding="utf-8").read()))
d = json.load(open(root + "/docs/api/openapi.json", encoding="utf-8"))
enum = set(d["components"]["schemas"]["ChangeLines"]["items"]["oneOf"][0]["prefixItems"][1]["enum"])
print("ok" if found == enum else "scripts print %s, STATUS has %s (edit STATUS in scripts/openapi-gen.py)" % (sorted(found), sorted(enum)))
EOF
)
check_eq "STATUS in openapi-gen.py equals the status words of scripts/*-change.sh" "ok" "$got"

finish
