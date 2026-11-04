#!/usr/bin/env python3
"""The subscriber that turns events into push messages (docs/adr/0005-events.md; run by scripts/event-notify.sh, python3 stdlib only).

  event-notify.py run [--spool DIR]...    take the events the media helpers left in the spool folders into the event log, then
                                          call `hs notify` for every row after the cursor that a rule asks for
  event-notify.py match <kind>            the rule a kind would get (for tests and `docs/notify-rules.md`)

The publisher (a script, a helper in a container) only writes events; this file only reads them and matches rules. Neither knows the other.
Rules are rows of scripts/lib/notify-rules.tsv and of the *.tsv files in the drop-in folder (they come first): kind glob, category,
priority, title template, message template; the first row that matches a kind wins; category `-` = matched and silent.

Cursor ($HS_STATE_DIR/event-notify.cursor): the id of the last row that was dealt with. It is written after EVERY row, once its notify call
returned, so a crash between the call and the write repeats at most that one message (at-least-once, never a hole). A notify call
that fails (exit not 0, timeout) is logged to stderr and the row is dealt with anyway: retrying would repeat messages and let one bad
row hold up all the others, and a channel that could not be reached is already a notify.failed row. The first run (no cursor file)
starts at the newest row: history is never replayed. Rows of the source `notify` are never read as triggers (no loop).

Test knobs: HS_STATE_DIR, HS_STATE_DB, HS_NOTIFY_CMD (default: bash <scripts>/notify.sh), HS_NOTIFY_RULES (core file), HS_NOTIFY_RULES_DIR,
HS_PYTHON.
"""
import fnmatch
import json
import os
import re
import shlex
import stat
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PY = os.environ.get("HS_PYTHON") or sys.executable or "python3"
STATE_DB = os.path.join(HERE, "state-db.py")
BATCH = 500            # rows read per run; a longer backlog is taken in the next run
MAX_SPOOL = 200        # spool files taken per run and folder
MAX_FILE = 8192        # bytes of one spool file
CATEGORIES = {"alarm", "lock", "problem", "ok", "start", "stop", "info"}
PRIORITIES = {"min", "low", "default", "high", "urgent"}
SPOOL_KIND = re.compile(r"^pkg\.([a-z0-9]+)\.[a-z0-9][a-z0-9-]{0,39}$")   # the shape of the only kinds a container may write
SPOOL_NAME = re.compile(r"^ev-[0-9]+-[0-9]+\.json$")
SUBJECT = re.compile(r"^[A-Za-z0-9._-]{1,64}$")


def warn(msg):
    sys.stderr.write("hs-event-notify: %s\n" % msg)


def state_dir():
    return os.environ.get("HS_STATE_DIR") or "/var/lib/hs"


def db(*args, data=None):
    return subprocess.run([PY, STATE_DB, *args], capture_output=True, text=True, timeout=60)


# ── rules ──
def rule_files():
    d = os.environ.get("HS_NOTIFY_RULES_DIR") or os.path.join(state_dir(), "notify-rules.d")
    files = []
    if os.path.isdir(d):
        files = [os.path.join(d, f) for f in sorted(os.listdir(d)) if f.endswith(".tsv")]
    return files + [os.environ.get("HS_NOTIFY_RULES") or os.path.join(HERE, "lib", "notify-rules.tsv")]


def load_rules():
    rules = []
    for path in rule_files():
        try:
            with open(path, encoding="utf-8") as f:
                lines = f.read().splitlines()
        except OSError:
            continue
        for n, line in enumerate(lines, 1):
            if not line.strip() or line.startswith("#"):
                continue
            c = line.split("\t")
            if len(c) < 5 or c[1] != "-" and c[1] not in CATEGORIES or c[2] != "-" and c[2] not in PRIORITIES:
                warn("%s:%d: not a rule (kind, category, priority, title, message), skipped" % (path, n))
                continue
            rules.append(c[:5])
    return rules


def find_rule(rules, kind):
    if kind.startswith("notify."):
        return None
    for r in rules:
        if fnmatch.fnmatchcase(kind, r[0]):
            return r
    return None


def render(tpl, values):
    return re.sub(r"\{([a-z0-9_]+)\}", lambda m: str(values.get(m.group(1), "")), tpl).replace("\\n", "\n")


# ── the event log ──
def read_rows(after):
    r = db("event-list", str(BATCH), "--after", str(after))
    rows = []
    if r.returncode != 0:
        return rows
    for line in r.stdout.splitlines():
        c = line.split("\t")
        if len(c) < 8 or not c[0].isdigit():
            continue
        payload = {}
        if c[7] != "-":
            try:
                payload = json.loads(c[7])
            except ValueError:
                payload = {}
        rows.append({"id": int(c[0]), "source": c[2], "kind": "%s.%s" % (c[2], c[3]), "subject": "" if c[4] == "-" else c[4],
                     "level": c[5], "text": "" if c[6] == "-" else c[6], "payload": payload if isinstance(payload, dict) else {}})
    return sorted(rows, key=lambda x: x["id"])


def newest_id():
    r = db("event-list", "1")
    if r.returncode != 0:
        return None       # unreadable is not empty: never move the cursor on a guess
    for line in r.stdout.splitlines():
        if line.split("\t")[0].isdigit():
            return int(line.split("\t")[0])
    return 0


def cursor_path():
    return os.path.join(state_dir(), "event-notify.cursor")


def read_cursor():
    try:
        with open(cursor_path()) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return None


def write_cursor(n):
    p = cursor_path()
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p + ".new", "w") as f:
        f.write("%d\n" % n)
    os.replace(p + ".new", p)


# ── the spool: events that a container left in a shared folder ──
def spool_packages():
    """The packages whose events a container may leave in the spool: the ones the core rules file has rules for (pkg.<package>.*).
    The server controls that file; a container cannot add a name, so it cannot write pkg.someother.x."""
    names = set()
    try:
        with open(os.environ.get("HS_NOTIFY_RULES") or os.path.join(HERE, "lib", "notify-rules.tsv"), encoding="utf-8") as f:
            for line in f:
                m = re.match(r"pkg\.([a-z0-9]+)\.", line)
                if m:
                    names.add(m.group(1))
    except OSError:
        pass
    return names


def clean_row(raw):
    """(kind, subject, text, payload) of a spool file, or None. A container is not trusted: only pkg.<package>. kinds of a package that the server lists (spool_packages), short flat values."""
    if not isinstance(raw, dict):
        return None
    kind, subject, text, payload = raw.get("kind"), raw.get("subject") or "", str(raw.get("text") or ""), raw.get("payload") or {}
    m = SPOOL_KIND.match(kind) if isinstance(kind, str) else None
    if not m or m.group(1) not in spool_packages() or not SUBJECT.match(str(subject)) or not isinstance(payload, dict):
        return None
    clean = {}
    for k, v in list(payload.items())[:20]:
        if not re.fullmatch(r"[a-z][a-z0-9_]{0,31}", str(k)) or isinstance(v, (dict, list)) or v is None:
            continue
        v = v if isinstance(v, (bool, int, float)) else str(v)[:600]
        if k == "poster_url" and not (isinstance(v, str) and re.match(r"https?://[^\s]+$", v)):
            continue
        clean[k] = v
    return kind, str(subject), text[:200], clean


def ingest(folder):
    """Move the events of one spool folder into the event log. Returns how many. A file that is not an ordinary small file of the
    right name is skipped (a link could point root at any file); one that is not an event is removed; one that could not be
    written stays for the next run."""
    try:
        st = os.lstat(folder)
    except OSError:
        return 0
    if not stat.S_ISDIR(st.st_mode):
        return 0
    n = 0
    now = time.time()
    names = sorted(os.listdir(folder))
    for name in names[:MAX_SPOOL * 2]:
        path = os.path.join(folder, name)
        try:
            s = os.lstat(path)
            if not stat.S_ISREG(s.st_mode):
                continue
            if name.startswith(".tmp-"):
                if now - s.st_mtime > 3600:
                    os.unlink(path)
                continue
            if not SPOOL_NAME.match(name):
                continue
            if n >= MAX_SPOOL:
                break
            row = None
            if s.st_size <= MAX_FILE:
                fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
                with os.fdopen(fd, "rb") as f:
                    try:
                        row = clean_row(json.loads(f.read(MAX_FILE + 1).decode("utf-8")))
                    except (ValueError, UnicodeDecodeError):
                        row = None
            if row is None:
                warn("%s: not an event, removed" % path)
                os.unlink(path)
                continue
            kind, subject, text, payload = row
            args = ["emit", kind, subject, text]
            if payload:
                args += ["--payload", json.dumps(payload)]
            if db(*args).returncode != 0:
                warn("%s: could not be written to the event log, kept" % path)
                continue
            os.unlink(path)
            n += 1
        except OSError as e:
            warn("%s: %s" % (path, e))
    return n


# ── run ──
def notify(row, rule):
    _, category, priority, title_tpl, msg_tpl = rule
    values = dict(row["payload"], kind=row["kind"], subject=row["subject"], level=row["level"], text=row["text"])
    cmd = shlex.split(os.environ.get("HS_NOTIFY_CMD") or "bash %s" % shlex.quote(os.path.join(HERE, "notify.sh")))
    cmd += ["--category", category]
    pfile = None
    if row["payload"]:
        pfile = os.path.join(state_dir(), ".event-notify-payload-%d.json" % os.getpid())
        with open(pfile, "w") as f:
            json.dump(row["payload"], f)
        cmd += ["--payload-file", pfile]
    cmd += [render(title_tpl, values), render(msg_tpl, values)]
    if priority != "-":
        cmd.append(priority)
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
        if r.returncode != 0:
            warn("%s (id %d): hs notify exited %d: %s" % (row["kind"], row["id"], r.returncode, (r.stderr or r.stdout).strip()[:200]))
            return False
        return True
    except (OSError, subprocess.SubprocessError) as e:
        warn("%s (id %d): %s" % (row["kind"], row["id"], e))
        return False
    finally:
        if pfile:
            try:
                os.unlink(pfile)
            except OSError:
                pass


def run(spools):
    os.makedirs(state_dir(), exist_ok=True)
    lock = None
    try:
        import fcntl
        lock = open(os.path.join(state_dir(), "event-notify.lock"), "w")
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except ImportError:
        pass
    except OSError:
        return 0       # the run before is still busy
    cursor = read_cursor()
    if cursor is None:
        # the first run starts at the newest row (before the spool is taken in: what the helpers left until now is news)
        cursor = newest_id()
        if cursor is None:
            warn("the event log cannot be read")
            return 0
        write_cursor(cursor)
    for folder in spools:
        try:
            ingest(folder)
        except OSError as e:
            warn("%s: %s" % (folder, e))
    newest = newest_id()
    if newest is None:
        warn("the event log cannot be read")
        return 0
    if cursor > newest:
        cursor = newest      # the log was started again: do not wait for ids that will never come
        write_cursor(cursor)
    rules = load_rules()
    for row in read_rows(cursor):
        rule = find_rule(rules, row["kind"])
        if rule and rule[1] != "-":
            notify(row, rule)
        write_cursor(row["id"])
    return 0


def main(argv):
    if len(argv) >= 2 and argv[1] == "run":
        spools = [argv[i + 1] for i, a in enumerate(argv) if a == "--spool" and i + 1 < len(argv)]
        return run(spools)
    if len(argv) == 3 and argv[1] == "match":
        r = find_rule(load_rules(), argv[2])
        print("\t".join(r) if r else "-")
        return 0 if r else 1
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
