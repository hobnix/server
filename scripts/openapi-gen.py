#!/usr/bin/env python3
"""The `hs sys` contract as one OpenAPI 3.1 document (docs/api/openapi.json; ADR 0001, "Must" item 3).

  openapi-gen.py write                 regenerate docs/api/openapi.json
  openapi-gen.py check [--registry F]  same, but change nothing: exit 1 when the file is stale (tests/openapi.sh)

Sources: the `sys` rows of scripts/lib/registry.tsv (one operation each), the READS table of scripts/web-serve.py (x-hs-web),
and docs/api/sys.toml (hand-written field shapes). The document describes the CLI (words, argv, lines, exit codes), not the web JSON.
The output file is generated: never edit it by hand. Python stdlib only.
"""
import importlib.util
import json
import os
import re
import sys
import tomllib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REGISTRY = os.path.join(ROOT, "scripts", "lib", "registry.tsv")
SHAPES = os.path.join(ROOT, "docs", "api", "sys.toml")
OUT = os.path.join(ROOT, "docs", "api", "openapi.json")
KINDS = ("tsv", "json", "text")
MIME = {"tsv": "text/tab-separated-values", "json": "application/json", "text": "text/plain"}
# Copied from tests/web-login-test.py (a heuristic, not shared): words that make a row change something.
CHANGING = {"plan", "start", "stop", "forget", "test", "collect", "delete", "purge", "measure", "unlock", "scheduled",
            "mount-all", "event", "history-record", "alarm", "boot", "stdin", "started", "stopping"}
CHANGE_KEYS = ["status", "reason", "heading", "needs", "step", "note", "warn", "danger", "section", "text", "command",
               "confirm_name", "long", "option", "fix", "unit", "id"]
STATUS = ["done", "needs", "ok", "refused", "started"]    # `status<TAB>...` in scripts/*-change.sh (needs: exit 2); tests/openapi.sh cross-checks
FAILED = {"description": "failed; stderr says why, stdout may be empty"}
FIELD = {"$ref": "#/components/schemas/Field"}
LINES = {"schema": {"$ref": "#/components/schemas/ChangeLines"}}


class Bad(Exception):
    pass


def load_web():
    os.environ["HS_WEB_QUIET"] = "1"
    spec = importlib.util.spec_from_file_location("web_serve", os.path.join(ROOT, "scripts", "web-serve.py"))
    ws = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ws)
    return ws


def read_rows(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            c = line.split("\t") + [""] * 7
            if c[0] == "sys":
                rows.append({"words": c[1].split()[1:], "script": c[2], "args": c[3], "help": c[4], "flags": c[6].split(",")})
    return rows


def script_help(script):
    try:
        with open(os.path.join(ROOT, "scripts", script), encoding="utf-8") as f:
            for line in f:
                if line.startswith("# help:"):
                    return line[len("# help:"):].strip()
    except OSError:
        pass
    return ""


def generic(words):
    return tuple("<x>" if w.startswith("<") else w for w in words)


def reads_map(ws):
    """row words with <x> -> READS spec (a positional query also matches the row with one more value)"""
    m = {}
    for key, spec in ws.READS.items():
        base = key + ("<x>",) * len(spec.get("args", []))
        m[base] = (spec, False)
        if any(isinstance(q, tuple) and len(q) > 1 and q[1] == "" for q in spec.get("query", {}).values()):
            m[base + ("<x>",)] = (spec, True)    # the same read with the positional query value: web form is ?name=value
    return m


def field(title, enum=None):
    d = dict(FIELD, title=title)
    if enum:
        d["enum"] = enum
    return d


def shape_schema(shape):
    """The schema of a tsv output from a sys.toml entry (columns or records)."""
    enums = shape.get("enums", {})
    if "columns" in shape:
        cols = shape["columns"]
        item = {"type": "array", "prefixItems": [field(c, enums.get(c)) for c in cols], "minItems": len(cols), "maxItems": len(cols)}
        return {"type": "array", "items": item}
    options = []
    for tag, fields in shape["records"].items():
        items = [{"const": tag}] + [field(f, enums.get(tag + "." + f, enums.get(f))) for f in fields]
        options.append({"type": "array", "prefixItems": items, "minItems": len(items), "maxItems": len(items)})
    return {"type": "array", "items": {"oneOf": options}}


def validate_shapes(shapes, rows, reads):
    paths = {" ".join(r["words"]): r for r in rows}
    for key, shape in shapes.items():
        if key not in paths:
            raise Bad("docs/api/sys.toml: '%s' is no core sys row" % key)
        kind = shape.get("kind")
        if kind not in KINDS:
            raise Bad("docs/api/sys.toml: '%s' has unknown kind '%s' (tsv, json, text)" % (key, kind))
        if "columns" in shape and "records" in shape:
            raise Bad("docs/api/sys.toml: '%s' sets both columns and records" % key)
        hit = reads.get(generic(paths[key]["words"]))
        spec = hit[0] if hit else None
        if spec and spec["kind"] != kind:
            raise Bad("docs/api/sys.toml: '%s' says kind %s, READS says %s" % (key, kind, spec["kind"]))


def change_lines():
    one = []
    for k in CHANGE_KEYS:
        v = dict(FIELD)
        if k == "status":
            v["enum"] = STATUS
        elif k == "long":
            v["enum"] = ["yes", "no"]
        elif k == "unit":
            v["pattern"] = r"^hs-[A-Za-z0-9@._-]{1,80}$"
        one.append({"type": "array", "prefixItems": [{"const": k}, v], "minItems": 2, "maxItems": 2})
    one.append({"type": "array", "prefixItems": [{"type": "string"}, dict(FIELD)], "minItems": 2, "maxItems": 2,
                "x-hs-note": "see parse_change in scripts/web-serve.py"})
    return one


def operation(r, shape, hit, ws):
    spec = hit[0] if hit else None
    words = r["words"]
    fixed = [w for w in words if not w.startswith("<")]
    cls = "plan" if "plan" in fixed else "start" if "start" in fixed else         "change" if CHANGING & set(fixed) or "changes" in r["flags"] else "read"
    params = [w[1:-1] for w in words if w.startswith("<")]
    op = {"operationId": ".".join(("by_" + w[1:-1]) if w.startswith("<") else w for w in words),
          "summary": r["help"] if r["help"] not in ("", "-") else script_help(r["script"]) or " ".join(words),
          "x-hs-exit": True}
    xs = {"words": words, "script": r["script"], "args": r["args"], "class": cls, "rest": "{rest}" in r["args"]}
    if cls == "start":
        xs["confirm"] = "--confirm <name>, the name the plan's confirm_name line asks for"
    op["x-hs-sys"] = xs
    if spec:
        op["x-hs-web"] = {"path": "/api/sys/" + "/".join(words[:-1] if hit[1] else words), "kind": spec["kind"], "ttl": spec.get("ttl"),
                          "query": list(spec.get("query", {}))}
    if params:
        op["parameters"] = [{"name": p, "in": "path", "required": True, "schema": {"type": "string"}} for p in params]
    stdin = shape.get("stdin")
    if stdin:
        op["requestBody"] = {"required": True, "content": {"text/plain": {"schema": {"type": "string"}}},
                             "description": ("one line on stdin: the secret or the document, never in argv or the environment"
                                             if stdin == "line" else "the bytes on stdin")}
    elif cls in ("plan", "start") and any(isinstance(e, dict) and e.get("stdin") for e in ws.CHANGES.get(words[0], [])):
        op["requestBody"] = {"required": False, "content": {"text/plain": {"schema": {"type": "string"}}},
                             "description": "one line on stdin for the entries that take it (a password, a key)"}
    tsv = MIME["tsv"]
    if cls == "plan":
        op["responses"] = {"0": {"description": "allowed", "content": {tsv: LINES}},
                           "1": {"description": "refused; the reason line says why", "content": {tsv: LINES}},
                           "2": {"description": "something is missing; the needs lines say what", "content": {tsv: LINES}}}
    elif cls == "start":
        op["description"] = "a long change starts a job; the `unit` line names it; follow it with `jobs tail`"
        op["responses"] = {"0": {"description": "done or started", "content": {tsv: LINES}},
                           "1": {"description": "refused", "content": {tsv: LINES}},
                           "2": {"description": "something is missing", "content": {tsv: LINES}}}
    else:
        described = "columns" in shape or "records" in shape
        if cls == "read":
            kind = shape.get("kind") or (spec["kind"] if spec else None)
        else:
            kind = shape.get("kind") or "text"
        if not described:
            op["x-hs-described"] = False
        if "note" in shape:
            op["description"] = shape["note"]
        schema = shape_schema(shape) if described else {"type": "string"}
        op["responses"] = {"0": {"description": "ok", "content": {MIME[kind or "text"]: {"schema": schema}}},
                           "default": dict(FAILED)}
    return cls, op


def build(registry):
    with open(SHAPES, "rb") as f:
        shapes = tomllib.load(f)
    ws = load_web()
    rows = read_rows(registry)
    reads = reads_map(ws)
    validate_shapes(shapes, rows, reads)
    with open(os.path.join(ROOT, "scripts", "lib", "api-level"), encoding="utf-8") as f:
        level = f.read().strip()
    paths, seen = {}, {}
    for r in rows:
        words = r["words"]
        url = "/" + "/".join("{" + w[1:-1] + "}" if w.startswith("<") else w for w in words)
        shape_key = re.sub(r"\{[^}]*\}", "{}", url)
        if shape_key in seen:
            print("warn: same path shape: %s / %s" % (seen[shape_key], url), file=sys.stderr)
        seen[shape_key] = url
        cls, op = operation(r, shapes.get(" ".join(words), {}), reads.get(generic(words)), ws)
        paths[url] = {("get" if cls == "read" else "post"): op}
    doc = {
        "openapi": "3.1.0",
        "info": {
            "title": "hs sys contract", "version": level,
            "description": ("The `hs sys` words as an API. One path segment is one argv word. A tsv output is one row per line, "
                            "fields separated by tabs, an empty field written -. Machine lines never change shape. Secrets go on "
                            "stdin only. HS_CALLER (cli, web, job, timer, test) tells the script who calls. Plan and start exit 0 "
                            "(allowed), 1 (refused) or 2 (something is missing). Generated by scripts/openapi-gen.py from "
                            "scripts/lib/registry.tsv and docs/api/sys.toml; never edit by hand. Open: whether a change to a "
                            "described shape bumps scripts/lib/api-level is not decided; for now it does not."),
        },
        "servers": [{"url": "hs:sys"}],
        "paths": {k: paths[k] for k in sorted(paths)},
        "components": {"schemas": {
            "Field": {"type": "string", "description": "one tab-separated field; an empty value is written -"},
            "ChangeLines": {"type": "array", "items": {"oneOf": change_lines()}},
        }},
    }
    return json.dumps(doc, indent=1, ensure_ascii=False, sort_keys=False) + "\n"


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    registry = argv[argv.index("--registry") + 1] if "--registry" in argv else REGISTRY
    if cmd not in ("write", "check"):
        print(__doc__)
        return 2
    try:
        want = build(registry)
    except Bad as e:
        print("error: %s" % e, file=sys.stderr)
        return 1
    if cmd == "write":
        with open(OUT, "w", encoding="utf-8", newline="\n") as f:
            f.write(want)
        return 0
    have = None
    if os.path.exists(OUT):
        with open(OUT, encoding="utf-8", newline="") as f:
            have = f.read()
    if have != want:
        print("docs/api/openapi.json is stale: run python3 scripts/openapi-gen.py write", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
