#!/usr/bin/env python3
"""TypeScript declarations for the `hs sys` contract (web/src/api/sys.gen.d.ts; epic #121, issue #124).

  openapi-ts-gen.py write                  regenerate web/src/api/sys.gen.d.ts from docs/api/openapi.json
  openapi-ts-gen.py check [--openapi F]    same, but change nothing: exit 1 when the file is stale (tests/openapi-ts.sh)

The web is plain JavaScript, so the output is a declaration file used through JSDoc:
  /** @param {import('./api/sys.gen').SysLines<'live.status'>} rows */
The output file is generated: never edit it by hand. Python stdlib only.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "docs", "api", "openapi.json")
OUT = os.path.join(ROOT, "web", "src", "api", "sys.gen.d.ts")
RESERVED = {"break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "enum", "export",
            "extends", "false", "finally", "for", "function", "if", "import", "in", "instanceof", "new", "null", "return", "super",
            "switch", "this", "throw", "true", "try", "typeof", "var", "void", "while", "with"}
HEADER = """// GENERATED from docs/api/openapi.json by scripts/openapi-ts-gen.py: never edit by hand.
// Regenerate: python3 scripts/openapi-ts-gen.py write (in the same commit as a change to docs/api/openapi.json).
// Use through JSDoc, e.g. @param {import('./api/sys.gen').SysLines<'live.status'>} rows
"""


class Bad(Exception):
    pass


def q(s):
    return json.dumps(s, ensure_ascii=False)


def label(title, used):
    n = re.sub(r"\W", "_", str(title)) or "field"
    if n[0].isdigit() or n in RESERVED:
        n = "_" + n
    base, i = n, 2
    while n in used:
        n, i = "%s%d" % (base, i), i + 1
    used.add(n)
    return n


def ts(s):
    """OpenAPI schema (the subset openapi-gen.py writes) -> TypeScript type"""
    if "$ref" in s:
        t = s["$ref"].rsplit("/", 1)[-1]
        if "enum" in s:
            return " | ".join(q(v) for v in s["enum"])
        return t
    if "const" in s:
        return q(s["const"])
    if "oneOf" in s:
        return "\n  | ".join(ts(o) for o in s["oneOf"])
    kind = s.get("type")
    if kind == "string":
        return "string"
    if kind == "array":
        if "prefixItems" in s:
            used = set()
            parts = []
            for p in s["prefixItems"]:
                name = label(p.get("title", "tag" if "const" in p else "field"), used)
                parts.append("%s: %s" % (name, ts(p)))
            return "[" + ", ".join(parts) + "]"
        inner = ts(s["items"])
        return "(%s)[]" % inner if "|" in inner or "\n" in inner else inner + "[]"
    raise Bad("unsupported schema: %s" % json.dumps(s)[:120])


def lines_type(op):
    """the type of the stdout lines of the exit-0 response"""
    content = op["responses"]["0"]["content"]
    mime, body = next(iter(content.items()))
    if mime == "application/json":
        return "unknown"
    if mime == "text/plain":
        return "string"
    schema = body["schema"]
    return "string[][]" if schema == {"type": "string"} else ts(schema)


def member(url, method, op):
    xs = op["x-hs-sys"]
    params = "".join("%s: string; " % label(p["name"], set()) for p in op.get("parameters", []))
    exits = "0 | 1 | 2" if xs["class"] in ("plan", "start") else "number"
    stdin = "yes" if op.get("requestBody", {}).get("required") else "no" if "requestBody" in op else "none"
    return "\n".join([
        "  %s: {" % q(op["operationId"]),
        "    /** %s */" % op["summary"].replace("*/", "* /").replace("\n", " "),
        "    words: [%s];" % ", ".join(q(w) for w in xs["words"]),
        "    path: %s;" % q(url),
        "    method: %s;" % q(method),
        "    class: %s;" % q(xs["class"]),
        "    params: { %s};" % params,
        "    stdin: %s;" % q(stdin),
        "    exit: %s;" % exits,
        "    lines: %s;" % lines_type(op).replace("\n", "\n    "),
        "  };",
    ])


def build(openapi):
    with open(openapi, encoding="utf-8") as f:
        doc = json.load(f)
    out = [HEADER]
    for name, schema in doc["components"]["schemas"].items():
        if "description" in schema:
            out.append("/** %s */" % schema["description"])
        out.append("export type %s = %s;\n" % (name, ts({k: v for k, v in schema.items() if k != "description"})))
    out.append("/** Every `hs sys` operation by operationId: its words, URL path, the shape of stdout lines and the exit codes. */")
    out.append("export interface SysOperations {")
    ops = []
    for url in sorted(doc["paths"]):
        for method, op in doc["paths"][url].items():
            ops.append((op["operationId"], member(url, method, op)))
    seen = set()
    for oid, text in sorted(ops):
        if oid in seen:
            raise Bad("duplicate operationId %s" % oid)
        seen.add(oid)
        out.append(text)
    out.append("}\n")
    out.append("export type SysOperationId = keyof SysOperations;")
    out.append("/** the lines one operation prints on stdout (exit 0) */")
    out.append("export type SysLines<K extends SysOperationId> = SysOperations[K][\"lines\"];")
    out.append("/** one line of it */")
    out.append("export type SysLine<K extends SysOperationId> = SysOperations[K][\"lines\"] extends (infer L)[] ? L : never;")
    return "\n".join(out) + "\n"


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    openapi = argv[argv.index("--openapi") + 1] if "--openapi" in argv else SRC
    if cmd not in ("write", "check"):
        print(__doc__)
        return 2
    try:
        want = build(openapi)
    except (Bad, OSError, KeyError, ValueError) as e:
        print("error: %s" % e, file=sys.stderr)
        return 1
    if cmd == "write":
        os.makedirs(os.path.dirname(OUT), exist_ok=True)
        with open(OUT, "w", encoding="utf-8", newline="\n") as f:
            f.write(want)
        return 0
    have = None
    if os.path.exists(OUT):
        with open(OUT, encoding="utf-8", newline="") as f:
            have = f.read()
    if have != want:
        print("web/src/api/sys.gen.d.ts is stale: run python3 scripts/openapi-ts-gen.py write", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
