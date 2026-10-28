#!/usr/bin/env python3
"""Look for personal data and secrets in the files of a repository before it goes public (docs/PLAN-packages.md, step 6).

    python3 scripts/dev/leak-scan.py [<folder>] [--patterns <file>] [--all-files]

Scans the files git tracks in <folder> (default: the current one; --all-files = every file below it, for a folder that is not a
repository yet). Two kinds of findings, one per line `file:line: kind: text`, exit 1 when there is any:
  secret   built in: private key blocks, GitHub / Slack / AWS tokens, `password = <literal>` style assignments with a long value
  mail     built in: an e-mail address whose domain is not example.* / localhost / users.noreply.github.com / a placeholder
  own      one regular expression per line of the --patterns file (case-insensitive; `#` lines and empty lines are skipped): the
           names, domains and hosts of the author's server. That file is NOT part of the repository (it would be the leak itself).
A file `.leak-allow` in <folder> holds `path-glob<TAB>kind` lines (kind secret|mail|own|*) for findings that are harmless on purpose
(test fixtures with a private-key header, unit names that look like addresses); `#` lines are comments.
Binary files and fonts are skipped. Standard library plus git.
"""
import fnmatch
import os
import re
import subprocess
import sys

SECRET = [
    (re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY"), "private key"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}\b|\bgithub_pat_[A-Za-z0-9_]{30,}\b"), "GitHub token"),
    (re.compile(r"\bxox[abpr]-[A-Za-z0-9-]{10,}\b"), "Slack token"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "AWS access key"),
    (re.compile(r"(?i)\b(?:password|passwd|secret|api[_-]?key|token)\s*[:=]\s*['\"][A-Za-z0-9+/_\-]{16,}['\"]"), "literal credential"),
]
MAIL = re.compile(r"\b[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})\b")
MAIL_OK = re.compile(r"(?i)^(example\.[a-z]+|.*\.example|localhost|users\.noreply\.github\.com|anthropic\.com|.*\.local|.*\.lan|.*\.test|.*\.invalid|.*\.(svg|png|webp|jpg))$")
SKIP_EXT = (".woff", ".woff2", ".ttf", ".otf", ".png", ".jpg", ".jpeg", ".gif", ".ico", ".webp", ".pdf", ".zip", ".gz", ".iso")


def files(folder, all_files):
    if not all_files:
        r = subprocess.run(["git", "ls-files", "-z"], cwd=folder, capture_output=True)
        if r.returncode == 0:
            return [f for f in r.stdout.decode("utf-8", "replace").split("\0") if f]
    out = []
    for base, dirs, names in os.walk(folder):
        dirs[:] = [d for d in dirs if d not in (".git", "node_modules", "__pycache__")]
        for n in names:
            out.append(os.path.relpath(os.path.join(base, n), folder))
    return out


def main(argv):
    folder, patterns, all_files, i = ".", [], False, 0
    while i < len(argv):
        a = argv[i]
        if a == "--patterns":
            with open(argv[i + 1], encoding="utf-8") as f:
                patterns = [re.compile(l.strip(), re.I) for l in f if l.strip() and not l.startswith("#")]
            i += 1
        elif a == "--all-files":
            all_files = True
        elif a.startswith("-"):
            print(__doc__)
            return 2
        else:
            folder = a
        i += 1
    allow = []
    try:
        with open(os.path.join(folder, ".leak-allow"), encoding="utf-8") as f:
            for l in f:
                if l.strip() and not l.startswith("#"):
                    g, _, k = l.rstrip("\n").partition("\t")
                    allow.append((g.strip(), (k or "*").strip()))
    except OSError:
        pass
    found = 0
    for rel in files(folder, all_files):
        if rel.lower().endswith(SKIP_EXT):
            continue
        try:
            with open(os.path.join(folder, rel), encoding="utf-8") as f:
                lines = f.read().splitlines()
        except (OSError, UnicodeDecodeError):
            continue
        for n, line in enumerate(lines, 1):
            hits = [("secret", m.group(0)[:60]) for rx, _ in SECRET for m in [rx.search(line)] if m]
            hits += [("mail", m.group(0)) for m in MAIL.finditer(line) if not MAIL_OK.match(m.group(1))]
            hits += [("own", m.group(0)) for rx in patterns for m in [rx.search(line)] if m]
            for kind, text in hits:
                if any(fnmatch.fnmatch(rel, g) and k in ("*", kind) for g, k in allow):
                    continue
                print(f"{rel}:{n}: {kind}: {text}")
                found += 1
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
