#!/usr/bin/env python3
"""Lists every web read and every poll() call of the frontend, and checks the ratchet (plain static scan, stdlib only).

  reads-inventory.py [--root WEBSRC] [--serve FILE] [--reasons FILE] [--max FILE] [--tsv] [--check]

Every read in the READS allowlist of scripts/web-serve.py either has a `topic` (live state: pushed, no timer) or a reason in
scripts/lib/read-reasons.tsv. A poll() call of web/src is "live" when it passes a topic (third argument) or when the read it
resolves to has a topic; every other call is "timed" (a timer asks the server again and again) and needs a reason too.
The number of timed call sites may only go down: scripts/lib/timed-reads.max holds the real count.

--tsv: rows "kind<TAB>key<TAB>where<TAB>topic<TAB>reason" (kind read|poll, empty field "-").
--check: exit 1 and one line per problem (missing reason, stale reason, count above or below the number in the max file).

Out of scope: reads that extension packages add at runtime (capability.toml [[web.reads]], see ext_load_web in web-serve.py).
"""
import argparse
import ast
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DEFAULT_ROOT = REPO / "web" / "src"
DEFAULT_SERVE = REPO / "scripts" / "web-serve.py"
DEFAULT_REASONS = REPO / "scripts" / "lib" / "read-reasons.tsv"
DEFAULT_MAX = REPO / "scripts" / "lib" / "timed-reads.max"

CALL = re.compile(r"(?<![\w$.])poll\(")
API = re.compile(r"/api/[A-Za-z0-9_/-]+(\?[^'\"`\s]*)?")
IDENT = re.compile(r"^(?:\(\s*\)\s*=>\s*)?([A-Za-z_$][\w$]*)$")


def load_reads(serve):
    """{key words tuple: {"topic": None|str|"map", "free": bool}} from the module-level READS dict (values are never evaluated)."""
    tree = ast.parse(Path(serve).read_text(encoding="utf-8"))
    for node in tree.body:
        targets = node.targets if isinstance(node, ast.Assign) else [node.target] if isinstance(node, ast.AnnAssign) else []
        if not any(isinstance(t, ast.Name) and t.id == "READS" for t in targets) or not isinstance(node.value, ast.Dict):
            continue
        reads = {}
        for k, v in zip(node.value.keys, node.value.values):
            if not isinstance(k, ast.Tuple) or not all(isinstance(e, ast.Constant) and isinstance(e.value, str) for e in k.elts):
                continue
            entry = {"topic": None, "free": False}
            if isinstance(v, ast.Dict):
                for ck, cv in zip(v.keys, v.values):
                    if not (isinstance(ck, ast.Constant) and isinstance(ck.value, str)):
                        continue
                    if ck.value == "topic":
                        entry["topic"] = cv.value if isinstance(cv, ast.Constant) and isinstance(cv.value, str) else "map"
                    elif ck.value in ("args", "query"):
                        entry["free"] = True
            reads[tuple(e.value for e in k.elts)] = entry
        return reads
    return {}


def blank_comments(text):
    """Comments replaced by spaces (newlines kept, so line numbers stay right)."""
    def blank(m):
        return re.sub(r"[^\n]", " ", m.group(0))
    text = re.sub(r"<!--.*?-->", blank, text, flags=re.S)
    text = re.sub(r"/\*.*?\*/", blank, text, flags=re.S)
    return re.sub(r"(?:(?<=\s)|^)//[^\n]*", blank, text, flags=re.M)


def call_args(text, start):
    """Top-level arguments of the call whose '(' is at text[start - 1]; None when the parens never close."""
    depth, quote, i, cur, args = 1, None, start, start, []
    while i < len(text):
        c = text[i]
        if quote:
            if c == "\\":
                i += 1
            elif c == quote:
                quote = None
        elif c in "'\"`":
            quote = c
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                args.append(text[cur:i])
                return args
        elif c == "," and depth == 1:
            args.append(text[cur:i])
            cur = i + 1
        i += 1
    return None


def resolve(path, query, tail, reads):
    """(key, entry, exact) for a /api/sys/... path (longest prefix), else ('path:<path>', None, False).
    exact: the URL is one live_topic_map() builds: the bare base for a string topic, base?pool=<x> for a mapped one."""
    if path.startswith("/api/sys/"):
        words = tuple(w for w in path[len("/api/sys/"):].split("/") if w)
        for n in range(len(words), 0, -1):
            if words[:n] in reads:
                entry = reads[words[:n]]
                bare = n == len(words) and not tail and not path.endswith("/")
                if entry["topic"] == "map":
                    exact = bare and re.fullmatch(r"\?pool=(bulk|fast)", query) is not None
                else:
                    exact = bare and not query
                return " ".join(words[:n]), entry, exact
    return "path:" + path, None, False


def const_text(text, name):
    """The right-hand side of `const|let NAME = ...` (rest of the line) in the same file, else None."""
    m = re.search(r"\b(?:const|let)\s+%s\s*=\s*(?:\$derived\(\s*)?([^\n]*)" % re.escape(name), text)
    return m.group(1) if m else None


def scan_polls(root, reads):
    """[{key, where, explicit, live, call}] one per (call, path); 'call' numbers the call sites."""
    found, call_no = [], 0
    for path in sorted(root.rglob("*")):
        if path.suffix not in (".svelte", ".js") or not path.is_file():
            continue
        rel = path.relative_to(root).as_posix()
        text = blank_comments(path.read_text(encoding="utf-8", errors="replace"))
        # a file with its own function poll() (not data.svelte.js) calls that one, not the shared read helper
        if rel != "data.svelte.js" and re.search(r"\bfunction\s+poll\s*\(", text):
            continue
        for m in CALL.finditer(text):
            if re.search(r"function\s+$", text[max(0, m.start() - 20):m.start()]):
                continue
            args = call_args(text, m.end())
            if not args or not args[0].strip():
                continue
            call_no += 1
            line = text.count("\n", 0, m.start()) + 1
            explicit = len(args) >= 3 and args[2].strip() not in ("", "undefined", "null")
            first = args[0].strip()
            im = IDENT.match(first)
            if im and not API.search(first):   # poll(CH, ...) / poll(() => path, ...): the constant of the same file
                first = const_text(text, im.group(1)) or first
            where = "%s:%d" % (rel, line)
            paths = [(m2.group(0).split("?")[0], m2.group(1) or "", first[m2.end():m2.end() + 1])
                     for m2 in API.finditer(first)]
            paths = [t for t in paths if t[0].rstrip("/") not in ("/api", "/api/sys")]   # a bare prefix is not a read
            if not paths:
                found.append({"key": "dynamic:" + rel, "where": where, "explicit": explicit, "live": explicit, "map": False, "call": call_no})
                continue
            for p, query, nxt in dict.fromkeys(paths):
                key, entry, exact = resolve(p, query, nxt == "$", reads)
                mapped = bool(entry and entry["topic"] and exact)
                found.append({"key": key, "where": where, "explicit": explicit, "live": explicit or mapped, "map": mapped, "call": call_no})
    return found


def load_reasons(path):
    reasons = {}
    p = Path(path)
    if not p.is_file():
        return reasons
    for line in p.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        key, _, reason = line.partition("\t")
        reasons[key.strip()] = reason.strip()
    return reasons


def load_max(path):
    p = Path(path)
    try:
        return int(p.read_text(encoding="utf-8").split()[0])
    except (OSError, ValueError, IndexError):
        return None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=str(DEFAULT_ROOT))
    ap.add_argument("--serve", default=str(DEFAULT_SERVE))
    ap.add_argument("--reasons", default=str(DEFAULT_REASONS))
    ap.add_argument("--max", default=str(DEFAULT_MAX))
    ap.add_argument("--tsv", action="store_true")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    root = Path(a.root)
    if not root.is_dir() or not Path(a.serve).is_file():
        print("no such directory or file: %s %s" % (root, a.serve), file=sys.stderr)
        return 2
    reads = load_reads(a.serve)
    polls = scan_polls(root, reads)
    reasons = load_reasons(a.reasons)
    timed = [p for p in polls if not p["live"]]
    timed_calls = len({p["call"] for p in timed})

    if a.check:
        bad = []
        need = {" ".join(k) for k, e in reads.items() if not e["topic"]} | {p["key"] for p in timed}
        for key in sorted(need):
            if not reasons.get(key):
                bad.append("no reason in %s for: %s" % (Path(a.reasons).name, key))
        for key in sorted(reasons):
            if key not in need:
                bad.append("stale reason (no such timed read): %s" % key)
        limit = load_max(a.max)
        if limit is None:
            bad.append("no number in %s" % Path(a.max).name)
        elif timed_calls > limit:
            bad.append("timed polls went up: %d calls, %s allows %d (give the read a topic, or reuse one)" % (timed_calls, Path(a.max).name, limit))
        elif timed_calls < limit:
            bad.append("timed polls went down: lower the number to %d in %s" % (timed_calls, Path(a.max).name))
        for line in bad:
            print(line)
        return 1 if bad else 0

    rows = []
    for k, e in sorted(reads.items()):
        key = " ".join(k)
        rows.append(("read", key, "-", e["topic"] or "-", reasons.get(key) or "-"))
    for p in polls:
        topic = "explicit" if p["explicit"] else "map" if p["map"] else "-"
        rows.append(("poll", p["key"], p["where"], topic, (reasons.get(p["key"]) or "-") if not p["live"] else "-"))
    if a.tsv:
        for r in rows:
            print("\t".join(r))
        return 0
    n_read = sum(1 for r in rows if r[0] == "read")
    print("reads: %d, without topic: %d" % (n_read, sum(1 for r in rows if r[0] == "read" and r[3] == "-")))
    print("poll calls: %d, timed: %d (max file: %s)" % (len({p["call"] for p in polls}), timed_calls, load_max(a.max)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
