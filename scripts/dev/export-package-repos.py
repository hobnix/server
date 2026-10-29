#!/usr/bin/env python3
"""Export the packages of this repository into the two package repositories (docs/PLAN-packages.md, step 5).

    python3 scripts/dev/export-package-repos.py --out <folder> [--org <name>] [--author "Name <mail>"] [--branding <dir>] [--force] [--no-git]

Writes <out>/recipes and <out>/extensions, each a CLEAN repository:
one commit, no history of the homeserver repository. Nothing is pushed and no tag is made: a release is `git tag -s v1.0.0`
with the repository's signing key (config/trusted-keys/README.md). Existing target folders are refused unless --force. The commit is made as --author (default: the git identity of this repository).
The files of --branding <dir> (default: .github/branding of this repository: logo-*.svg, banner@2x.webp, banner.png) go to .github/branding; the banner is shown in the README.

Layout of a package repository:
    index.toml                 [package.<name>] version, kind, path, title, requires_core, audience, core (what `hs pkg` reads at a tag)
    recipes/<name>/ | extensions/<name>/   the package folder as it is in packages/ or capabilities/
    README.md CONTRIBUTING.md SECURITY.md LICENSE .gitignore .github/workflows/check.yml

Standard library plus git.
"""
import os
import shutil
import subprocess
import sys
import tomllib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
CORE_RECIPES = ("docker", "zoraxy", "monitoring", "ntfy", "domain")   # the core refers to these by name
EXTENSIONS = ("games", "posters", "passthrough")   # passthrough needs the core capability gateway (requires)


def q(s):
    import json
    return json.dumps(s, ensure_ascii=False)


def load(folder):
    with open(os.path.join(folder, "package.toml"), "rb") as f:
        return tomllib.load(f)


def index_text(entries):
    out = ["# The index of this repository (docs/PLAN-packages.md). `hs pkg` reads it at a signed release tag; the versions here must equal",
           "# the package.toml of each folder (`python3 scripts/pkg.py repo-check .` in the core checks that)."]
    for name, e in sorted(entries.items()):
        out += ["", f"[package.{name}]", f"version = {q(e['version'])}", f"kind = {q(e['kind'])}", f"path = {q(e['path'])}",
                f"title = {q(e['title'])}", f"requires_core = {q(e['requires_core'])}", f"audience = {q(e.get('audience', 'generic'))}"]
        if e.get("core"):
            out.append("core = true")
    return "\n".join(out) + "\n"


def readme(repo, org, kind, banner=None):
    what = "recipes: each installs an app in its own container or VM" if kind == "recipe" else "extensions: optional commands and pages for the server"
    head = f'<p align="center"><img src=".github/branding/{banner}" alt="{repo}" width="100%"></p>\n\n' if banner else ""
    return head + f"""# {repo}

Packages for Hobnix, the home server (https://github.com/{org}/server) — {what}.

A package is a folder with a `package.toml` (name, semver `version`, `requires_core`), its scripts, translations and tests. `index.toml`
lists them. The server installs a package only from a release tag (`v1.2.3`) whose SSH signature verifies against the repository's
trusted key:

```
hs pkg fetch
hs pkg available
hs pkg install <name>
hs pkg update <name>
```

Packages run as root on the server: read the diff `hs pkg update` shows. Writing one: CONTRIBUTING.md.

## The name

**Hob** is a small, hairy, wizened household and farm spirit from the folklore of the English Midlands, Northern England and the
Anglo-Scottish border: the helper that quietly keeps the house running. **Nix** is NixOS, the operating system underneath. Hobnix is
the helper that keeps a NixOS home server running.

## AI was used here

Large parts of the code, the documentation and the tests of this project were written with the help of AI coding assistants. The
maintainer directs, reviews and tests the work, but not everything has been run on every kind of hardware, and AI-written code can be
wrong in ways that look right. Packages run as root on your server: read what you install (`hs pkg update` shows the diff), and report
what you find.

## Licence

MIT (see LICENSE). Contributions are accepted under the same licence.
"""


def contributing(kind):
    return f"""# Writing a package

1. One folder per package under `{'recipes' if kind == 'recipe' else 'extensions'}/<name>/` with a `package.toml`:
   `name` (= folder), `version` (semver), `kind = "{kind}"`, `title`, `title_de`, `requires_core = ">=1"` (the API level of the core
   helpers it uses), `audience = "generic"` (or `"personal"`: hidden unless asked for).
2. {'`run.sh` is the idempotent installer, built from the helpers of the core (`scripts/recipes/_lib.sh`: ensure_container, step, spin, in_ct, piece, fetch_pinned, ...). It never prints raw command output, never reads a secret from argv or the environment, pins every download (version + sha256) and never opens a public route for an admin page.' if kind == 'recipe' else '`capability.toml` and `commands.tsv` describe the commands (`hs ext <name> <command>`), the web reads and the page; scripts are referenced as `@/file`.'}
3. Raise `version` in `package.toml` AND in `index.toml` (a patch for a fix, a minor for a feature, a major when a person has to act).
4. `python3 <core>/scripts/pkg.py validate` and `repo-check .` must pass (CI runs them against the core).
5. A release is a signed tag `vX.Y.Z` on the commit with the new index.
"""


WORKFLOW = """name: check
on: [push, pull_request]
env:
  # the core checkout the packages are validated against (change it when the core lives elsewhere)
  CORE_REPOSITORY: {org}/server
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/checkout@v4
        with:
          repository: ${{{{ env.CORE_REPOSITORY }}}}
          path: core
      - name: Manifests and index
        run: |
          mkdir tree && ln -s "$PWD/{folder}" "tree/{treename}"
          HS_PACKAGES_ROOT="$PWD/tree" python3 -I core/scripts/pkg.py validate
          python3 -I core/scripts/pkg.py repo-check .
      - name: Shell syntax
        run: for f in {folder}/*/*.sh; do [ -f "$f" ] && bash -n "$f"; done; true
"""


MIT = """MIT License

Copyright (c) 2026 The Hobnix contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""


def security(repo, org):
    return f"""# Security policy

Packages in this repository run as root on a server. Please report a vulnerability, a way to get code run without a signed release, or a
package that does more than it says, **privately**: open a report under the Security tab of https://github.com/{org}/{repo}
("Report a vulnerability"). Do not open a public issue for it.

You get an answer within a week. A fix is released as a new signed tag (`vX.Y.Z`); the advisory names the affected versions.
How releases are signed and how a signing key is replaced: the core repository, `config/trusted-keys/README.md`.
"""


def copy_package(src, dst):
    shutil.copytree(src, dst, ignore=shutil.ignore_patterns("__pycache__", "*.pyc", ".git"))


def build(out, name, org, kind, packages, force, git, author, branding=None):
    repo = os.path.join(out, name)
    if os.path.exists(repo):
        if not force:
            raise SystemExit(f"{repo} exists (use --force to replace it)")
        shutil.rmtree(repo, onerror=lambda f, p, e: (os.chmod(p, 0o700), f(p)))
    folder = "recipes" if kind == "recipe" else "extensions"
    os.makedirs(os.path.join(repo, folder))
    entries = {}
    for src in packages:
        m = load(src)
        n = m["name"]
        copy_package(src, os.path.join(repo, folder, n))
        entries[n] = dict(version=m["version"], kind=m["kind"], path=f"{folder}/{n}", title=m.get("title", n),
                          requires_core=m["requires_core"], audience=m.get("audience", "generic"), core=n in CORE_RECIPES)
    def w(rel, text):
        p = os.path.join(repo, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
    w("index.toml", index_text(entries))
    # the look of the repository: every file of the branding folder (default: .github/branding of this repository) goes to .github/branding
    bdir = branding or os.path.join(ROOT, ".github", "branding")
    if os.path.isdir(bdir):
        shutil.copytree(bdir, os.path.join(repo, ".github", "branding"))
    banner = next((f for f in ("banner@2x.webp", "banner.png", "banner.svg") if os.path.isfile(os.path.join(repo, ".github", "branding", f))), None)
    w("README.md", readme(name, org, kind, banner))
    w("CONTRIBUTING.md", contributing(kind))
    w(".gitignore", "__pycache__/\n*.pyc\n")
    w("LICENSE", MIT)
    w("SECURITY.md", security(name, org))
    w(".github/workflows/check.yml", WORKFLOW.format(org=org, folder=folder, treename="packages" if kind == "recipe" else "capabilities"))
    if git:
        sha = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
        def g(*a):
            subprocess.run(["git", *a], cwd=repo, check=True, capture_output=True)
        g("init", "-q", "-b", "main")
        g("add", "-A")
        g("-c", "user.name=" + author[0], "-c", "user.email=" + author[1], "-c", "commit.gpgsign=false", "commit", "-q", "-m",
          f"Initial import of the {kind} packages from the homeserver repository ({sha or 'unknown'})")
    return repo, len(entries)


def main(argv):
    out, branding, author = None, None, None
    org, force, git = "hobnix", False, True
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--out":
            out = argv[i + 1]; i += 1
        elif a == "--org":
            org = argv[i + 1]; i += 1
        elif a == "--branding":
            branding = argv[i + 1]; i += 1
        elif a == "--author":
            author = tuple(x.strip() for x in argv[i + 1].replace(">", "").split("<")); i += 1
        elif a == "--force":
            force = True
        elif a == "--no-git":
            git = False
        else:
            print(__doc__)
            return 1
        i += 1
    if not out:
        print("give --out <folder>: the two repositories are created inside it")
        return 1
    if not author:      # the git identity of the person running this (git config user.name / user.email), never a made-up one
        def cfg(k):
            return subprocess.run(["git", "config", k], cwd=ROOT, capture_output=True, text=True).stdout.strip()
        author = (cfg("user.name"), cfg("user.email"))
    if not all(author):
        print("no author: set git config user.name / user.email or pass --author 'Name <mail>'")
        return 1
    recipes = [os.path.join(ROOT, "packages", n) for n in sorted(os.listdir(os.path.join(ROOT, "packages")))
               if os.path.isfile(os.path.join(ROOT, "packages", n, "package.toml"))]
    exts = [os.path.join(ROOT, "capabilities", n) for n in EXTENSIONS]
    for name, kind, pk in (("recipes", "recipe", recipes), ("extensions", "extension", exts)):
        repo, n = build(out, name, org, kind, pk, force, git, author, branding)
        print(f"{repo}: {n} packages")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
