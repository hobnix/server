"""hs pkg new: start a package in a checkout of a package repository (docs/PLAN-packages.md). Standard library only.

  pkg.py new <name> --template recipe|extension [--dir <path>] [--title <text>] [--title-de <text>]

Writes <dir>/recipes/<name>/ (recipe) or <dir>/extensions/<name>/ (extension) and appends [package.<name>] to <dir>/index.toml, so that
`pkg.py validate` (the folder linked as packages/ or capabilities/, as the repositories' CI does) and `pkg.py repo-check <dir>` pass without
edits. Never overwrites anything. A capability template waits for the service extensions (#238).
Output, read by scripts/pkg.sh only (not a contract with the web interface):
  done:    folder TAB <absolute package folder>, then one `file TAB <path inside it>` per file, then `index TAB <absolute index.toml>`; exit 0
  refused: error TAB <code> TAB <detail, - when none>; exit 2. Codes: usage, template, name, title, notrepo, exists, write
"""
import os
import re
import shutil
import tomllib

SUB = {"recipe": "recipes", "extension": "extensions"}
RESERVED = ("list", "enable", "disable")   # words of `hs ext`
VERSION = "0.1.0"
REQUIRES = ">=1"   # the templates use level-1 helpers only

R_PACKAGE = '''# Manifest of a package (docs/PLAN-packages.md of the core). Raise version here AND in index.toml with every change.
name = "{name}"
version = "0.1.0"
kind = "recipe"
title = {q_title}
title_de = {q_title_de}
requires_core = ">=1"
audience = "generic"
needs = []
uses = []
runs = ["lxc"]
input = "none"
script = "run.sh"
'''

R_RUN = '''#!/usr/bin/env bash
# recipe: {title}
# recipe.de: {title_de}
# kind: generic
# needs: -
# uses: -
set -euo pipefail

# What it does: creates the container "{name}" and runs one step inside it. Replace that step with the installation of your app, built
# from the helpers of the core (scripts/recipes/_lib.sh: ensure_container, step, in_ct, fetch_pinned, wait_page, declare_service, docs_hint).
# Rules: pin every download (version and sha256), print no raw command output, never read a secret from argv or the environment, never
# open a public route for an admin page. The header lines above and package.toml must agree (python3 <core>/scripts/pkg.py validate).
scripts=${HS_SCRIPTS:-$(dirname "$0")/../../scripts}
ct=${RECIPE_NAME:-{name}}
. "${HS_RECIPE_LIB:-$scripts/recipes/_lib.sh}"

if [ "${1:-}" = --dry-run ]; then
  say "Would:"
  say "$(t "  create the container '%s' (1024 MB RAM limit) unless it exists" "$ct")"
  exit 0
fi

ensure_container "$ct" 1024
step "$(t 'Set up %s' "$ct")"
in_ct "Checking the container" 'true'
box <<DONE
$(t 'Done: the container %s is ready.' "$ct")
$(docs_hint {name})
DONE
'''

R_GUIDE = '''# {title}

{title}. This guide installs it with two commands. Not tested on hardware yet.

## Before you start

- An installed server: see [Install](install.md).

## Install it

```bash
hs pkg install {name}
```

```bash
hs recipe {name}
```

The recipe creates the container `{name}` and sets it up. Running it again changes only what is not current.

## Check that it worked

- `hs ct list` shows the container `{name}` as running.

## If something goes wrong

| Symptom | Cause | Fix |
| --- | --- | --- |
| The recipe stops with an error | a step inside the container failed | run `hs recipe {name}` again; `hs doctor` checks the server |

## Next

- [Containers and apps](containers-and-apps.md)
'''

X_PACKAGE = '''# Manifest of a package (docs/PLAN-packages.md of the core). Raise version here AND in index.toml with every change.
name = "{name}"
version = "0.1.0"
kind = "extension"
title = {q_title}
title_de = {q_title_de}
requires_core = ">=1"
audience = "generic"
'''

X_CAP = '''# Manifest of the extension (docs/PLAN-extensions.md of the core): the commands are in commands.tsv, the scripts in this folder (@/file).
name = "{name}"
title = {q_title}
title_de = {q_title_de}
kind = "feature"
requires = []
provides = []
needs = []
# No NixOS module: scripts only. Off until `hs ext enable {name}` (no rebuild).
notes = "NOTES.md"
extension = true

# What the web interface may read while the extension is on: each read is a `sys ext {name} ...` row of commands.tsv.
[[web.reads]]
words = "list"
kind = "tsv"
ttl = 30
'''

X_COMMANDS = '''# Commands of the extension package "{name}" (docs/PLAN-extensions.md of the core). Same columns as scripts/lib/registry.tsv of the core:
# kind\tpath\tscript\targs\thelp\thelp.de\tflags
# Only rows under this package's own name (user: ext {name} ..., sys: sys ext {name} ...) are loaded, and only while the package is on.
user\text {name} list\t@/list.sh\tlist\tthe saved entries of {name}: name and value\tdie gespeicherten Einträge von {name}: Name und Wert\ttopic:system,reads
sys\tsys ext {name} list\t@/list.sh\t--list\tthe saved entries of {name} as data: name, value (- when empty)\t-
'''

X_LIST = '''#!/usr/bin/env bash
# help: the saved entries of {name}
# help.de: die gespeicherten Einträge von {name}
# args: list | --list
# The example command of the extension {name}: replace it with your own. It reads <state>/{name}/entries (name TAB value per line).
# --list (hs sys ext {name} list) = name TAB value, one row per entry, no header, nothing when there is none; an empty value is written -
# (machine readable: the web interface reads it; never change its shape once it is released). HS_STATE_DIR points tests at another folder.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
scripts=${HS_SCRIPTS:-$here/../../scripts}   # the core helpers; hs and hs-web set HS_SCRIPTS
. "$scripts/lib/ui.sh"
file=${HS_STATE_DIR:-/var/lib/hs}/{name}/entries

rows() { [ ! -s "$file" ] || awk -F'\\t' 'NF { printf "%s\\t%s\\n", $1, ($2 == "" ? "-" : $2) }' "$file"; }

case "${1:-list}" in
  --list) rows ;;
  list)
    if [ ! -s "$file" ]; then note "Nothing saved yet."; exit 0; fi
    { thead 'Name' 'Value'; rows; } | table ;;
  *) say "usage: hs ext {name} list"; exit 1 ;;
esac
'''

X_NOTES = '''# {name}

{title}. An extension package (docs/PLAN-extensions.md of the core): switch it on with `hs ext enable {name}` (no rebuild).
Commands: commands.tsv (`hs ext {name} list`, `hs sys ext {name} list`); the web read `list` is declared in capability.toml.
Scripts: list.sh in this folder; it finds the core helpers through HS_SCRIPTS, which hs sets.
'''

X_GUIDE = '''# {title}

{title}. Not tested on hardware yet.

## Before you start

- An installed server: see [Install](install.md).

## Switch it on

```bash
hs pkg install {name}
```

```bash
hs ext enable {name}
```

## Show the entries

```bash
hs ext {name} list
```

## Check that it worked

- `hs ext list` shows `{name}` as on.

## If something goes wrong

| Symptom | Cause | Fix |
| --- | --- | --- |
| `hs ext {name} list` is unknown | the extension is off | `hs ext enable {name}` |

## Next

- [Containers and apps](containers-and-apps.md)
'''

# (path inside the folder, text, mode)
TEMPLATES = {
    "recipe": [("package.toml", R_PACKAGE, 0o644), ("run.sh", R_RUN, 0o755), ("guide.md", R_GUIDE, 0o644)],
    "extension": [("package.toml", X_PACKAGE, 0o644), ("capability.toml", X_CAP, 0o644), ("commands.tsv", X_COMMANDS, 0o644),
                  ("list.sh", X_LIST, 0o755), ("NOTES.md", X_NOTES, 0o644), ("guide.md", X_GUIDE, 0o644)],
}

OPTIONS = ("--template", "--dir", "--title", "--title-de")


def refuse(code, detail="-"):
    print("error\t%s\t%s" % (code, detail or "-"))
    return 2


def bad_title(s):
    return len(s) > 100 or any(ord(c) < 0x20 or ord(c) == 0x7f for c in s) or s != s.strip()


def render(text, name, title, title_de, q):
    vals = {"q_title_de": q(title_de), "q_title": q(title), "title_de": title_de, "title": title, "name": name}
    return re.sub(r"\{(q_title_de|q_title|title_de|title|name)\}", lambda m: vals[m.group(1)], text)


def run(main, argv):
    opts, name, i = {}, None, 0
    while i < len(argv):
        a = argv[i]
        if a.startswith("--"):
            if a not in OPTIONS or i + 1 >= len(argv):
                return refuse("usage")
            opts[a] = argv[i + 1]
            i += 2
        else:
            if name is not None:
                return refuse("usage")
            name = a
            i += 1
    if name is None or "--template" not in opts:
        return refuse("usage")
    template = opts["--template"]
    if template not in SUB:
        return refuse("template", template)
    if not main.NAME.fullmatch(name) or name in RESERVED:
        return refuse("name", name)
    title = opts.get("--title", name)
    title_de = opts.get("--title-de", title)
    if bad_title(title) or bad_title(title_de):
        return refuse("title")
    d = os.path.abspath(opts.get("--dir") or os.getcwd())
    sub = SUB[template]
    index = os.path.join(d, "index.toml")
    if not os.path.isfile(index) or not os.path.isdir(os.path.join(d, sub)):
        return refuse("notrepo", d)
    try:
        with open(index, "rb") as f:
            parsed = tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError):
        return refuse("notrepo", d)
    folder = os.path.join(d, sub, name)
    pk = parsed.get("package")
    if (isinstance(pk, dict) and name in pk) or os.path.lexists(folder):
        return refuse("exists", name)
    entry = ('\n[package.%s]\nversion = "%s"\nkind = "%s"\npath = "%s/%s"\ntitle = %s\nrequires_core = "%s"\naudience = "generic"\n'
             % (name, VERSION, template, sub, name, main.q(title), REQUIRES))
    new = index + ".new"
    files = []
    try:
        os.mkdir(folder)
        for rel, text, mode in TEMPLATES[template]:
            p = os.path.join(folder, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w", encoding="utf-8", newline="\n") as f:
                f.write(render(text, name, title, title_de, main.q))
            os.chmod(p, mode)
            files.append(rel)
        with open(index, "rb") as f:
            data = f.read()
        if data and not data.endswith(b"\n"):
            data += b"\n"
        with open(new, "wb") as f:
            f.write(data + entry.encode("utf-8"))
        shutil.copymode(index, new)
        os.replace(new, index)
    except OSError as e:
        shutil.rmtree(folder, ignore_errors=True)
        try:
            os.remove(new)
        except OSError:
            pass
        return refuse("write", str(e).replace("\t", " ").replace("\n", " "))
    print("folder\t" + folder)
    for rel in files:
        print("file\t" + rel)
    print("index\t" + index)
    return 0
