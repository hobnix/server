#!/usr/bin/env python3
"""Builds the bundle tests/web-files-contract.mjs reads: the REAL outputs of scripts/fm.sh (tests/fixtures/fm/*.out, made by capture.sh) turned into what the web server
would answer, with the web server's own code (scripts/web-serve.py): a tsv read is {"rows": [[fields]]}, a change goes through parse_change(out, rc).
usage: web-files-contract-build.py <fixtures dir> <output.json>"""
import importlib.util
import json
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("web_serve", os.path.join(here, "..", "scripts", "web-serve.py"))
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)

src, dst = sys.argv[1], sys.argv[2]
bundle = {}
for f in sorted(os.listdir(src)):
    if not f.endswith(".out"):
        continue
    name = f[:-4]
    out = open(os.path.join(src, f), encoding="utf-8").read()
    rc = int(open(os.path.join(src, name + ".rc")).read().strip() or 0)
    if name.startswith(("plan-", "start-")):
        bundle[name] = ws.parse_change(out, rc)
    else:
        bundle[name] = {"rows": [line.split("\t") for line in out.splitlines() if line != ""], "rc": rc}
with open(dst, "w", encoding="utf-8") as fh:
    json.dump(bundle, fh)
