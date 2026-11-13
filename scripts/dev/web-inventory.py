#!/usr/bin/env python3
"""Counts shared components vs raw markup per folder of web/src (plain static scan, stdlib only).

  web-inventory.py [--root DIR] [--tsv] [--classes [N]]

Default: a short table. --tsv: header + one row per folder (ui:<Name> columns, empty field "-").
--classes [N]: the N (default 20) most repeated static class names in pages/ as "count<TAB>class".
The row "outside ui" is the number the ratchet test uses.
"""
import argparse
import re
import sys
from collections import Counter
from pathlib import Path

DEFAULT_ROOT = Path(__file__).resolve().parents[2] / "web" / "src"
RAW = ("input", "select", "textarea", "button")
HEX = re.compile(r"(?<![\w&#])#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3})(?![\w])")
COMMENT = re.compile(r"<!--.*?-->", re.S)
URL = re.compile(r"url\([^)]*\)")
STYLE = re.compile(r"<style\b[^>]*>(.*?)</style>", re.S)
CLASS = re.compile(r'\bclass="([^"]*)"')


def folder_of(root, path):
    parts = path.relative_to(root).parts
    return parts[0] if len(parts) > 1 else "."


def ui_names(root):
    names = set()
    index = root / "ui" / "index.js"
    if index.is_file():
        names.update(re.findall(r"default as (\w+)", index.read_text(encoding="utf-8")))
    ui = root / "ui"
    if ui.is_dir():
        names.update(p.stem for p in ui.glob("*.svelte"))
    return sorted(names)


def strip_lines(text):
    text = COMMENT.sub("", text)
    return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("//"))


def scan(root):
    names = ui_names(root)
    cols = {}

    def row(folder):
        return cols.setdefault(folder, Counter())

    for path in sorted(root.rglob("*")):
        if path.suffix not in (".svelte", ".css") or not path.is_file():
            continue
        folder = folder_of(root, path)
        r = row(folder)
        raw = path.read_text(encoding="utf-8", errors="replace")
        if path.name != "tokens.css":
            r["hex"] += len(HEX.findall(URL.sub("", strip_lines(raw))))
        if path.suffix != ".svelte":
            continue
        r["files"] += 1
        text = strip_lines(raw)
        for tag in RAW:
            r[tag] += len(re.findall(r"<%s(?![\w-])" % tag, text))
        for m in STYLE.finditer(text):
            r["style"] += 1
            r["style_lines"] += len(m.group(1).strip("\n").split("\n")) if m.group(1).strip() else 0
        if folder != "ui":
            for n in names:
                c = len(re.findall(r"<%s(?![\w.-])" % n, text))
                if c:
                    r["ui:" + n] += c
    return names, cols


def classes(root, limit):
    cnt = Counter()
    base = root / "pages"
    for path in sorted(base.rglob("*.svelte")) if base.is_dir() else []:
        for m in CLASS.finditer(COMMENT.sub("", path.read_text(encoding="utf-8", errors="replace"))):
            cnt.update(re.sub(r"\{[^}]*\}", " ", m.group(1)).split())
    for name, n in sorted(cnt.items(), key=lambda kv: (-kv[1], kv[0]))[:limit]:
        print("%d\t%s" % (n, name))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=str(DEFAULT_ROOT))
    ap.add_argument("--tsv", action="store_true")
    ap.add_argument("--classes", nargs="?", const=20, type=int, metavar="N")
    a = ap.parse_args()
    root = Path(a.root)
    if not root.is_dir():
        print("no such directory: %s" % root, file=sys.stderr)
        return 2
    if a.classes is not None:
        classes(root, a.classes)
        return 0
    names, cols = scan(root)
    folders = sorted(cols)
    fixed = ["files", "ui_uses", *RAW, "style", "style_lines", "hex"]
    for r in cols.values():
        r["ui_uses"] = sum(r["ui:" + n] for n in names)
    total = Counter()
    outside = Counter()
    for f, r in cols.items():
        total.update(r)
        if f != "ui":
            outside.update(r)
    rows = [(f, cols[f]) for f in folders] + [("total", total), ("outside ui", outside)]
    if a.tsv:
        heads = fixed + ["ui:" + n for n in names]
        print("\t".join(["folder"] + heads))
        for f, r in rows:
            print("\t".join([f] + [str(r[h]) if r[h] else "0" for h in heads]))
        return 0
    table = [["folder"] + fixed] + [[f] + [str(r[h]) for h in fixed] for f, r in rows]
    w = [max(len(t[i]) for t in table) for i in range(len(fixed) + 1)]
    for i, t in enumerate(table):
        print("  ".join(c.ljust(w[j]) if j == 0 else c.rjust(w[j]) for j, c in enumerate(t)))
        if i == 0 or i == len(table) - 3:
            print("  ".join("-" * x for x in w))
    return 0


if __name__ == "__main__":
    sys.exit(main())
