#!/usr/bin/env python3
"""The steps that were never run on real hardware: every "Not tested on hardware yet." marker, counted per guide.

  untested.py [--steps] [--all] [ROOT ...]

Without options: one line per guide (a file of docs/ that is not a plan or design record, and every guide.md of a package or capability)
with the number of markers and the date the guide was last worked through on the server (docs/verified.tsv, `hs docs verified`).
  --steps   also one line per marker: file:line and the heading it stands under (the list to take to the server)
  --all     every Markdown file, not only the guides (plans, decision records, notes)
  ROOT      a checkout to read instead of this one (for example the recipes or extensions repository); several are allowed

A line that only talks about the marker (the phrase in quotes, as in a rule) is not counted. Nothing is written. Python stdlib only.
"""
import os
import re
import sys

MARK = "Not tested on hardware yet"
HERE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SKIP_DIRS = {".git", "node_modules", ".work", ".claude", ".opencode", ".github", "target", "result", "changelog", "design"}
NOT_GUIDES = ("README", "CLI-DESIGN", "COMMANDS-DESIGN", "Entwicklungsnotizen", "GUIDE-TEMPLATE", "roadmap", "dev-environment")
NOT_GUIDE_PREFIXES = ("PLAN-", "RELEASE-")
QUOTED = re.compile(r'["`“]' + MARK)


def is_guide(rel):
    parts = rel.split("/")
    name = parts[-1][:-3]
    if parts[-1] == "guide.md":
        return True
    if len(parts) == 2 and parts[0] == "docs":
        return name not in NOT_GUIDES and not name.startswith(NOT_GUIDE_PREFIXES)
    return False


def files(root, everything):
    for base, dirs, names in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        for n in sorted(names):
            if not n.endswith(".md"):
                continue
            rel = os.path.relpath(os.path.join(base, n), root).replace(os.sep, "/")
            if everything or is_guide(rel):
                yield rel


def markers(path):
    """(line number, heading above it) for every marker in the file"""
    out = []
    heading = "-"
    fence = False
    with open(path, encoding="utf-8", errors="replace") as f:
        for no, line in enumerate(f, 1):
            if line.lstrip().startswith("```"):
                fence = not fence
            elif not fence and line.startswith("#"):
                heading = line.lstrip("#").strip() or "-"
            if MARK in line and not QUOTED.search(line):
                out.append((no, heading))
    return out


def verified(root):
    dates = {}
    try:
        with open(os.path.join(root, "docs", "verified.tsv"), encoding="utf-8") as f:
            for line in f:
                cols = line.rstrip("\n").split("\t")
                if not line.startswith("#") and len(cols) >= 2:
                    dates[cols[0]] = cols[1]
    except OSError:
        pass
    return dates


def report(root, steps, everything, label):
    dates = verified(root)
    rows = []
    for rel in files(root, everything):
        found = markers(os.path.join(root, rel))
        if found:
            key = rel[5:-3] if rel.startswith("docs/") else rel[:-3]
            rows.append((rel, found, dates.get(key, "never")))
    total = sum(len(r[1]) for r in rows)
    if label:
        print("== %s" % root)
    if not rows:
        print("No untested steps.")
        return 0
    width = max(len(r[0]) for r in rows)
    print("%-*s  %5s  %s" % (width, "Guide" if not everything else "File", "Steps", "Last checked"))
    for rel, found, date in sorted(rows, key=lambda r: (-len(r[1]), r[0])):
        print("%-*s  %5d  %s" % (width, rel, len(found), date))
    print("%-*s  %5d" % (width, "Total (%d files)" % len(rows), total))
    if steps:
        for rel, found, _ in rows:
            print("")
            for no, heading in found:
                print("%s:%d\t%s" % (rel, no, heading))
    return total


def main(argv):
    steps = everything = False
    roots = []
    for a in argv:
        if a == "--steps":
            steps = True
        elif a == "--all":
            everything = True
        elif a in ("-h", "--help") or a.startswith("-"):
            raise SystemExit(__doc__)
        else:
            roots.append(a)
    roots = roots or [HERE]
    for i, root in enumerate(roots):
        if not os.path.isdir(root):
            raise SystemExit("error: not a folder: %s" % root)
        if i:
            print("")
        report(root, steps, everything, len(roots) > 1)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
