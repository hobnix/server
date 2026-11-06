#!/usr/bin/env python3
"""The generated parts of docs/roadmap.md, from the GitHub project board and TODO.md.

  roadmap-gen.py write [--board FILE] [--todo FILE] [--doc FILE]   rewrite the generated blocks in docs/roadmap.md
  roadmap-gen.py check --board FILE [--todo FILE] [--doc FILE]     change nothing: exit 1 when a block is stale (tests/roadmap-doc.sh)

The board is the source of truth. Without --board, `write` runs `gh project item-list 1 --owner hobnix --limit 500 --format json`
(needs the gh CLI and a login). With --board it reads that JSON from a file, which is what the test does. The text between the markers is
generated: never edit it by hand. Python stdlib only.
"""
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOC = os.path.join(ROOT, "docs", "roadmap.md")
TODO = os.path.join(ROOT, "TODO.md")
BOARD_CMD = ["gh", "project", "item-list", "1", "--owner", "hobnix", "--limit", "500", "--format", "json"]
BLOCKS = {
    "board": ("<!-- BEGIN board (python3 scripts/roadmap-gen.py write) -->", "<!-- END board -->"),
    "todo": ("<!-- BEGIN todo (python3 scripts/roadmap-gen.py write) -->", "<!-- END todo -->"),
}
ORDER = ["In Progress", "In Review", "Ready", "Backlog", "Done"]


def cell(text):
    return text.replace("|", "\\|").replace("\n", " ").strip()


def link(item):
    c = item.get("content") or {}
    repo = c.get("repository", "hobnix/server")
    num = c.get("number")
    if num is None:
        return "-"
    short = "#%d" % num if repo == "hobnix/server" else "%s#%d" % (repo, num)
    return "[%s](%s)" % (short, c.get("url", ""))


def board_block(data):
    items = data["items"]
    by_ms = {}
    for it in items:
        ms = (it.get("milestone") or {}).get("title") or "No milestone"
        by_ms.setdefault(ms, []).append(it)

    def msort(k):
        return (k == "No milestone", k)

    out = []
    for ms in sorted(by_ms, key=msort):
        group = by_ms[ms]
        done = [i for i in group if i.get("status") == "Done"]
        out.append("### %s" % ms)
        out.append("")
        out.append("%d issues, %d done." % (len(group), len(done)))
        out.append("")
        open_items = [i for i in group if i.get("status") != "Done"]

        def key(i):
            st = i.get("status") or "Backlog"
            return (ORDER.index(st) if st in ORDER else 3, i.get("priority") or "P9", (i.get("content") or {}).get("number", 0))

        if open_items:
            out.append("| Issue | Status | Priority | Title |")
            out.append("| --- | --- | --- | --- |")
            for i in sorted(open_items, key=key):
                out.append("| %s | %s | %s | %s |" % (link(i), i.get("status") or "-", i.get("priority") or "-", cell(i.get("title", ""))))
            out.append("")
        if done:
            nums = sorted(done, key=lambda i: (i.get("content") or {}).get("number", 0))
            out.append("Done: " + ", ".join(link(i) for i in nums))
            out.append("")
    return "\n".join(out).rstrip("\n")


def short_text(t):
    t = t.strip()
    t = re.sub(r"^\([^)]*\)\s*", "", t)          # a leading "(merged #325 ...)" note
    t = re.sub(r"\*\*|`", "", t)
    m = re.search(r"(\. |: )", t)
    if m and m.start() >= 20:
        t = t[: m.start()]
    t = t.rstrip(".:")
    return t if len(t) <= 110 else t[:107].rstrip() + "..."


def todo_block(path):
    section = ""
    marks = {" ": "open", "~": "in progress", "?": "needs a decision"}
    rows = []
    counts = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            h = re.match(r"^## ([A-Z])\. (.*)", line)
            if h:
                section = h.group(1)
                counts[section] = [h.group(2).strip(), 0, 0]
                continue
            m = re.match(r"^(\d+)\. \[(.)\] (.*)", line)
            if not m or not section:
                continue
            counts[section][1] += 1
            if m.group(2) == "x":
                counts[section][2] += 1
                continue
            rows.append("| %s%s | %s | %s |" % (section, m.group(1), marks.get(m.group(2), m.group(2)), cell(short_text(m.group(3)))))
    out = ["| Section | Done | Items |", "| --- | --- | --- |"]
    for k, (title, n, d) in counts.items():
        out.append("| %s. %s | %d | %d |" % (k, cell(title), d, n))
    out += ["", "Not done yet:", "", "| Item | State | What |", "| --- | --- | --- |"] + rows
    return "\n".join(out)


def replace(doc, name, body):
    b, e = BLOCKS[name]
    i, j = doc.find(b), doc.find(e)
    if i < 0 or j < i:
        raise SystemExit("error: docs/roadmap.md: markers for %s not found" % name)
    return doc[: i + len(b)] + "\n\n" + body + "\n\n" + doc[j:]


def main(argv):
    if not argv or argv[0] not in ("write", "check"):
        raise SystemExit(__doc__)
    mode, args = argv[0], argv[1:]
    board = todo = None
    doc = DOC
    while args:
        if args[0] == "--board" and len(args) > 1:
            board, args = args[1], args[2:]
        elif args[0] == "--doc" and len(args) > 1:
            doc, args = args[1], args[2:]
        elif args[0] == "--todo" and len(args) > 1:
            todo, args = args[1], args[2:]
        else:
            raise SystemExit(__doc__)
    if board:
        with open(board, encoding="utf-8") as f:
            data = json.load(f)
    elif mode == "write":
        data = json.loads(subprocess.run(BOARD_CMD, check=True, capture_output=True, text=True).stdout)
    else:
        raise SystemExit("error: check needs --board FILE (the board is not fetched in a check)")
    with open(doc, encoding="utf-8") as f:
        old = f.read()
    new = replace(replace(old, "board", board_block(data)), "todo", todo_block(todo or TODO))
    if mode == "check":
        if new != old:
            print("docs/roadmap.md is stale: python3 scripts/roadmap-gen.py write", file=sys.stderr)
            return 1
        return 0
    with open(doc, "w", encoding="utf-8") as f:
        f.write(new)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
