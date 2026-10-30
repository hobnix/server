#!/usr/bin/env python3
"""The changelog: one TOML file per user-visible change in docs/changelog (HS_CHANGELOG_DIR overrides the folder, for tests).

File name: YYYY-MM-DD-<slug>.toml (slug: lower case letters, digits, '-'). Keys, all strings, no others:
  date  required, a real ISO date, equal to the date in the file name
  type  required: feature | fix | change | security
  title required, English, one line, 1..100 chars, no tab
  docs  optional: <guide>[#<anchor>]; docs/<guide>.md must exist and have a heading with that anchor
  body  optional, English, plain text, at most 1000 chars, no tab; a blank line starts a new paragraph
No line-break characters other than \\n (in the body) are allowed: \\r, \\x0b, \\x0c, \\x1c-\\x1e, \\x85, U+2028, U+2029 (the web splits rows
with str.splitlines()).

Subcommands (run as: python3 -I changelog.py ...):
  rows <repo> [--since YYYY-MM-DD] [--limit N] [--files]
      Prints the entry lines (newest first: date, then id, descending), tab separated, an empty field is '-':
        entry TAB id TAB date TAB type TAB title TAB docs|- TAB body|-      (body on one line: each newline becomes the two characters \\n)
      Without --files every file of the folder; with --files the repo-relative paths come from stdin (git diff output).
      Invalid files are skipped silently (validate reports them).
  validate <repo>
      Prints '<file>: <reason>' per problem and exits 1, else '<N> changelog entries ok' and exits 0.
"""
import datetime
import os
import re
import sys
import tomllib

TYPES = {"feature", "fix", "change", "security"}
# characters str.splitlines() breaks a line at; only \n is allowed, and only in the body
BREAKS = re.compile("[\r\n\x0b\x0c\x1c-\x1e\x85  ]")
BREAKS_BODY = re.compile("[\r\x0b\x0c\x1c-\x1e\x85  ]")
KEYS = {"date", "type", "title", "docs", "body"}
NAME_RE = re.compile(r"^(\d{4}-\d{2}-\d{2})-[a-z0-9][a-z0-9-]{0,60}\.toml$")
DOCS_RE = re.compile(r"^([a-z0-9][a-z0-9-]*)(?:#([a-z0-9_-]+))?$")


def folder(repo):
    return os.environ.get("HS_CHANGELOG_DIR") or os.path.join(repo, "docs", "changelog")


def anchors(path):
    """The heading ids of a guide, with the rule of the web (web/src/docs/markdown.js headingId)."""
    out = set()
    try:
        with open(path, encoding="utf-8") as f:
            for ln in f:
                m = re.match(r"^#{1,6} +(.*?)\s*$", ln)
                if m:
                    out.add(re.sub(r"\s", "-", re.sub(r"[^\w\s-]", "", m.group(1).lower()).strip()))
    except OSError:
        pass
    return out


def parse(repo, path):
    """-> (entry dict, None) or (None, reason)."""
    name = os.path.basename(path)
    m = NAME_RE.match(name)
    if not m:
        return None, "file name must be YYYY-MM-DD-<slug>.toml (slug: a-z, 0-9, -)"
    try:
        with open(path, "rb") as f:
            d = tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError, UnicodeDecodeError) as e:
        return None, f"cannot read as TOML: {e}"
    extra = sorted(set(d) - KEYS)
    if extra:
        return None, "unknown key: " + ", ".join(extra)
    for k in ("date", "type", "title"):
        if k not in d:
            return None, f"missing key: {k}"
    for k, v in d.items():
        if not isinstance(v, str):
            return None, f"{k} must be a string"
    try:
        datetime.date.fromisoformat(d["date"])
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", d["date"]):
            raise ValueError
    except ValueError:
        return None, "date is not a valid YYYY-MM-DD date"
    if d["date"] != m.group(1):
        return None, "date does not match the file name"
    if d["type"] not in TYPES:
        return None, "type must be one of: " + ", ".join(sorted(TYPES))
    if not 1 <= len(d["title"]) <= 100 or "\t" in d["title"] or BREAKS.search(d["title"]):
        return None, "title must be 1..100 chars on one line, no tab"
    body = d.get("body", "")
    if len(body) > 1000 or "\t" in body or BREAKS_BODY.search(body):
        return None, "body must be at most 1000 chars, no tab, only \\n as a line break"
    docs = d.get("docs", "")
    if "docs" in d:
        dm = DOCS_RE.match(docs)
        if not dm:
            return None, "docs must be <guide> or <guide>#<anchor>"
        gpath = os.path.join(repo, "docs", dm.group(1) + ".md")
        if not os.path.isfile(gpath):
            return None, f"docs/{dm.group(1)}.md does not exist"
        if dm.group(2) and dm.group(2) not in anchors(gpath):
            return None, f"docs/{dm.group(1)}.md has no heading with the anchor #{dm.group(2)}"
    return {"id": name[:-5], "date": d["date"], "type": d["type"], "title": d["title"],
            "docs": docs, "body": body}, None


def line_of(e):
    body = e["body"].strip().replace("\t", " ").replace("\r", "").replace("\n", "\\n")
    return "\t".join(["entry", e["id"], e["date"], e["type"], e["title"], e["docs"] or "-", body or "-"])


def cmd_rows(argv):
    repo, since, limit, files = argv[0], "", None, False
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--files":
            files = True
        elif a == "--since" and i + 1 < len(argv):
            i += 1
            since = argv[i]
        elif a == "--limit" and i + 1 < len(argv):
            i += 1
            limit = int(argv[i])
        else:
            return 2
        i += 1
    d = folder(repo)
    if files:
        paths = []
        for rel in sys.stdin.read().splitlines():
            rel = rel.strip()
            if rel.startswith("docs/changelog/") and rel.endswith(".toml"):
                p = os.path.join(d, os.path.basename(rel))
                if os.path.isfile(p):
                    paths.append(p)
    else:
        try:
            paths = [os.path.join(d, n) for n in os.listdir(d) if n.endswith(".toml")]
        except OSError:
            paths = []
    entries = []
    for p in paths:
        e, err = parse(repo, p)
        if e and (not since or e["date"] >= since):
            entries.append(e)
    entries.sort(key=lambda e: (e["date"], e["id"]), reverse=True)
    if limit is not None:
        entries = entries[:limit]
    for e in entries:
        print(line_of(e))
    return 0


def cmd_validate(argv):
    repo = argv[0]
    d = folder(repo)
    try:
        names = sorted(os.listdir(d))
    except OSError:
        names = []
    bad = 0
    n = 0
    for name in names:
        if name == "README.md":
            continue
        if not name.endswith(".toml"):
            print(f"{name}: only .toml files (and README.md) belong in docs/changelog")
            bad += 1
            continue
        e, err = parse(repo, os.path.join(d, name))
        if err:
            print(f"{name}: {err}")
            bad += 1
        else:
            n += 1
    if bad:
        return 1
    print(f"{n} changelog entries ok")
    return 0


def main(argv):
    if len(argv) >= 3 and argv[1] == "rows":
        return cmd_rows(argv[2:])
    if len(argv) == 3 and argv[1] == "validate":
        return cmd_validate(argv[2:])
    print("usage: changelog.py rows <repo> [--since YYYY-MM-DD] [--limit N] [--files] | validate <repo>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
