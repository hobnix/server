"""Permissions a package declares in package.toml `permissions = [...]` (ADR 0014, hobnix/server#239). Python stdlib only, no CLI.

This is step 1 of the ADR: DECLARE and DISCLOSE. A permission is a statement the author makes and the administrator reads (hs ext list,
hs pkg install, the diff of hs pkg update); the core checks that the declaration is well formed and that it covers what the manifest
itself uses. Commands still run as root: a declared permission is NOT a sandbox and nothing here confines a package (ADR 0014, "Consequences").

A permission is "key" or "key:argument". Keys:
  web.read, web.change         the package has [[web.reads]] / [[web.changes]] (no argument)
  events.emit:<kind-glob>      kinds it may write; must lie below pkg.<name>. (the rule event kinds already follow)
  events.subscribe:<glob>      event kinds a service receives (ADR 0010/0011)
  fs.read:<path>, fs.write:<path>   an absolute path, no "..", no space
  net:none|lan|internet        outgoing connections (the meaning is the owner's decision, ADR 0014 open point 2: declared only)
  host:<command>               an hs command or system tool it calls (incus, systemctl, ...)
  secrets:<name>               a secret read through scripts/lib/secret.sh
  devices:gpu                  a device
A manifest without `permissions` is "not declared": it still installs (existing packages), and is shown as such.
Once `permissions` exists it must cover what the manifest uses: [[events]] needs events.emit, [[web.reads]] web.read, [[web.changes]] web.change.
"""
import re

KEYS = {
    "web.read": None, "web.change": None,
    "events.emit": re.compile(r"^pkg\.[a-z][a-z0-9-]{0,40}\.[a-z0-9*.-]{1,60}$"),
    "events.subscribe": re.compile(r"^[a-z0-9*][a-z0-9*.-]{0,79}$"),
    "fs.read": re.compile(r"^/[A-Za-z0-9._/-]{0,200}$"),
    "fs.write": re.compile(r"^/[A-Za-z0-9._/-]{0,200}$"),
    "net": re.compile(r"^(none|lan|internet)$"),
    "host": re.compile(r"^[a-z][a-z0-9._-]{0,40}$"),
    "secrets": re.compile(r"^[a-z][a-z0-9_-]{0,40}$"),
    "devices": re.compile(r"^gpu$"),
}


def split(p):
    key, _, arg = str(p).partition(":")
    return key, arg


def check_one(name, p):
    """The problem with one permission string, or None."""
    if not isinstance(p, str) or not p:
        return "a permission is a non-empty text"
    key, arg = split(p)
    if key not in KEYS:
        return "unknown permission %s (known: %s)" % (key, ", ".join(sorted(KEYS)))
    rx = KEYS[key]
    if rx is None:
        return None if ":" not in p else "%s takes no argument" % key
    if not arg:
        return "%s needs an argument (%s:...)" % (key, key)
    if not rx.match(arg) or ".." in arg.split("/"):
        return "%s: argument %r is not allowed" % (key, arg)
    if key == "events.emit" and not arg.startswith("pkg.%s." % name):
        return "events.emit must lie below pkg.%s. (got %s)" % (name, arg)
    return None


def manifest_problems(name, m, web=None):
    """[text] for the `permissions` of a package.toml dict `m`; `web` = the parsed capability.toml of an extension (its [[web.*]] tables) or None."""
    if "permissions" not in m:
        return []
    perms = m["permissions"]
    if not isinstance(perms, list):
        return ["permissions must be a list of texts"]
    out = []
    for p in perms:
        t = check_one(name, p)
        if t:
            out.append(t)
    if len(set(map(str, perms))) != len(perms):
        out.append("permissions lists the same permission twice")
    if out:
        return out
    have = set(perms)
    keys = {split(p)[0] for p in perms}
    if m.get("events") and "events.emit" not in keys:
        out.append("the package declares [[events]] but not events.emit:pkg.%s.*" % name)
    elif m.get("events"):
        globs = [split(p)[1] for p in perms if split(p)[0] == "events.emit"]
        for e in m["events"]:
            k = "pkg.%s.%s" % (name, e.get("kind", ""))
            if not any(_glob(g, k) for g in globs):
                out.append("event %s is not covered by events.emit" % k)
    web = web or {}
    wm = web.get("web", {}) if isinstance(web.get("web"), dict) else {}
    if wm.get("reads") and "web.read" not in have:
        out.append("the package declares [[web.reads]] but not web.read")
    if wm.get("changes") and "web.change" not in have:
        out.append("the package declares [[web.changes]] but not web.change")
    return out


def folder_problems(name, folder):
    """ENFORCEMENT (ADR 0014 step 1b): [text] when the package in `folder` declares `permissions` that do not cover what its manifests use.
    The loaders call this at run time (web reads/changes/pages and the live collector skip such a package) and `hs ext enable` refuses it, so a
    manifest edited after install, or a package that skipped the install check, cannot use more than it declared. A package without
    `permissions` is not checked (existing packages). Nothing here confines a command: it still runs as root."""
    import os
    import tomllib
    try:
        with open(os.path.join(folder, "package.toml"), "rb") as f:
            m = tomllib.load(f)
    except OSError:
        return []
    except tomllib.TOMLDecodeError as e:
        return ["package.toml is not valid TOML (%s)" % e]
    if "permissions" not in m:
        return []
    web = {}
    try:
        with open(os.path.join(folder, "capability.toml"), "rb") as f:
            web = tomllib.load(f)
    except OSError:
        pass
    except tomllib.TOMLDecodeError as e:
        return ["capability.toml is not valid TOML (%s)" % e]
    return manifest_problems(name, m, web)


def _glob(g, k):
    return re.match("^" + re.escape(g).replace(r"\*", ".*") + "$", k) is not None


def of(m):
    """The declared permissions as a list, or None when the manifest does not declare any (absent is not the same as empty)."""
    p = m.get("permissions")
    return [str(x) for x in p] if isinstance(p, list) else None


def added(old, new):
    """The permissions `new` has and `old` lacks. An undeclared old manifest counts as none: everything declared is then new."""
    have = set(old or [])
    return [p for p in (new or []) if p not in have]


def describe(perms):
    """One line for people."""
    if perms is None:
        return "not declared"
    return ", ".join(perms) if perms else "none"
