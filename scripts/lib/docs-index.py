#!/usr/bin/env python3
"""The index of the documentation pages for the web interface (scripts/docs-build.sh calls this once the pages are in <out>/de and <out>/en).

  docs-index.py <out> <categories.tsv> <built> <rev>

Writes <out>/index.json:
  {"built": "...", "rev": "...", "langs": {"de": {"label": "Deutsch", "groups": [{"name": "...", "pages": [{"slug", "title", "file"}]}]}, "en": {...}}}
`file` is the name the page has in docs/ ("install.md"), so the renderer can follow the links between the guides. The groups
come from docs/categories.tsv (lang <TAB> group <TAB> file without .md; `@commands` = the generated command page); a page the table
does not list goes last under "Weitere" / "More". The generated pages (command reference, cheat sheet) have no file in docs/.
"""
import json
import os
import sys

LABELS = {"de": "Deutsch", "en": "English"}
MORE = {"de": "Weitere", "en": "More"}
COMMANDS = {"de": ("befehle-liste", "Alle Befehle"), "en": ("commands", "All commands")}
EXTRA = {"de": [("spickzettel", "Spickzettel (zum Ausdrucken)")], "en": []}
START = {"de": "start", "en": "start"}


def slug(name):
    t = name
    for a, b in (("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("Ä", "Ae"), ("Ö", "Oe"), ("Ü", "Ue"), ("ß", "ss")):
        t = t.replace(a, b)
    out, last = [], False
    for ch in t.lower():
        if ch.isascii() and (ch.isalnum()):
            out.append(ch)
            last = False
        elif not last:
            out.append("-")
            last = True
    return "".join(out).strip("-")


def title_of(path):
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                if line.startswith("# "):
                    return line[2:].strip()
    except OSError:
        pass
    return ""


def main(argv):
    if len(argv) != 5:
        print("usage: docs-index.py <out> <categories.tsv> <built> <rev>", file=sys.stderr)
        return 1
    out, cat_file, built, rev = argv[1:5]
    langs = {}
    for lang in ("de", "en"):
        folder = os.path.join(out, lang)
        if not os.path.isdir(folder):
            continue          # a language that has no pages is not offered (today only English)
        slugs = sorted(f[:-3] for f in os.listdir(folder) if f.endswith(".md"))
        # the original names, for the links between the guides: docs/<file>.md became <slug>.md
        files = {}
        docs = os.environ.get("HS_DOCS_SRC", "")
        if docs and os.path.isdir(docs):
            for f in os.listdir(docs):
                if f.endswith(".md"):
                    files.setdefault(slug(f[:-3]), f)
        start_slug = START[lang]
        placed, groups, order = set(), [], {}
        rows = []
        if os.path.isfile(cat_file):
            with open(cat_file, encoding="utf-8") as f:
                for line in f:
                    if line.startswith("#") or not line.strip():
                        continue
                    p = line.rstrip("\n").split("\t")
                    if len(p) >= 3 and p[0] == lang:
                        rows.append((p[1], p[2]))
        for group, file in rows:
            if file == "@commands":
                s, label = COMMANDS[lang]
                extras = EXTRA[lang]
            else:
                s, label, extras = slug(file), None, []
            if s not in slugs or s in placed:
                continue
            g = order.get(group)
            if g is None:
                g = {"name": group, "pages": []}
                order[group] = g
                groups.append(g)
            placed.add(s)
            g["pages"].append({"slug": s, "title": label or title_of(os.path.join(folder, s + ".md")) or s, "file": files.get(s, s + ".md")})
            for es, el in extras:
                if es in slugs and es not in placed:
                    placed.add(es)
                    g["pages"].append({"slug": es, "title": el, "file": es + ".md"})
        rest = [s for s in slugs if s not in placed and s != start_slug]
        if rest:
            groups.append({"name": MORE[lang], "pages": [{"slug": s, "title": title_of(os.path.join(folder, s + ".md")) or s, "file": files.get(s, s + ".md")} for s in rest]})
        langs[lang] = {"label": LABELS[lang], "start": start_slug if start_slug in slugs else "", "groups": groups}
    with open(os.path.join(out, "index.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump({"built": built, "rev": rev, "langs": langs}, f, ensure_ascii=False, indent=1)
        f.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
