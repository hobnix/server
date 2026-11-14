#!/usr/bin/env python3
"""Packages: recipes and extensions as one thing (docs/PLAN-packages.md, step 1). Standard library only.

  pkg.py list [--kind recipe|extension] [--all] [--json]   name, kind, version, audience, title (personal ones only with --all)
  pkg.py updates                                           packages whose tree version is newer than the recorded one
  pkg.py repo-check [<folder>]                             check a package repository checkout: index.toml against its folders
  pkg.py repo-unbumped <tag> [<folder>]                    packages of a repository checkout whose folder changed since <tag> without a version rise (package.toml AND index.toml); exit 1 when any
  pkg.py validate                                          check every manifest (and that a recipe's header agrees); exit 1 on a problem
  pkg.py check-draft                                       a package.toml draft on stdin: level, where, text per finding; exit 1 on an error (web package builder)
  pkg.py convert <recipe-script>                           print the package.toml for a recipe written with header lines
  pkg.py record <name> [--applied]                         remember the tree's version as installed (installed.toml); --applied: a run applied it
  pkg.py applied                                           name, version the last successful run applied
  pkg.py api                                               the API level of the core helpers
  pkg.py perms-check <folder> [name]                       exit 1 and the reasons when the declared permissions do not cover what the package uses (hs ext enable refuses it)
  pkg.py perms <name>                                      the permissions the package declares, one per line; "-" when it declares none (ADR 0014: declared, not enforced)
  pkg.py new <name> --template recipe|extension [--dir <path>]  start a package in a checkout of a package repository (pkg_new.py)

Repositories (docs/PLAN-packages.md, "Repositories" and "Trust"); the git work is `git`, signatures are SSH signatures on release tags:
  pkg.py repo list                                         name, url, signed|unsigned, default|added
  pkg.py repo add <name> <url> (--key <allowed_signers> | --unsigned)
  pkg.py repo remove <name>                                an added repository (the two defaults stay)
  pkg.py fetch [<repo>]                                    update the local clones and find the newest tag whose signature verifies
  pkg.py available                                         packages in the repositories (cache): repo, name, kind, version, installed
  pkg.py market                                            everything installable as data: name, kind, repo, version, installed, state (new|current|update|orphan), core, audience, title
  pkg.py install <name> [--repo <repo>]                    fetch the package at the verified tag into <state>/packages/current/<name>
  pkg.py update <name> [--yes] [--accept-permissions]     show the diff and the permissions, ask, install the new tag; NEW permissions need the typed name (or the flag)
  pkg.py remove <name>                                     forget an installed repository package (a recipe's container is never touched)

Manifests: packages/<name>/package.toml (a recipe: its script is run.sh beside it) and
capabilities/<name>/package.toml (an extension). [[events]] of a manifest -> <state>/pkg-events/<name>.tsv (scripts/lib/pkg_events.py).
Knobs for tests: HS_PACKAGES_ROOT (the checkout), HS_STATE_DIR (installed.toml), HS_PKG_EVENTS_DIR (the installed events).
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import io
import importlib.util
import tomllib

HERE = os.path.dirname(os.path.abspath(__file__))


def _load_pkg_events():
    spec = importlib.util.spec_from_file_location("pkg_events", os.path.join(HERE, "lib", "pkg_events.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


pkg_events = _load_pkg_events()


def _load_pkg_perms():
    spec = importlib.util.spec_from_file_location("pkg_perms", os.path.join(HERE, "lib", "pkg_perms.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


pkg_perms = _load_pkg_perms()


def capability_toml(folder):
    """The parsed capability.toml beside a package.toml (an extension's [[web.*]] live there), {} when absent or invalid."""
    try:
        with open(os.path.join(folder, "capability.toml"), "rb") as f:
            return tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError):
        return {}
KINDS = ("recipe", "extension")
AUDIENCES = ("generic", "personal")
NEEDS = ("docker", "share", "tailscale")
USES = ("gpu",)
INPUTS = ("none", "form", "terminal")
RUNS = ("lxc", "docker", "vm")
ASK_TYPES = re.compile(r"^(text|secret|choice)$")
NAME = re.compile(r"^[a-z][a-z0-9-]{0,40}$")
SEMVER = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
REQUIRES = re.compile(r"^>=\s*([1-9]\d*)$")


def root():
    """The tree with config/ (the default repositories, the trusted keys) and, in a checkout that still has them, packages/ and capabilities/.
    The scripts run from a copy in the Nix store that has no config/: the checkout in /etc/nixos (HS_NIXOS_DIR in tests) is the source then."""
    env = os.environ.get("HS_PACKAGES_ROOT")
    if env and os.path.isdir(env):
        return env
    for r in (os.path.dirname(HERE), os.environ.get("HS_NIXOS_DIR", "/etc/nixos")):
        if os.path.isfile(os.path.join(r, "config", "package-repos.toml")):
            return r
    return os.path.dirname(HERE)


def api_level():
    with open(os.path.join(HERE, "lib", "api-level"), encoding="utf-8") as f:
        return int(f.read().split()[0])


def semver_key(v):
    return tuple(int(x) for x in v.split("."))


def state_dir():
    return os.path.join(os.environ.get("HS_STATE_DIR", "/var/lib/hs"), "packages")


def manifests():
    """[(path, dict)] of every package.toml: recipes under packages/, extensions under capabilities/, then the packages installed from repositories."""
    r, out = root(), []
    for d in (os.path.join(r, "packages"), os.path.join(r, "capabilities"), os.path.join(state_dir(), "current")):
        if not os.path.isdir(d):
            continue
        for n in sorted(os.listdir(d)):
            p = os.path.join(d, n, "package.toml")
            if os.path.isfile(p):
                with open(p, "rb") as f:
                    out.append((p, tomllib.load(f)))
    return out


def installed_file():
    return os.path.join(state_dir(), "installed.toml")


def installed():
    try:
        with open(installed_file(), "rb") as f:
            return tomllib.load(f).get("package", {})
    except (OSError, tomllib.TOMLDecodeError):
        return {}


def save_installed(data):
    f = installed_file()
    os.makedirs(os.path.dirname(f), exist_ok=True)
    with open(f + ".new", "w", encoding="utf-8") as o:
        for n in sorted(data):
            o.write(f"[package.{n}]\n")
            for k in ("version", "applied", "repo", "commit", "tag"):
                if k in data[n]:
                    o.write(f"{k} = {q(str(data[n][k]))}\n")
            o.write("\n")
    os.replace(f + ".new", f)


def header(path):
    """The comment header of a recipe script: dict of key -> value, asks as a list."""
    h, asks = {}, []
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = re.match(r"^# ([a-z.]+): ?(.*)$", line.rstrip("\n"))
            if not m:
                continue
            k, v = m.groups()
            if k == "ask":
                asks.append(v)
            else:
                h.setdefault(k, v)
    h["asks"] = asks
    return h


def q(s):
    return json.dumps(s, ensure_ascii=False)


def convert(script):
    """package.toml text for a recipe script with header lines."""
    h = header(script)
    name = os.path.basename(script)[:-3]
    title = (h.get("recipe") or name).split(": ", 1)[-1] if h.get("recipe") else name
    title_de = (h.get("recipe.de") or h.get("recipe") or name).split(": ", 1)[-1]
    needs = [w for w in h.get("needs", "-").split() if w != "-"]
    uses = [w for w in h.get("uses", "-").split() if w != "-"]
    runs = h.get("runs", "lxc").split() or ["lxc"]
    lines = [
        "# Manifest of a package (docs/PLAN-packages.md). Until the packages move out of this repository the header lines of the",
        "# script still say the same (tests/pkg.sh keeps both in step).",
        f"name = {q(name)}",
        'version = "1.0.0"',
        'kind = "recipe"',
        f"title = {q(title)}",
        f"title_de = {q(title_de)}",
        "requires_core = \">=1\"",
        f"audience = {q(h.get('kind', 'generic'))}",
        f"needs = {json.dumps(needs)}",
        f"uses = {json.dumps(uses)}",
        f"runs = {json.dumps(runs)}",
        f"input = {q(h.get('input', 'none'))}",
        f"script = {q('run.sh')}",
    ]
    for a in h["asks"]:
        f = a.split("|")
        f += [""] * (8 - len(f))
        key, label, typ, default, pattern, when = f[0], f[1], f[2], f[3], f[4], f[5]
        kind, _, choices = typ.partition(":")
        lines += ["", "[[ask]]", f"key = {q(key)}", f"label = {q(label)}", f"type = {q(kind)}"]
        if choices:
            lines.append(f"choices = {json.dumps(choices.split(','))}")
        if default:
            lines.append(f"default = {q(default)}")
        if pattern:
            lines.append(f"pattern = {q(pattern)}")
        if when:
            lines.append(f"when = {q(when)}")
    return "\n".join(lines) + "\n"


def manifest_problems(m, path=None, seen=None):
    """[text] for one package.toml dict. `path` = its file: the checks that need the folder (name = folder, the script and its header, the
    capability.toml of an extension) run only then; None = a draft that is not on disk yet (hs pkg check-draft, the web package builder, ADR 0018)."""
    out = []
    r = root()
    level = api_level()
    n = m.get("name", "?")
    bad = out.append
    if not NAME.match(str(n)):
        bad("name is not a lowercase word")
    if path:
        folder = os.path.basename(os.path.dirname(path))
        if n != folder:
            bad(f"name differs from the folder ({folder})")
        if seen is not None:
            if n in seen:
                bad(f"name also used in {seen[n]}")
            seen[n] = path
    if not SEMVER.match(str(m.get("version", ""))):
        bad("version is not semver (1.2.3)")
    if m.get("kind") not in KINDS:
        bad("kind is not recipe or extension")
    if not m.get("title"):
        bad("title missing")
    rq = REQUIRES.match(str(m.get("requires_core", "")))
    if not rq:
        bad('requires_core must look like ">=1"')
    elif int(rq.group(1)) > level:
        bad(f"requires_core {rq.group(1)} is above the API level {level}")
    if m.get("audience", "generic") not in AUDIENCES:
        bad("audience is not generic or personal")
    if m.get("kind") == "recipe":
        for w in m.get("needs", []):
            if w not in NEEDS:
                bad(f"unknown need {w}")
        for w in m.get("uses", []):
            if w not in USES:
                bad(f"unknown use {w}")
        for w in m.get("runs", ["lxc"]):
            if w not in RUNS:
                bad(f"unknown runtime {w} in runs")
        if m.get("input", "none") not in INPUTS:
            bad("input is not none, form or terminal")
        s = m.get("script", "")
        if path:
            sp = os.path.join(r, s) if s.startswith("scripts/") else os.path.join(os.path.dirname(path), s)
            if not s or ".." in s or s.startswith("/") or not os.path.isfile(sp):
                bad(f"script {s!r} not found (scripts/... of the core, or a file in the package)")
            else:
                h = header(sp)
                if h.get("kind", "generic") != m.get("audience", "generic"):
                    bad("audience differs from the script's '# kind:' header")
                if sorted(w for w in h.get("needs", "-").split() if w != "-") != sorted(m.get("needs", [])):
                    bad("needs differ from the script's '# needs:' header")
                if sorted(w for w in h.get("uses", "-").split() if w != "-") != sorted(m.get("uses", [])):
                    bad("uses differ from the script's '# uses:' header")
                if sorted(h.get("runs", "lxc").split()) != sorted(m.get("runs", ["lxc"])):
                    bad("runs differ from the script's '# runs:' header")
                if h.get("input", "none") != m.get("input", "none"):
                    bad("input differs from the script's '# input:' header")
                keys = [a.split("|")[0] for a in h["asks"]]
                if keys != [a.get("key") for a in m.get("ask", [])]:
                    bad("questions differ from the script's '# ask:' headers")
        elif not s or ".." in s or s.startswith("/"):
            bad(f"script {s!r} must be a file name in the package or scripts/... of the core")
        if m.get("input", "none") == "form" and not m.get("ask"):
            bad("a form recipe declares questions")
        for a in m.get("ask", []):
            if not ASK_TYPES.match(str(a.get("type", ""))):
                bad(f"question {a.get('key')}: type is not text, secret or choice")
            if a.get("type") == "choice" and not a.get("choices"):
                bad(f"question {a.get('key')}: a choice needs choices")
            if not a.get("label"):
                bad(f"question {a.get('key')}: label missing")
    elif path and not os.path.isfile(os.path.join(os.path.dirname(path), "capability.toml")):
        bad("an extension needs its capability.toml beside package.toml")
    for t in pkg_events.manifest_problems(n, m.get("events", [])):
        bad(t)
    for t in pkg_perms.manifest_problems(n, m, capability_toml(os.path.dirname(path)) if path else None):
        bad("permissions: " + t)
    return out


def problems():
    """[(package, text)] for every manifest."""
    out, seen = [], {}
    for path, m in manifests():
        out += [(m.get("name", "?"), t) for t in manifest_problems(m, path, seen)]
    return out


def draft_findings(text):
    """[(level, where, text)] for a package.toml draft given as text: what `hs sys pkg plan check-draft` prints as `finding` lines.
    The same checks as `hs pkg validate` (manifest_problems); only what needs files on disk waits until the package is built."""
    try:
        m = tomllib.loads(text)
    except tomllib.TOMLDecodeError as e:
        return [("error", "-", f"not valid TOML: {e}")]
    out = []
    for t in manifest_problems(m):
        key = t.split(" ", 1)[0].rstrip(":")
        out.append(("error", key if key in ("name", "version", "kind", "title", "requires_core", "audience", "script", "permissions") else "-", t))
    if not out:
        out.append(("warn", "-", "Checked without files: the script and its header lines, and capability.toml, are checked when the package is built (hs pkg validate)."))
    return out


def _git_show(folder, rev, path):
    r = subprocess.run(["git", "-C", folder, "show", f"{rev}:{path}"], capture_output=True)
    return tomllib.loads(r.stdout.decode("utf-8", "replace")) if r.returncode == 0 else None


def _ver(v):
    return tuple(int(x) for x in str(v).split(".")) if SEMVER.match(str(v)) else None


def repo_unbumped(folder, since):
    """Packages whose folder changed since the tag `since` while the version did not rise in package.toml AND index.toml (CI of the package repositories, release PRs).
    A package that is new since the tag, or gone, is not listed; neither is a change outside the package folders."""
    old_idx = _git_show(folder, since, "index.toml")
    if old_idx is None:
        raise ValueError(f"no index.toml at {since}")
    old_idx = old_idx.get("package", {})
    try:
        with open(os.path.join(folder, "index.toml"), "rb") as f:
            idx = tomllib.load(f).get("package", {})
    except (OSError, tomllib.TOMLDecodeError) as e:
        raise ValueError(f"index.toml: {e}")
    out = []
    for name, e in sorted(idx.items()):
        old = old_idx.get(name)
        if old is None:
            continue
        path, oldpath = str(e.get("path", "")), str(old.get("path", ""))
        d = subprocess.run(["git", "-C", folder, "diff", "--name-only", since, "--", path, oldpath], capture_output=True, text=True)
        if d.returncode != 0:
            raise ValueError(f"git diff against {since} failed")
        if not d.stdout.strip():
            continue
        try:
            with open(os.path.join(folder, path, "package.toml"), "rb") as f:
                now_pkg = tomllib.load(f).get("version")
        except (OSError, tomllib.TOMLDecodeError):
            now_pkg = None
        old_pkg = (_git_show(folder, since, f"{oldpath}/package.toml") or {}).get("version")
        rose_pkg = _ver(now_pkg) is not None and _ver(old_pkg) is not None and _ver(now_pkg) > _ver(old_pkg)
        rose_idx = _ver(e.get("version")) is not None and _ver(old.get("version")) is not None and _ver(e.get("version")) > _ver(old.get("version"))
        if not (rose_pkg and rose_idx):
            out.append(f"{name}: changed since {since}, version {old_pkg} -> package.toml {now_pkg}, index.toml {old.get('version')} -> {e.get('version')}")
    return out


def repo_check(folder):
    """Problems of a package REPOSITORY checkout: index.toml against the package folders (what CI of a repository runs)."""
    out = []
    try:
        with open(os.path.join(folder, "index.toml"), "rb") as f:
            idx = tomllib.load(f).get("package", {})
    except (OSError, tomllib.TOMLDecodeError) as e:
        return [f"index.toml: {e}"]
    level = api_level()
    listed = set()
    for name, e in sorted(idx.items()):
        listed.add(os.path.normpath(e.get("path", "")))
        path = str(e.get("path", ""))
        if not re.match(r"^[A-Za-z0-9._/-]+$", path) or ".." in path.split("/"):
            out.append(f"{name}: path {path!r} is not allowed")
            continue
        mf = os.path.join(folder, path, "package.toml")
        try:
            with open(mf, "rb") as f:
                m = tomllib.load(f)
        except (OSError, tomllib.TOMLDecodeError):
            out.append(f"{name}: {path}/package.toml is missing or invalid")
            continue
        if m.get("name") != name:
            out.append(f"{name}: package.toml says name {m.get('name')!r}")
        if m.get("version") != e.get("version"):
            out.append(f"{name}: index version {e.get('version')} differs from package.toml {m.get('version')}")
        if m.get("kind") != e.get("kind"):
            out.append(f"{name}: kind differs between index and package.toml")
        if m.get("requires_core") != e.get("requires_core"):
            out.append(f"{name}: requires_core differs between index and package.toml")
        rq = REQUIRES.match(str(e.get("requires_core", "")))
        if not rq or int(rq.group(1)) > level:
            out.append(f"{name}: requires_core {e.get('requires_core')!r} is not usable at API level {level}")
        if not SEMVER.match(str(e.get("version", ""))):
            out.append(f"{name}: version is not semver")
        out += [f"{name}: {t}" for t in pkg_events.manifest_problems(name, m.get("events", []))]
        out += [f"{name}: permissions: {t}" for t in pkg_perms.manifest_problems(name, m, capability_toml(os.path.join(folder, path)))]
    for sub in ("recipes", "extensions"):
        d = os.path.join(folder, sub)
        if os.path.isdir(d):
            for n in sorted(os.listdir(d)):
                if os.path.isfile(os.path.join(d, n, "package.toml")) and os.path.normpath(f"{sub}/{n}") not in listed:
                    out.append(f"{sub}/{n}: has a package.toml but is not in index.toml")
    return out


def rows(all_=False, kind=None):
    inst = installed()
    out = []
    for _, m in manifests():
        if kind and m.get("kind") != kind:
            continue
        if m.get("audience", "generic") == "personal" and not all_:
            continue
        have = inst.get(m["name"], {}).get("version", "-")
        out.append(dict(name=m["name"], kind=m["kind"], version=m["version"], installed=have,
                        audience=m.get("audience", "generic"), title=m.get("title", "")))
    return out


def main(argv):
    sys.stdout.reconfigure(encoding="utf-8")   # the German titles; a Windows checkout would write its code page
    if not argv:
        print(__doc__)
        return 1
    cmd, rest = argv[0], argv[1:]
    if cmd == "api":
        print(api_level())
    elif cmd == "list":
        kind = rest[rest.index("--kind") + 1] if "--kind" in rest else None
        data = rows("--all" in rest, kind)
        if "--json" in rest:
            print(json.dumps(data))
        else:
            for r in data:
                print("\t".join([r["name"], r["kind"], r["version"], r["installed"], r["audience"], r["title"]]))
    elif cmd == "updates":
        seen = set()
        for r in rows(True):
            if r["installed"] != "-" and semver_key(r["version"]) > semver_key(r["installed"]):
                print("\t".join([r["name"], r["installed"], r["version"]]))
                seen.add(r["name"])
        # packages from a repository: the newest verified release in the cached clones (hs pkg fetch refreshes them)
        spec = importlib.util.spec_from_file_location("pkg_repo", os.path.join(HERE, "pkg_repo.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        cat = mod.Repos(MAIN).catalog()
        for n, have in installed().items():
            if "repo" not in have or n in seen:
                continue
            for r_name, e, _, _ in cat.get(n, []):
                if r_name == have["repo"] and semver_key(e["version"]) > semver_key(have["version"]):
                    print("\t".join([n, have["version"], e["version"]]))
    elif cmd in ("repo", "fetch", "available", "market", "install", "update", "remove"):
        spec = importlib.util.spec_from_file_location("pkg_repo", os.path.join(HERE, "pkg_repo.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod.run(MAIN, cmd, rest)
    elif cmd == "new":
        spec = importlib.util.spec_from_file_location("pkg_new", os.path.join(HERE, "pkg_new.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod.run(MAIN, rest)
    elif cmd == "perms":
        found = [m for _, m in manifests() if m.get("name") == (rest[0] if rest else "")]
        if not found:
            print("unknown package", file=sys.stderr)
            return 1
        for x in pkg_perms.of(found[0]) or ["-"]:
            print(x)
    elif cmd == "perms-check":      # perms-check <folder> [name]: what the declared permissions do not cover (exit 1), used by hs ext enable (ADR 0014)
        if not rest:
            print("usage: pkg.py perms-check <folder> [name]", file=sys.stderr)
            return 2
        p = pkg_perms.folder_problems(rest[1] if len(rest) > 1 else os.path.basename(os.path.abspath(rest[0])), rest[0])
        for t in p:
            print(t)
        return 1 if p else 0
    elif cmd == "repo-check":
        p = repo_check(rest[0] if rest else ".")
        for t in p:
            print(t)
        return 1 if p else 0
    elif cmd == "repo-unbumped":    # repo-unbumped <tag> [<folder>]: changed since the tag without a version rise (exit 1)
        if not rest:
            print("usage: pkg.py repo-unbumped <tag> [<folder>]", file=sys.stderr)
            return 2
        try:
            p = repo_unbumped(rest[1] if len(rest) > 1 else ".", rest[0])
        except ValueError as e:
            print(e, file=sys.stderr)
            return 2
        for t in p:
            print(t)
        return 1 if p else 0
    elif cmd == "check-draft":
        # a package.toml draft on stdin -> level<TAB>where<TAB>text per finding; exit 1 when there is an error
        found = draft_findings(sys.stdin.buffer.read(262144).decode("utf-8", "replace"))
        for lv, where, t in found:
            print(f"{lv}\t{where}\t{t}")
        return 1 if any(f[0] == "error" for f in found) else 0
    elif cmd == "validate":
        p = problems()
        for n, t in p:
            print(f"{n}\t{t}")
        return 1 if p else 0
    elif cmd == "convert":
        sys.stdout.write(convert(rest[0]))
    elif cmd == "record":
        known = {m["name"]: m["version"] for _, m in manifests()}
        if not rest or rest[0] not in known:
            print("unknown package", file=sys.stderr)
            return 1
        data = installed()
        have = data.get(rest[0], {})
        # keep repo/commit/tag of a package installed from a repository, else `hs pkg remove|update` refuse it
        data[rest[0]] = dict(have, version=known[rest[0]])
        if "--applied" in rest[1:]:
            data[rest[0]]["applied"] = known[rest[0]]
        save_installed(data)
    elif cmd == "applied":
        for n, have in sorted(installed().items()):
            if "applied" in have:
                print(f"{n}\t{have['applied']}")
    else:
        print(__doc__)
        return 1
    return 0


MAIN = sys.modules[__name__]
if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
