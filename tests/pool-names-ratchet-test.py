#!/usr/bin/env python3
"""Ratchet for hard-coded pool names: the words bulk/fast per file of the code may only go down.

  pool-names-ratchet-test.py [--root DIR] [--baseline FILE] [--update]

Counts matches (not lines, comments included) of the pool names bulk/fast in the files in scope and compares them with
tests/pool-names-ratchet.tsv (header `file<TAB>count`, one row per file with count > 0, sorted by path).
A file not in the baseline has baseline 0. Exit 1 if a count rose, fell without the baseline being lowered, or a row is stale.
--update rewrites the baseline from the current tree. Files come from `git ls-files` when --root is the repo, else from a walk.
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
PAT = re.compile(r"(?<![A-Za-z0-9_.-])(bulk|fast)(?![A-Za-z0-9_-])")
GENERATED = {"config/defaults.nix", "scripts/lib/config-keys.sh", "scripts/lib/capabilities.tsv", "machine.toml.example"}
SKIP_DIRS = {".git", "node_modules", ".work", ".claude"}


def in_scope(rel):
    parts = rel.split("/")
    name = parts[-1]
    ext = name.rsplit(".", 1)[-1] if "." in name else ""
    if rel in GENERATED or ".gen." in name or name.endswith(".md"):
        return False
    if rel.startswith(("tests/", "docs/", "web/design/", "scripts/lib/i18n/")):
        return False
    if parts[0] == "scripts":
        return len(parts) > 1 and ext in ("sh", "py", "tsv")
    if parts[0] == "capabilities":
        return len(parts) > 1 and ext in ("nix", "sh", "py", "toml")
    if len(parts) == 1:
        return ext == "nix"
    if parts[0] == "installer":
        return ext == "nix"
    if rel == "config/schema.toml":
        return True
    if parts[0] == "presets":
        return len(parts) == 2 and ext == "toml"
    if rel.startswith("web/src/"):
        return ext in ("svelte", "js", "ts")
    return False


def files(root):
    if root.resolve() == REPO:
        p = subprocess.run(["git", "-C", str(root), "ls-files", "-z"], capture_output=True)
        if p.returncode != 0:
            print(p.stderr.decode(errors="replace").strip(), file=sys.stderr)
            sys.exit(2)
        names = [n for n in p.stdout.decode("utf-8", "replace").split("\0") if n]
    else:
        names = []
        for f in root.rglob("*"):
            rel = f.relative_to(root)
            if f.is_file() and not (set(rel.parts[:-1]) & SKIP_DIRS):
                names.append(rel.as_posix())
    return sorted(n for n in names if in_scope(n) and (root / n).is_file())


def current(root):
    rows = {}
    for n in files(root):
        c = len(PAT.findall((root / n).read_bytes().decode("utf-8", "replace")))
        if c:
            rows[n] = c
    return rows


def render(rows):
    return "file\tcount\n" + "".join("%s\t%d\n" % (f, rows[f]) for f in sorted(rows))


def parse(text):
    rows = {}
    for line in text.splitlines()[1:]:
        if line.strip():
            f, c = line.split("\t")
            rows[f] = int(c)
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=str(REPO))
    ap.add_argument("--baseline", default=str(REPO / "tests" / "pool-names-ratchet.tsv"))
    ap.add_argument("--update", action="store_true")
    a = ap.parse_args()
    root = Path(a.root)
    new = current(root)
    base = Path(a.baseline)
    if a.update:
        base.write_text(render(new), encoding="utf-8", newline="\n")
        print("wrote %s" % base)
        return 0
    old = parse(base.read_text(encoding="utf-8")) if base.is_file() else {}
    bad = 0
    for f in sorted(set(old) | set(new)):
        n = new.get(f, 0)
        b = old.get(f, 0)
        if n > b:
            print("%s: pool names %d > %d" % (f, n, b))
            bad += 1
        elif f in old and n == 0:
            print("%s: pool names %d < %d: remove the row (--update)" % (f, n, b))
            bad += 1
        elif n < b:
            print("%s: pool names %d < %d: lower the number (--update)" % (f, n, b))
            bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
