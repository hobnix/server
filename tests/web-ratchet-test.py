#!/usr/bin/env python3
"""Ratchet for raw markup in web/src: input/select/textarea/own <style>/hex colours per file may only go down.

  web-ratchet-test.py [--root DIR] [--baseline FILE] [--update]

Compares `scripts/dev/web-inventory.py --files` with tests/web-ratchet.tsv (the one file holding the numbers).
A file not in the baseline has baseline 0. Exit 1 if a value rose, or fell without the baseline being lowered.
--update rewrites the baseline from the current tree.
"""
import argparse
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
INV = REPO / "scripts" / "dev" / "web-inventory.py"
COLS = ["input", "select", "textarea", "style", "hex"]


def current(root):
    p = subprocess.run([sys.executable, str(INV), "--root", str(root), "--files"], capture_output=True, text=True)
    if p.returncode != 0:
        print(p.stderr.strip(), file=sys.stderr)
        sys.exit(2)
    return p.stdout


def parse(text):
    rows = {}
    for line in text.splitlines()[1:]:
        if line.strip():
            f = line.split("\t")
            rows[f[0]] = dict(zip(COLS, (int(x) for x in f[1:])))
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=str(REPO / "web" / "src"))
    ap.add_argument("--baseline", default=str(REPO / "tests" / "web-ratchet.tsv"))
    ap.add_argument("--update", action="store_true")
    a = ap.parse_args()
    out = current(a.root)
    base = Path(a.baseline)
    if a.update:
        base.write_text(out, encoding="utf-8", newline="\n")
        print("wrote %s" % base)
        return 0
    old = parse(base.read_text(encoding="utf-8")) if base.is_file() else {}
    new = parse(out)
    bad = 0
    for f in sorted(set(old) | set(new)):
        for c in COLS:
            n = new.get(f, {}).get(c, 0)
            b = old.get(f, {}).get(c, 0)
            if n > b:
                print("web/src/%s: %s %d > %d (baseline); use ui components or add one to ui first" % (f, c, n, b))
                bad += 1
            elif n < b:
                print("web/src/%s: %s %d < %d: lower the number in tests/web-ratchet.tsv (python3 tests/web-ratchet-test.py --update)" % (f, c, n, b))
                bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
