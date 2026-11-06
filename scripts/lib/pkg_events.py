"""The events a package declares in package.toml [[events]] (hobnix/server#313). Python stdlib only, no CLI.

`hs pkg` installs the declaration of a package as <installed_dir>/<package>.tsv; the level lookup (state-db.py), the notification rules and
the spool allowlist (event-notify.py) and the catalogue read it. The core keeps a transition copy of the media helper's events in
scripts/lib/pkg-events/ (same format) until hobnix/recipes declares them; an installed file replaces the copy of the same package completely.

Format: UTF-8 text, tab-separated, exactly 10 columns, "-" = empty. Lines starting with # and blank lines are skipped.
  kind  level  payload keys  label  icon  meaning  category  priority  title  message
The file name stem is the package name. A row whose kind does not start with pkg.<stem>., whose suffix or level is invalid, or which
has not 10 columns is dropped quietly. Without notify the last four columns are "-" (no rule).

Knobs: HS_PKG_EVENTS_DIR (the installed directory), HS_STATE_DIR (default /var/lib/hs; the directory is <state>/pkg-events).
"""
import glob
import os
import re

COLUMNS = ("kind", "level", "payload", "label", "icon", "meaning", "category", "priority", "title", "message")
LEVELS = ("info", "warn", "error")
CATEGORIES = ("alarm", "lock", "problem", "ok", "start", "stop", "info")
PRIORITIES = ("min", "low", "default", "high", "urgent")
SUFFIX = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
PAYLOAD_KEY = re.compile(r"^[a-z][a-z0-9_]{0,31}\??$")
ICON = re.compile(r"^[a-z0-9-]{1,40}$")
PACKAGE = re.compile(r"^[a-z][a-z0-9-]{0,40}$")
EVENT_KEYS = {"kind", "level", "label", "icon", "meaning", "payload", "notify"}
NOTIFY_KEYS = {"category", "priority", "title", "message"}
CORE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pkg-events")


def installed_dir():
    d = os.environ.get("HS_PKG_EVENTS_DIR")
    if d:
        return d
    return os.path.join(os.environ.get("HS_STATE_DIR") or "/var/lib/hs", "pkg-events")


def _line(s, limit):
    """A text that is one short line: no tab or line break, not "-"."""
    return (isinstance(s, str) and 1 <= len(s) <= limit and s != "-"
            and not any(c in s for c in "\t\n\r"))


def manifest_problems(package, events):
    if not isinstance(events, list) or not all(isinstance(e, dict) for e in events):
        return ["events must be [[events]] tables"]
    out = []
    seen = set()
    for e in events:
        k = e.get("kind")
        if not isinstance(k, str) or not SUFFIX.match(k):
            out.append("events: kind %r is not a lower-case word (write the part after pkg.%s. only)" % (k, package))
            continue
        if k in seen:
            out.append("events: %s is declared twice" % k)
            continue
        seen.add(k)
        if e.get("level") not in LEVELS:
            out.append("events: %s: level is not info, warn or error" % k)
        if not _line(e.get("label"), 60):
            out.append("events: %s: label missing or not one short line" % k)
        if "icon" in e and not (isinstance(e["icon"], str) and ICON.match(e["icon"])):
            out.append("events: %s: icon is not an icon name" % k)
        if not _line(e.get("meaning"), 200):
            out.append("events: %s: meaning missing or not one line" % k)
        pl = e.get("payload", [])
        if not isinstance(pl, list):
            out.append("events: %s: payload is a list of keys" % k)
            pl = []
        pseen = set()
        for x in pl:
            if not isinstance(x, str) or not PAYLOAD_KEY.match(x):
                out.append("events: %s: payload key %r is not a lower-case word" % (k, x))
            elif x in pseen:
                out.append("events: %s: payload key %s listed twice" % (k, x))
            else:
                pseen.add(x)
        for x in sorted(set(e) - EVENT_KEYS):
            out.append("events: %s: unknown key %s" % (k, x))
        if "notify" in e:
            n = e["notify"]
            if not isinstance(n, dict):
                out.append("events: %s: notify needs a title and a message (one line each)" % k)
                continue
            if n.get("category") not in CATEGORIES:
                out.append("events: %s: notify category is not one of %s" % (k, " ".join(CATEGORIES)))
            if "priority" in n and n["priority"] not in PRIORITIES:
                out.append("events: %s: notify priority is not one of %s" % (k, " ".join(PRIORITIES)))
            if not (_line(n.get("title"), 300) and _line(n.get("message"), 300)):
                out.append("events: %s: notify needs a title and a message (one line each)" % k)
            for x in sorted(set(n) - NOTIFY_KEYS):
                out.append("events: %s: notify: unknown key %s" % (k, x))
    return out


def rows(package, events):
    out = []
    for e in events:
        n = e.get("notify")
        out.append(["pkg.%s.%s" % (package, e["kind"]), e["level"], ",".join(e.get("payload") or []) or "-",
                    e["label"], e.get("icon") or "-", e["meaning"],
                    n["category"] if n else "-", (n.get("priority") or "-") if n else "-",
                    n["title"] if n else "-", n["message"] if n else "-"])
    return out


def tsv_text(package, events):
    head = ("# Events of the package %s (written by hs pkg from its package.toml [[events]]; never edit by hand). scripts/lib/pkg_events.py\n"
            "# kind\tlevel\tpayload keys\tlabel\ticon\tmeaning\tcategory\tpriority\ttitle\tmessage\n" % package)
    return head + "".join("\t".join(r) + "\n" for r in rows(package, events))


def write(package, events):
    if not events:
        remove(package)
        return
    d = installed_dir()
    os.makedirs(d, 0o755, exist_ok=True)
    p = os.path.join(d, package + ".tsv")
    with open(p + ".new", "w", encoding="utf-8", newline="\n") as f:
        f.write(tsv_text(package, events))
    os.chmod(p + ".new", 0o644)
    os.replace(p + ".new", p)


def remove(package):
    try:
        os.unlink(os.path.join(installed_dir(), package + ".tsv"))
    except FileNotFoundError:
        pass


def read_file(path, package):
    prefix = "pkg.%s." % package
    out = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\n")
                if not line or line.startswith("#"):
                    continue
                c = line.split("\t")
                if len(c) != len(COLUMNS):
                    continue
                r = dict(zip(COLUMNS, c))
                if not r["kind"].startswith(prefix) or not SUFFIX.match(r["kind"][len(prefix):]) or r["level"] not in LEVELS:
                    continue
                out.append(r)
    except OSError:
        return []
    return out


def declarations():
    out = {}
    for d in (CORE_DIR, installed_dir()):
        got = {}
        for p in sorted(glob.glob(os.path.join(d, "*.tsv"))):
            name = os.path.basename(p)[:-4]
            if PACKAGE.match(name):
                got[name] = read_file(p, name)
        out.update(got)
    return out


def find(kind):
    m = re.match(r"^pkg\.([a-z][a-z0-9-]{0,40})\.([a-z0-9][a-z0-9-]{0,39})$", kind or "")
    if not m:
        return None
    p = os.path.join(installed_dir(), m.group(1) + ".tsv")
    if not os.path.exists(p):
        p = os.path.join(CORE_DIR, m.group(1) + ".tsv")
    for r in read_file(p, m.group(1)):
        if r["kind"] == kind:
            return r
    return None
