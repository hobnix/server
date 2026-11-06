#!/usr/bin/env python3
"""Which extension packages are on, where they live, and which of their reads the web interface and the live state may use.
Shared by scripts/web-serve.py (it imports these names) and scripts/live_state.py / live-collect.py (extension reads that opt in to a live topic).
Standard library only. Declaration format: see the comment above EXT_NAME in web-serve.py and docs/PLAN-extensions.md."""
import json
import os
import re

EXT_NAME = re.compile(r"^[a-z][a-z0-9-]{0,30}$")
EXT_KINDS = ("tsv", "json", "text")
EXT_BLOCKS = ("table", "kv", "cards", "text", "empty", "gallery")
EXT_WORD = re.compile(r"^[a-z0-9][a-z0-9-]{0,30}$")      # a word of a live read: it becomes part of a topic name (hs:v1:ext-<name>-<words>)
LIVE_MIN, LIVE_MAX = 10, 3600
LIVE_LOCKED = ("run", "skip")
TOPIC_MAX = 100
NEEDS_MAX = 8
TOPIC_NAME = re.compile(r"^[a-z0-9][a-z0-9-]{0,99}$")


def env(name, default):
    return os.environ.get(name, default)


def runtime_setting(key):
    """A runtime setting (config/schema.toml store = "settings": one file in /var/lib/hs/settings, scripts/lib/setting.sh), or None.
    It wins over the environment hs-web was started with, which Nix fills from machine.toml (the old place), so a change needs no restart."""
    d = env("HS_SETTINGS_DIR", os.path.join(env("HS_STATE_DIR", "/var/lib/hs"), "settings"))
    try:
        with open(os.path.join(d, key), encoding="utf-8") as f:
            return f.readline().strip()
    except OSError:
        return None


def capabilities():
    """The capabilities that are on, by the rules of scripts/lib/capability.sh: named in /etc/hs/capabilities (Nix), or implied by a
    runtime setting (scripts/lib/capabilities.tsv, made from capabilities/*/capability.toml). The environment Nix fills from an old
    machine.toml still counts for vpsHost and proxyStatusUrl until `hs config migrate-settings` has moved them."""
    legacy = {"vpsHost": "HS_WEB_VPS_HOST", "proxyStatusUrl": "HS_WEB_PROXY_URL"}
    on = set()
    state = env("HS_STATE_DIR", "/var/lib/hs")
    try:
        with open(env("HS_CAPABILITIES_FILE", "/etc/hs/capabilities"), encoding="utf-8") as f:
            on = {line.strip() for line in f if line.strip()}
    except OSError:
        pass
    try:           # `hs ext enable <package>` for a package without a Nix module: on at once (scripts/lib/capability.sh)
        with open(os.path.join(state, "capabilities-on"), encoding="utf-8") as f:
            on |= {line.strip() for line in f if line.strip()}
    except OSError:
        pass
    tsv = env("HS_CAPABILITIES_TSV", os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib", "capabilities.tsv"))
    try:
        with open(tsv, encoding="utf-8") as f:
            for line in f:
                if line.startswith("#") or not line.strip():
                    continue
                cols = line.rstrip("\n").split("\t")
                for key in (cols[1].split(",") if len(cols) > 1 else []):
                    v = runtime_setting(key)
                    if v is None and key in legacy:
                        v = env(legacy[key], "")
                    if (v or "") not in ("", "false", "0"):
                        on.add(cols[0])
    except OSError:
        pass
    try:           # `hs ext disable <package>` wins over everything above
        with open(os.path.join(state, "capabilities-off"), encoding="utf-8") as f:
            on -= {line.strip() for line in f if line.strip()}
    except OSError:
        pass
    return sorted(on)


def applied_recipes():
    """the packages hs recipe has applied on this server (installed.toml, written by scripts/pkg.py record): a recipe package is on from then on"""
    import tomllib
    try:
        with open(os.path.join(env("HS_STATE_DIR", "/var/lib/hs"), "packages", "installed.toml"), "rb") as f:
            return set(tomllib.load(f).get("package", {}))
    except (OSError, tomllib.TOMLDecodeError):
        return set()


def ext_roots():
    """The folders that hold packages (the same order as scripts/lib/registry-load.sh): HS_PACKAGES_DIR alone, or the checkout beside scripts/ and
    /etc/nixos (the scripts run from a copy in the Nix store that has no capabilities/). A pinned-commit location is added here later."""
    if env("HS_PACKAGES_DIR", ""):
        return [env("HS_PACKAGES_DIR", "")]
    here = os.path.dirname(os.path.abspath(__file__))
    base = os.path.dirname(here)
    cur = os.path.join(env("HS_STATE_DIR", "/var/lib/hs"), "packages", "current")      # installed from a repository (scripts/pkg_repo.py)
    return [r for r in (os.path.join(base, "capabilities"), "/etc/nixos/capabilities", os.path.join(base, "packages"), "/etc/nixos/packages", cur) if os.path.isdir(r)]


def ext_sys_rows(path):
    """the sys rows of a package's commands.tsv as word tuples with <x> for every value: ('ext', 'games', 'plan', '<x>', '<x>')"""
    rows = set()
    with open(path, encoding="utf-8") as f:
        for line in f:
            c = line.rstrip("\r\n").split("\t")
            if line.startswith("#") or len(c) < 2 or c[0] != "sys":
                continue
            rows.add(tuple("<x>" if w.startswith("<") else w for w in c[1].split()[1:]))
    return rows


def ext_packages():
    """[(name, folder)] of the packages that are on, the first folder that has a package wins (sorted by name within a folder)"""
    on, done, out = set(capabilities()) | applied_recipes(), set(), []
    for root in ext_roots():
        try:
            names = sorted(os.listdir(root))
        except OSError:
            continue
        for name in names:
            if name not in on or not EXT_NAME.match(name) or name in done:
                continue
            done.add(name)
            out.append((name, os.path.join(root, name)))
    return out


def ext_manifest(d):
    """the parsed capability.toml of a package folder (a recipe package: package.toml); OSError / TOMLDecodeError when it is missing or wrong"""
    import tomllib
    manifest = os.path.join(d, "capability.toml")
    if not os.path.isfile(manifest):
        manifest = os.path.join(d, "package.toml")
    with open(manifest, "rb") as f:
        return tomllib.load(f)


def _pattern(p):
    if not isinstance(p, str) or not 1 <= len(p) <= 400:
        raise ValueError("bad pattern")
    re.compile(p)
    return p


def core_topics():
    """the topic names of the core table (column 1 of live-topics.tsv); not live_state.topics, which calls into this module"""
    path = env("HS_LIVE_TOPICS", os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib", "live-topics.tsv"))
    try:
        with open(path, encoding="utf-8") as f:
            return {line.split("\t")[0] for line in f if line.strip() and not line.lstrip().startswith("#")}
    except OSError:
        return set()


def ext_read(name, rd, rows, caps=None):
    """Validate one [[web.reads]] entry of the package `name` against the sys rows of its commands.tsv -> (words, spec). Raises ValueError/KeyError/TypeError.
    `live = <seconds>` (10..3600, only without args) opts the read in to a live-state topic ext-<name>-<words joined by '-'; `locked = "run"|"skip"` (default skip).
    `needs = [<core topic>, ...]` (1..8, only with live): a new gen of one of them re-reads this topic in a wave (scripts/live-collect.py); ext_declarations
    switches the live topic off when a name is not a core topic."""
    words = tuple(["ext", name] + str(rd["words"]).split())
    args = [_pattern(a) for a in rd.get("args", [])]
    if rd["kind"] not in EXT_KINDS or not isinstance(rd["ttl"], int) or not 0 <= rd["ttl"] <= 3600 or len(words) < 3:
        raise ValueError("bad read")
    if words + tuple("<x>" for _ in args) not in rows or set(words) & {"plan", "start", "stop", "delete", "purge"}:
        raise ValueError("a read is not a sys row of the package, or changes something")
    spec = {"kind": rd["kind"], "ttl": rd["ttl"]}
    if args:
        spec["args"] = args
    locked = rd.get("locked", "skip")
    if locked not in LIVE_LOCKED:
        raise ValueError("locked must be run or skip")
    if "live" in rd:
        live = rd["live"]
        if args:
            raise ValueError("a read with args cannot have a live topic")
        if isinstance(live, bool) or not isinstance(live, int) or not LIVE_MIN <= live <= LIVE_MAX:
            raise ValueError("live must be %d..%d seconds" % (LIVE_MIN, LIVE_MAX))
        if not all(EXT_WORD.match(w) for w in words[2:]):
            raise ValueError("the words of a live read may only be a-z, 0-9 and -")
        topic = "ext-%s-%s" % (name, "-".join(words[2:]))
        if len(topic) > TOPIC_MAX:
            raise ValueError("the topic name is too long")
        # the capability that must be on (a recipe package has none: it is on once applied; the rescan drops it when it goes)
        caps = capabilities() if caps is None else caps
        spec.update({"topic": topic, "live": live, "locked": locked, "cap": name if name in caps else None})
    if "needs" in rd:
        needs = rd["needs"]
        if "live" not in rd:
            raise ValueError("needs only with live")
        if (not isinstance(needs, list) or not 1 <= len(needs) <= NEEDS_MAX
                or not all(isinstance(n, str) and TOPIC_NAME.match(n) for n in needs)):
            raise ValueError("needs must be a list of up to 8 topic names")
        spec["needs"] = sorted(set(needs))
    return words, spec


def _ext_page(name, page, words):
    """The [web.page] declaration of a package for the generic page of the frontend (web/src/shell/GenericPage.svelte): plain data, checked here so
    that it names only reads the package declared and changes of its own area. Raises ValueError. -> the declaration as it goes out."""
    if not isinstance(page, dict) or len(json.dumps(page)) > 30000:
        raise ValueError("bad page")
    known = {" ".join(w[2:]) for w in words}

    def walk(node):
        if isinstance(node, dict):
            r = node.get("read")
            if r is not None and r not in known:
                raise ValueError("the page reads %r, which is not a declared read" % r)
            for j in node.get("joins", []):
                if j.get("read") not in known:
                    raise ValueError("a join reads something that is not a declared read")
            if node.get("type") is not None and node["type"] not in EXT_BLOCKS:
                raise ValueError("unknown block type")
            for key in ("actions", "rowActions"):
                for a in node.get(key, []):
                    if "plan" in a and (not isinstance(a["plan"], list) or not a["plan"] or a["plan"][0] != "ext/" + name):
                        raise ValueError("a page action may only plan changes of its own area")
                    if "input" in a:    # a text field before the plan: {input} in the plan arguments; the server still checks every argument against the changes
                        i = a["input"]
                        if (not isinstance(i, dict) or not isinstance(i.get("label"), str) or not 1 <= len(i["label"]) <= 80
                                or not any("{input}" in str(x) for x in a.get("plan", [])[1:])):
                            raise ValueError("an input action needs a label and {input} in its plan arguments")
                        if "pattern" in i:
                            _pattern(i["pattern"])
            for c in node.get("columns", []):
                pl = c.get("plan")
                if pl is not None and (not isinstance(pl, list) or not pl or pl[0] != "ext/" + name):
                    raise ValueError("a switch may only plan changes of its own area")
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)
    walk(page)
    return {"name": name, **page}


def ext_declarations(log=None):
    """-> [(name, reads, changes, page)] of the packages that are on, with the WHOLE declaration checked (reads, changes and page): a package with
    anything wrong adds nothing (the reason goes to `log(text)`), and a live topic name that an earlier package already has drops the later package.
    The one rule for the web interface (ext_load_web) and the live-state collector (ext_live_rows), so they always agree on what is registered."""
    import tomllib
    out, taken, caps, core = [], set(), capabilities(), core_topics()
    for name, d in ext_packages():
        try:
            web = ext_manifest(d).get("web", {})
            if not web:
                continue        # a capability without a [web] declaration (most of them) has nothing to register and no commands.tsv
            rows = ext_sys_rows(os.path.join(d, "commands.tsv"))
            r_new, c_new, p_new = {}, [], None
            for rd in web.get("reads", []):
                words, spec = ext_read(name, rd, rows, caps)
                t = spec.get("topic")
                if t and (t in taken or any(v.get("topic") == t for v in r_new.values())):
                    raise ValueError("a live topic name is used twice")
                r_new[words] = spec
            for spec in r_new.values():
                missing = [t for t in spec.get("needs", ()) if t not in core]
                if missing:      # the read stays a plain direct read; the same rule for the web interface and the collector
                    if log:
                        log("extension %s: live topic %s off (needs unknown topic %s)" % (name, spec["topic"], ", ".join(missing)))
                    for k in ("topic", "live", "locked", "cap", "needs"):
                        spec.pop(k, None)
            for ch in web.get("changes", []):
                if "patterns" in ch:
                    c_new.append([_pattern(p) for p in ch["patterns"]])
                else:
                    ent = {"fixed": [_pattern(p) for p in ch["fixed"]],
                           "opts": {o["flag"]: (_pattern(o["pattern"]) if o.get("pattern") is not None else None, bool(o.get("repeats", False)))
                                    for o in ch.get("opts", [])}}
                    if ch.get("stdin"):
                        ent["stdin"] = True
                    for flag in ent["opts"]:
                        if not re.fullmatch(r"--[a-z][a-z0-9-]{0,30}", flag):
                            raise ValueError("bad flag")
                    c_new.append(ent)
            if "page" in web:
                p_new = _ext_page(name, web["page"], list(r_new))
            heads = {w[:3] for w in rows}
            if c_new and not (("ext", name, "plan") in heads and ("ext", name, "start") in heads):
                raise ValueError("changes need the plan and start rows of the package")
        except (OSError, KeyError, TypeError, ValueError, re.error, tomllib.TOMLDecodeError) as e:
            if log:
                log("extension %s: web declaration ignored (%s)" % (name, e))
            continue
        taken |= {v["topic"] for v in r_new.values() if v.get("topic")}
        out.append((name, r_new, c_new, p_new))
    return out


def ext_load_web():
    """-> (reads, changes, pages) declared by the manifests of the packages that are on (web-serve.py registers them)"""
    reads, changes, pages = {}, {}, []
    for name, r_new, c_new, p_new in ext_declarations(lambda m: print(m, flush=True)):
        reads.update(r_new)
        if p_new:
            pages.append(p_new)
        if c_new:
            changes["ext/" + name] = c_new
    return reads, changes, pages


def ext_live_rows(log=None):
    """-> (rows, info) of the live reads of the packages whose whole declaration is good: rows are (topic, words list, seconds, lock mode) like
    live_state.topics(), info is {topic: {"cap": name|None, "groups": {"ext-<name>"}}}."""
    rows, info = [], {}
    for name, r_new, _, _ in ext_declarations(log):
        for words, spec in r_new.items():
            if "topic" in spec:
                rows.append((spec["topic"], list(words), spec["live"], spec["locked"]))
                info[spec["topic"]] = {"cap": spec["cap"], "groups": {"ext-" + name}}
                if spec.get("needs"):
                    info[spec["topic"]]["needs"] = tuple(spec["needs"])
    return rows, info
