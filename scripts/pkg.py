#!/usr/bin/env python3
"""Packages: recipes and extensions as one thing (docs/PLAN-packages.md, step 1). Standard library only.

  pkg.py list [--kind recipe|extension] [--all] [--json]   name, kind, version, audience, title (personal ones only with --all)
  pkg.py updates                                           packages whose tree version is newer than the recorded one
  pkg.py repo-check [<folder>]                             check a package repository checkout: index.toml against its folders
  pkg.py validate                                          check every manifest (and that a recipe's header agrees); exit 1 on a problem
  pkg.py convert <recipe-script>                           print the package.toml for a recipe written with header lines
  pkg.py record <name>                                     remember the tree's version as installed (installed.toml)
  pkg.py api                                               the API level of the core helpers

Repositories (docs/PLAN-packages.md, "Repositories" and "Trust"); the git work is `git`, signatures are SSH signatures on release tags:
  pkg.py repo list                                         name, url, signed|unsigned, default|added
  pkg.py repo add <name> <url> (--key <allowed_signers> | --unsigned)
  pkg.py repo remove <name>                                an added repository (the two defaults stay)
  pkg.py fetch [<repo>]                                    update the local clones and find the newest tag whose signature verifies
  pkg.py available                                         packages in the repositories (cache): repo, name, kind, version, installed
  pkg.py install <name> [--repo <repo>]                    fetch the package at the verified tag into <state>/packages/current/<name>
  pkg.py update <name> [--yes]                             show the diff to the installed commit, ask, install the new tag
  pkg.py remove <name>                                     forget an installed repository package (a recipe's container is never touched)

Manifests: packages/<name>/package.toml (a recipe: its script is run.sh beside it) and
capabilities/<name>/package.toml (an extension). Knobs for tests: HS_PACKAGES_ROOT (the checkout), HS_STATE_DIR (installed.toml).
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
KINDS = ("recipe", "extension")
AUDIENCES = ("generic", "personal")
NEEDS = ("docker", "share", "tailscale")
USES = ("gpu",)
DEVICE_KINDS = ("usb",)
INPUTS = ("none", "form", "terminal")
ASK_TYPES = re.compile(r"^(text|secret|choice|usb)$")
NAME = re.compile(r"^[a-z][a-z0-9-]{0,40}$")
SEMVER = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
DEVICE_ID = re.compile(r"^[0-9a-f]{4}:[0-9a-f]{4}$")
REQUIRES = re.compile(r"^>=\s*([1-9]\d*)$")


def root():
    for r in (os.environ.get("HS_PACKAGES_ROOT"), os.path.dirname(HERE), "/etc/nixos"):
        if r and os.path.isdir(os.path.join(r, "packages")):
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
            for k in ("version", "repo", "commit", "tag"):
                if k in data[n]:
                    o.write(f"{k} = {q(str(data[n][k]))}\n")
            o.write("\n")
    os.replace(f + ".new", f)


def header(path):
    """The comment header of a recipe script: dict of key -> value, asks as a list."""
    h, asks, devices = {}, [], []
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = re.match(r"^# ([a-z.]+): ?(.*)$", line.rstrip("\n"))
            if not m:
                continue
            k, v = m.groups()
            if k == "ask":
                asks.append(v)
            elif k == "device":
                devices.append(v)
            else:
                h.setdefault(k, v)
    h["asks"] = asks
    h["devices"] = devices
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
    devs = [d.split("|") + [""] * 3 for d in h["devices"]]
    lines = [
        "# Manifest of a package (docs/PLAN-packages.md). Until the packages move out of this repository the header lines of the",
        "# script still say the same (tests/pkg.sh keeps both in step).",
        f"name = {q(name)}",
        'version = "1.0.0"',
        'kind = "recipe"',
        f"title = {q(title)}",
        f"title_de = {q(title_de)}",
        f"requires_core = \">={2 if devs else 1}\"",
        f"audience = {q(h.get('kind', 'generic'))}",
        f"needs = {json.dumps(needs)}",
        f"uses = {json.dumps(uses)}",
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
    for d in devs:
        lines += ["", "[[device]]", f"kind = {q(d[0])}", f"name = {q(d[1])}"]
        lines.append(f"ask = {q(d[2][4:])}" if d[2].startswith("ask:") else f"id = {q(d[2])}")
    return "\n".join(lines) + "\n"


def device_key(kind, name, id_, ask):
    """The '# device:' header form of a [[device]] table: kind|name|id or kind|name|ask:KEY."""
    return f"{kind}|{name}|" + (f"ask:{ask}" if ask else str(id_))


def problems():
    """[(package, text)] for every manifest."""
    out, seen = [], {}
    r = root()
    level = api_level()
    for path, m in manifests():
        folder = os.path.basename(os.path.dirname(path))
        n = m.get("name", "?")

        def bad(t, n=n):
            out.append((n, t))

        if not NAME.match(str(n)):
            bad("name is not a lowercase word")
        if n != folder:
            bad(f"name differs from the folder ({folder})")
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
            if m.get("input", "none") not in INPUTS:
                bad("input is not none, form or terminal")
            s = m.get("script", "")
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
                if h.get("input", "none") != m.get("input", "none"):
                    bad("input differs from the script's '# input:' header")
                keys = [a.split("|")[0] for a in h["asks"]]
                if keys != [a.get("key") for a in m.get("ask", [])]:
                    bad("questions differ from the script's '# ask:' headers")
            devs = m.get("device", [])
            if devs and int(rq.group(1) if rq else 0) < 2:
                bad("a [[device]] needs requires_core >=2")
            if s and os.path.isfile(sp):
                want = [device_key(d.get("kind"), d.get("name"), d.get("id"), d.get("ask")) for d in devs]
                if want != h["devices"]:
                    bad("devices differ from the script's '# device:' headers")
            ask_keys = [a.get("key") for a in m.get("ask", [])]
            seen_dev = set()
            for d in devs:
                dn = d.get("name")
                if d.get("kind") not in DEVICE_KINDS:
                    bad(f"unknown device kind {d.get('kind')} (v1: usb)")
                if not NAME.match(str(dn)):
                    bad(f"device {dn}: name is not a lowercase word")
                if dn in seen_dev:
                    bad(f"device {dn}: name used twice")
                seen_dev.add(dn)
                if ("id" in d) == ("ask" in d):
                    bad(f"device {dn}: give exactly one of id or ask")
                elif "id" in d and not DEVICE_ID.match(str(d["id"])):
                    bad(f"device {dn}: id must look like 04f9:0042")
                elif "ask" in d and d["ask"] not in ask_keys:
                    bad(f"device {dn}: ask {d['ask']} is not an [[ask]] key")
                elif "ask" in d and {a.get("key"): a.get("type") for a in m.get("ask", [])}.get(d["ask"]) != "usb":
                    bad(f"device {dn}: ask {d['ask']} must have type usb")
            if m.get("input", "none") == "form" and not m.get("ask"):
                bad("a form recipe declares questions")
            for a in m.get("ask", []):
                if not ASK_TYPES.match(str(a.get("type", ""))):
                    bad(f"question {a.get('key')}: type is not text, secret, choice or usb")
                if a.get("type") == "choice" and not a.get("choices"):
                    bad(f"question {a.get('key')}: a choice needs choices")
                if not a.get("label"):
                    bad(f"question {a.get('key')}: label missing")
        else:
            if not os.path.isfile(os.path.join(os.path.dirname(path), "capability.toml")):
                bad("an extension needs its capability.toml beside package.toml")
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
    elif cmd in ("repo", "fetch", "available", "install", "update", "remove"):
        spec = importlib.util.spec_from_file_location("pkg_repo", os.path.join(HERE, "pkg_repo.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod.run(MAIN, cmd, rest)
    elif cmd == "repo-check":
        p = repo_check(rest[0] if rest else ".")
        for t in p:
            print(t)
        return 1 if p else 0
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
        data[rest[0]] = {"version": known[rest[0]]}
        f = installed_file()
        os.makedirs(os.path.dirname(f), exist_ok=True)
        with open(f + ".new", "w", encoding="utf-8") as o:
            for n in sorted(data):
                o.write(f"[package.{n}]\nversion = {q(data[n]['version'])}\n\n")
        os.replace(f + ".new", f)
    else:
        print(__doc__)
        return 1
    return 0


MAIN = sys.modules[__name__]
if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
