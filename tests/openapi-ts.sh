#!/usr/bin/env bash
# The TypeScript declarations of the `hs sys` contract (web/src/api/sys.gen.d.ts, scripts/openapi-ts-gen.py) match docs/api/openapi.json.
# No root, no server, no node (python3 only).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
GEN="python3 $SCRIPTS/openapi-ts-gen.py"
OUT=$ROOT/web/src/api/sys.gen.d.ts

echo "-- the committed file is current"
check "web/src/api/sys.gen.d.ts is up to date (else: python3 scripts/openapi-ts-gen.py write)" $GEN check

echo "-- a changed openapi.json makes it stale"
python3 - "$ROOT/docs/api/openapi.json" "$WORK/openapi.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
d["paths"]["/zz-test/probe"] = {"get": {"operationId": "zz-test.probe", "summary": "probe",
    "x-hs-sys": {"words": ["zz-test", "probe"], "class": "read"},
    "responses": {"0": {"description": "ok", "content": {"text/plain": {"schema": {"type": "string"}}}}}}}
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"))
EOF
rc=0; err=$($GEN check --openapi "$WORK/openapi.json" 2>&1 >/dev/null) || rc=$?
check_eq "check exits 1 with an extra operation" "1" "$rc"
check_out "check says stale" "stale" echo "$err"

echo "-- the file says it is generated"
check_out "header names the generator" "GENERATED from docs/api/openapi.json by scripts/openapi-ts-gen.py: never edit by hand" head -n 1 "$OUT"
check_out "header names the regenerate command" "python3 scripts/openapi-ts-gen.py write" head -n 3 "$OUT"

finish
