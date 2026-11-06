#!/usr/bin/env python3
"""The "Today" table of docs/events.md, generated from scripts/lib/event-kinds.tsv (so the list cannot drift).

  events-doc-gen.py write    rewrite the table between the BEGIN/END markers in docs/events.md
  events-doc-gen.py check    change nothing: exit 1 when the table is stale (tests/events-doc.sh)

The text between the markers is generated: never edit it by hand. Python stdlib only.
"""
import importlib.util
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def _load_pkg_events():
    spec = importlib.util.spec_from_file_location("pkg_events", os.path.join(ROOT, "scripts", "lib", "pkg_events.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


pkg_events = _load_pkg_events()
TSV = os.path.join(ROOT, "scripts", "lib", "event-kinds.tsv")
DOC = os.path.join(ROOT, "docs", "events.md")
BEGIN = "<!-- BEGIN generated from scripts/lib/event-kinds.tsv (python3 scripts/events-doc-gen.py write) -->"
BEGIN_PKG = "<!-- BEGIN package events generated from scripts/lib/pkg-events (python3 scripts/events-doc-gen.py write) -->"
END = "<!-- END generated -->"


def table(path):
    rows = ["| Kind | Level | Payload keys | Meaning |", "| --- | --- | --- | --- |"]
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            c = line.split("\t")
            if len(c) != 4:
                raise SystemExit("error: %s: need 4 tab-separated columns: %s" % (path, line))
            keys = "none" if c[2] == "-" else ", ".join("`%s`" % k for k in c[2].split(","))
            rows.append("| `%s` | %s | %s | %s |" % (c[0], c[1], keys, c[3].replace("|", "\\|")))
    return "\n".join(rows)


def pkg_table(d):
    rows = ["| Kind | Level | Payload keys | Meaning | Push message |", "| --- | --- | --- | --- | --- |"]
    for name in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        if not name.endswith(".tsv"):
            continue
        for r in pkg_events.read_file(os.path.join(d, name), name[:-4]):
            keys = "none" if r["payload"] == "-" else ", ".join("`%s`" % k for k in r["payload"].split(","))
            push = "none" if r["category"] == "-" else "%s, %s" % (r["category"], "default" if r["priority"] == "-" else r["priority"])
            rows.append("| `%s` | %s | %s | %s | %s |" % (r["kind"], r["level"], keys, r["meaning"].replace("|", "\\|"), push))
    return "\n".join(rows)


def render(text, begin, body):
    a = text.find(begin)
    b = text.find(END, a) if a >= 0 else -1
    if a < 0 or b < 0:
        raise SystemExit("error: docs/events.md has no BEGIN/END markers for %s" % begin[:40])
    return text[:a] + begin + "\n\n" + body + "\n\n" + text[b:]


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd not in ("write", "check"):
        print(__doc__)
        return 2
    tsv = argv[argv.index("--tsv") + 1] if "--tsv" in argv else TSV
    with open(DOC, encoding="utf-8", newline="") as f:
        have = f.read()
    pdir = argv[argv.index("--pkg-dir") + 1] if "--pkg-dir" in argv else pkg_events.CORE_DIR
    want = render(render(have, BEGIN, table(tsv)), BEGIN_PKG, pkg_table(pdir))
    if cmd == "write":
        with open(DOC, "w", encoding="utf-8", newline="\n") as f:
            f.write(want)
        return 0
    if have != want:
        print("docs/events.md is stale: run python3 scripts/events-doc-gen.py write", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
