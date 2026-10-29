#!/usr/bin/env python3
"""The state database: /var/lib/hs/state.db, SQLite, WAL.

ONE writer (this program, started as root by scripts/state.sh), any number of read-only readers.
Reads open the file with mode=ro and query_only. A value that cannot be read is NULL / "unknown", never a stale number.

Commands (machine readable output; scripts/state.sh makes the pretty version for people):
  collect [--event]          read the disks (monitor.sh --disks + lsblk) and update disks / events / smart
  disks                      inventory, tab separated: serial model size dev state role pool first_seen last_seen worse note
  events [N]                 time kind subject text (newest last)
  smart <serial|dev>         the stored SMART readings of one disk
  problems                   key TAB text for health-check.sh (missing disks, worsening disks, a collector that stopped)
  deck-disks                 the 5 fields per disk the status document uses (name bytes kind role temp), from the last reading
  inventory-json             {"known":N,"missing":[...],"worse":[...]} for the status document
  forget <serial|dev> [--yes]  remove a MISSING disk from the list for good
  read-put <key> [--ms N] [--rc N]  keep the output of a read (stdin) for the web interface: scripts/reads-collect.sh, the one writer of the table `reads`
  usage-record <key> <used> <size>  one reading of a pool / filesystem fill level (bytes; backup: percent and 100), at most one per hour and key
  usage <key> [days]         the readings of the last N days (default 60): time TAB used TAB size, oldest first (scripts/forecast.py reads them)
  read-get <key>             the kept output (nothing and exit 1 when there is none)
  reads                      key TAB age in seconds TAB milliseconds the read took TAB exit code TAB bytes, oldest first
  baseline-run               the daily SMART check: read every disk through disk-health.sh --readings, compare with the stored reading,
                             update the table baseline (docs/PLAN-disk-health.md)
  baseline                   machine line per disk: serial dev kind level since last_read first_read wwn realloc pending uncorr crc
                             nv_crit nv_media nv_used nv_spare present note
Environment (tests): HS_STATE_DB, HS_STATE_DIR, HS_MONITOR (command), HS_LSBLK, HS_LOCKED_MARKER, HS_NOW,
HS_STATE_SMART_EVERY (seconds, default 900), HS_STATE_WORSE_DAYS (default 14), HS_DISK_HEALTH (the reading command),
HS_SMART_FAIL_REALLOC (10), HS_SMART_FAIL_MEDIA (10), HS_SMART_WEAR_JUMP (3), HS_SMART_HOLD_DAYS (7), HS_SMART_WAKE_DAYS (6),
HS_SMART_STALE (seconds, default 2*86400+3600).
"""
import json
import os
import re
import sqlite3
import subprocess
import sys
import time

STATE_DIR = os.environ.get("HS_STATE_DIR", "/var/lib/hs")
DB = os.environ.get("HS_STATE_DB", os.path.join(STATE_DIR, "state.db"))
HERE = os.path.dirname(os.path.abspath(__file__))
SMART_EVERY = int(os.environ.get("HS_STATE_SMART_EVERY", "900"))
WORSE_DAYS = int(os.environ.get("HS_STATE_WORSE_DAYS", "14"))
STALE_S = int(os.environ.get("HS_STATE_STALE", "1800"))
KEEP_EVENTS = 2000
SMART_KEEP_DAYS = 400
SMART_THIN_DAYS = 30
# the daily SMART check (baseline): thresholds in one place
FAIL_REALLOC = int(os.environ.get("HS_SMART_FAIL_REALLOC", "10"))
FAIL_MEDIA = int(os.environ.get("HS_SMART_FAIL_MEDIA", "10"))
WEAR_JUMP = int(os.environ.get("HS_SMART_WEAR_JUMP", "3"))
HOLD_DAYS = int(os.environ.get("HS_SMART_HOLD_DAYS", "7"))
WAKE_DAYS = int(os.environ.get("HS_SMART_WAKE_DAYS", "6"))
BASELINE_STALE_S = int(os.environ.get("HS_SMART_STALE", str(2 * 86400 + 3600)))


def now():
    return int(os.environ.get("HS_NOW") or time.time())


SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS disks (
  serial TEXT PRIMARY KEY, model TEXT, size INTEGER, dev TEXT,
  first_seen INTEGER, last_seen INTEGER, role TEXT, pool TEXT,
  state TEXT NOT NULL DEFAULT 'ok', note TEXT, worse INTEGER NOT NULL DEFAULT 0,
  temp INTEGER, kind TEXT);
CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY AUTOINCREMENT, time INTEGER NOT NULL, kind TEXT NOT NULL, subject TEXT, text TEXT);
CREATE TABLE IF NOT EXISTS smart (
  time INTEGER NOT NULL, serial TEXT NOT NULL, realloc INTEGER, pending INTEGER, crc INTEGER, temp INTEGER, hours INTEGER);
CREATE INDEX IF NOT EXISTS smart_serial ON smart (serial, time);
-- the daily SMART check: the last reading per disk (key: serial) and the level it earned from what changed since the reading before
CREATE TABLE IF NOT EXISTS baseline (serial TEXT PRIMARY KEY, wwn TEXT, dev TEXT, kind TEXT, first_read INTEGER, last_read INTEGER, last_try INTEGER, hours INTEGER, realloc INTEGER, pending INTEGER, uncorr INTEGER, crc INTEGER, nv_crit INTEGER, nv_media INTEGER, nv_used INTEGER, nv_spare INTEGER, nv_spare_thr INTEGER, level TEXT NOT NULL DEFAULT 'healthy', level_time INTEGER, note TEXT);
CREATE TABLE IF NOT EXISTS samples (
  time INTEGER NOT NULL, cpu INTEGER, mem INTEGER, gpu INTEGER, rx INTEGER, tx INTEGER, boot INTEGER NOT NULL DEFAULT 0);
-- the output of the slow `hs sys ...` reads, written by the collector (scripts/reads-collect.sh) and served by the web interface instead of running the script
CREATE TABLE IF NOT EXISTS reads (
  key TEXT PRIMARY KEY, payload TEXT NOT NULL, updated INTEGER NOT NULL, ms INTEGER, rc INTEGER NOT NULL DEFAULT 0);
-- fill levels for the capacity forecast (scripts/forecast.py, health-check.sh): one reading per hour and key
CREATE TABLE IF NOT EXISTS usage (
  time INTEGER NOT NULL, key TEXT NOT NULL, used INTEGER NOT NULL, size INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS usage_key ON usage (key, time);
CREATE TABLE IF NOT EXISTS hours (
  hour INTEGER PRIMARY KEY, cpu REAL, mem REAL, gpu REAL, rx REAL, tx REAL, up REAL, boot INTEGER NOT NULL DEFAULT 0);
"""


def open_rw():
    os.makedirs(os.path.dirname(DB) or ".", exist_ok=True)
    c = sqlite3.connect(DB, timeout=30)
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("PRAGMA synchronous=NORMAL")
    c.executescript(SCHEMA)
    c.execute("PRAGMA user_version=1")
    return c


def open_ro():
    """Read-only; None when the database does not exist yet (the readers then answer with nothing, never with an error)."""
    if not os.path.exists(DB):
        return None
    try:
        c = sqlite3.connect("file:%s?mode=ro" % DB.replace("\\", "/"), uri=True, timeout=10)
        c.execute("PRAGMA query_only=1")
        c.execute("SELECT 1 FROM disks LIMIT 1")
        return c
    except sqlite3.Error:
        return None


BASH = os.environ.get("HS_TEST_BASH", "bash")


def run(cmd, timeout=60):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
        return r.stdout if r.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def num(s):
    s = (s or "").strip()
    return int(s) if re.fullmatch(r"\d+", s) else None


def unescape(s):
    return re.sub(r"\\x([0-9a-fA-F]{2})", lambda m: chr(int(m.group(1), 16)), s)


def read_monitor():
    """name -> dict from monitor.sh --disks (name bytes kind role temp health hours realloc pending crc rest free)."""
    cmd = os.environ.get("HS_MONITOR")
    out = run([BASH, cmd or os.path.join(HERE, "monitor.sh"), "--disks"], 120)
    rows = {}
    for line in out.splitlines():
        f = line.split("\t")
        if len(f) < 10 or not f[0]:
            continue
        rows[f[0]] = {"name": f[0], "bytes": num(f[1]), "kind": f[2], "role": f[3], "temp": num(f[4]), "health": f[5],
                      "hours": num(f[6]), "realloc": num(f[7]), "pending": num(f[8]), "crc": num(f[9])}
    return rows


def read_identity():
    """name -> (serial, model) from lsblk raw output (spaces are escaped as \\x20, so the columns split cleanly)."""
    lsblk = os.environ.get("HS_LSBLK")
    out = run([BASH, lsblk, "-dnr", "-o", "NAME,SERIAL,MODEL"] if lsblk else ["lsblk", "-dnr", "-o", "NAME,SERIAL,MODEL"])
    ident = {}
    for line in out.splitlines():
        p = line.split(" ", 2)
        if not p or not p[0]:
            continue
        serial = unescape(p[1]).strip() if len(p) > 1 else ""
        model = unescape(p[2]).strip() if len(p) > 2 else ""
        ident[p[0]] = (serial, model)
    return ident


def pool_of(role):
    if not role or role in ("system", "free", "mounted", "backup disk", "unknown"):
        return ""
    if role.startswith("bulk "):
        return "bulk"
    return role


def event(c, t, kind, subject, text):
    c.execute("INSERT INTO events (time, kind, subject, text) VALUES (?,?,?,?)", (t, kind, subject, text))


def label(model, serial):
    return "%s%s" % (model or "disk", (" (S/N %s)" % serial) if serial and not serial.startswith("dev:") else "")


def collect(args):
    if os.environ.get("HS_STATE_NO_COLLECT"):     # tests of other scripts that call the collector
        return 0
    t = now()
    mon = read_monitor()
    ident = read_identity()
    locked = os.path.exists(os.environ.get("HS_LOCKED_MARKER", "/run/hs/storage-locked"))
    c = open_rw()
    with c:   # one transaction: a run that fails changes nothing
        if not mon or not ident:
            # the source failed: say so, change nothing else (a disk is never missing because a tool did not answer)
            c.execute("INSERT OR REPLACE INTO meta VALUES ('collect_ok','0')")
            c.execute("INSERT OR REPLACE INTO meta VALUES ('collect_try',?)", (str(t),))
            return 0
        seed = c.execute("SELECT COUNT(*) FROM disks").fetchone()[0] == 0
        seen = set()
        last_smart = {}
        for r in c.execute("SELECT serial, MAX(time) FROM smart GROUP BY serial"):
            last_smart[r[0]] = r[1]
        base_from = t - WORSE_DAYS * 86400
        for name, d in mon.items():
            serial, model = ident.get(name, ("", ""))
            tracked = bool(serial)
            key = serial if tracked else "dev:%s" % name
            seen.add(key)
            role = d["role"]
            row = c.execute("SELECT state, role, pool, worse FROM disks WHERE serial=?", (key,)).fetchone()
            if locked:
                # pool membership is not readable while the storage is locked: keep what we knew
                role, pool = (row[1], row[2]) if row else ("unknown", "")
            else:
                pool = pool_of(role)
            state = "ok" if tracked else "unknown"
            if row is None:
                c.execute("INSERT INTO disks (serial, model, size, dev, first_seen, last_seen, role, pool, state, kind, temp)"
                          " VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                          (key, model, d["bytes"], name, t, t, role, pool, state, d["kind"], d["temp"]))
                if not seed:
                    event(c, t, "new", key, "%s plugged in or seen for the first time as %s (%s)" % (label(model, key), name, role))
            else:
                if row[0] == "missing":
                    event(c, t, "back", key, "%s is back as %s" % (label(model, key), name))
                c.execute("UPDATE disks SET model=?, size=?, dev=?, last_seen=?, role=?, pool=?, state=?, kind=?, temp=? WHERE serial=?",
                          (model, d["bytes"], name, t, role, pool, state, d["kind"], d["temp"], key))
            # SMART rows over time (at most one per SMART_EVERY seconds and disk; NULL where it was not readable)
            if t - last_smart.get(key, 0) >= SMART_EVERY or "--event" in args:
                vals = (d["realloc"], d["pending"], d["crc"], d["temp"], d["hours"])
                if any(v is not None for v in vals):
                    # the baseline comes from the older readings: the oldest one inside the window
                    base = c.execute("SELECT realloc, pending, crc FROM smart WHERE serial=? AND time>=? ORDER BY time LIMIT 1",
                                     (key, base_from)).fetchone()
                    c.execute("INSERT INTO smart VALUES (?,?,?,?,?,?,?)", (t, key) + vals)
                    last_smart[key] = t
                    worse, note = 0, ""
                    if base:
                        grown = [(n, b, v) for n, b, v in zip(("reallocated", "pending", "CRC"), base, vals[:3])
                                 if b is not None and v is not None and v > b]
                        if grown:
                            worse = 1
                            note = ", ".join("%s %d -> %d" % g for g in grown)
                    was = c.execute("SELECT worse FROM disks WHERE serial=?", (key,)).fetchone()[0]
                    c.execute("UPDATE disks SET worse=?, note=? WHERE serial=?", (worse, note, key))
                    if worse and not was:
                        event(c, t, "worse", key, "%s is getting worse: %s" % (label(model, key), note))
        # disks we know that lsblk no longer lists
        for r in c.execute("SELECT serial, model, state, dev FROM disks").fetchall():
            if r[0] in seen:
                continue
            if r[0].startswith("dev:"):
                c.execute("DELETE FROM disks WHERE serial=?", (r[0],))     # no serial, cannot be followed: just gone
            elif r[2] != "missing":
                c.execute("UPDATE disks SET state='missing', worse=worse WHERE serial=?", (r[0],))
                event(c, t, "missing", r[0], "%s (was %s) is not there any more" % (label(r[1], r[0]), r[3]))
        # retention
        c.execute("DELETE FROM smart WHERE time < ?", (t - SMART_KEEP_DAYS * 86400,))
        c.execute("DELETE FROM smart WHERE time < ? AND rowid NOT IN (SELECT MIN(rowid) FROM smart WHERE time < ? GROUP BY serial, time / 86400)",
                  (t - SMART_THIN_DAYS * 86400, t - SMART_THIN_DAYS * 86400))
        c.execute("DELETE FROM events WHERE id NOT IN (SELECT id FROM events ORDER BY id DESC LIMIT ?)", (KEEP_EVENTS,))
        c.execute("INSERT OR REPLACE INTO meta VALUES ('collect_ok','1')")
        c.execute("INSERT OR REPLACE INTO meta VALUES ('collect_time',?)", (str(t),))
        c.execute("INSERT OR REPLACE INTO meta VALUES ('collect_try',?)", (str(t),))
    return 0


def clean(s):
    return str(s if s is not None else "-").replace("\t", " ").replace("\n", " ")


# ---------------------------------------------------------------- the daily SMART check (docs/PLAN-disk-health.md)
COLS = ("hours", "realloc", "pending", "uncorr", "crc", "nv_crit", "nv_media", "nv_used", "nv_spare", "nv_spare_thr")
MONOTONIC = ("realloc", "crc", "nv_media", "nv_used")
RANK = {"healthy": 0, "watch": 1, "failing": 2}
NAMES = {"realloc": "reallocated", "pending": "pending", "uncorr": "offline uncorrectable", "crc": "CRC",
         "nv_crit": "NVMe critical warning", "nv_media": "NVMe media errors", "nv_used": "NVMe wear %", "nv_spare": "NVMe spare %"}


def read_readings(wake=None):
    """name -> row from disk-health.sh --readings (the only script that asks the disks); wake = names to read without -n standby."""
    cmd = [BASH, os.environ.get("HS_DISK_HEALTH") or os.path.join(HERE, "disk-health.sh"), "--readings"]
    if wake:
        cmd += ["--wake", ",".join(wake)]
    rows = {}
    for line in run(cmd, 900).splitlines():
        f = line.split("\t")
        if len(f) < 16 or not f[0]:
            continue
        r = {"name": f[0], "state": f[1], "kind": f[2], "serial": "" if f[3] == "-" else f[3], "wwn": "" if f[4] == "-" else f[4],
             "model": "" if f[15] == "-" else f[15]}
        for k, v in zip(COLS, f[5:15]):
            r[k] = num(v)
        rows[f[0]] = r
    return rows


def cmd_baseline_run(args):
    if os.environ.get("HS_STATE_NO_COLLECT"):
        return 0
    t = now()
    rows = read_readings()
    c = open_rw()
    if not rows:
        with c:
            c.execute("INSERT OR REPLACE INTO meta VALUES ('baseline_try',?)", (str(t),))
        return 0
    by_serial, by_dev = {}, {}
    for serial, dev, last_read in c.execute("SELECT serial, dev, last_read FROM baseline"):
        by_serial[serial] = last_read
        by_dev[dev] = last_read
    meta = dict(c.execute("SELECT key, value FROM meta"))
    due, wake_keys = [], []
    for name, r in rows.items():
        if r["state"] != "asleep":
            continue
        if r["serial"] and r["serial"] in by_serial:
            last = by_serial[r["serial"]]
        elif name in by_dev:
            last = by_dev[name]
        else:
            last = None
        # the last wake ATTEMPT counts too: a disk that gives no usable reading (bridge, HBA) is not woken every night
        wkey = "baseline_wake:" + (r["serial"] or name)
        tried = num(meta.get(wkey))
        if tried is not None and t - tried < WAKE_DAYS * 86400:
            continue
        if last is None or t - last >= WAKE_DAYS * 86400:
            due.append(name)
            wake_keys.append(wkey)
    if due:
        for name, r in read_readings(due).items():
            if r["state"] == "read" and name in rows:
                rows[name] = r
    with c:
        for wkey in wake_keys:
            c.execute("INSERT OR REPLACE INTO meta VALUES (?,?)", (wkey, str(t)))
        seed = c.execute("SELECT COUNT(*) FROM baseline").fetchone()[0] == 0
        for name, r in rows.items():
            if r["state"] == "read" and r["serial"]:
                process(c, t, r, seed)
            elif r["state"] == "asleep":
                if r["serial"]:
                    c.execute("UPDATE baseline SET last_try=? WHERE serial=?", (t, r["serial"]))
                else:
                    c.execute("UPDATE baseline SET last_try=? WHERE dev=?", (t, name))
        c.execute("DELETE FROM baseline WHERE last_read < ?", (t - SMART_KEEP_DAYS * 86400,))
        c.execute("INSERT OR REPLACE INTO meta VALUES ('baseline_time',?)", (str(t),))
        c.execute("INSERT OR REPLACE INTO meta VALUES ('baseline_try',?)", (str(t),))
    return 0


def process(c, t, r, seed):
    """Compare one reading with the stored one and keep the level (decisions 3 to 7 of the plan)."""
    serial, name = r["serial"], r["name"]
    lab = label(r["model"], serial)
    row = c.execute("SELECT wwn, hours, level, level_time, note, " + ", ".join(COLS[1:]) + " FROM baseline WHERE serial=?", (serial,)).fetchone()
    if row is None:
        c.execute("INSERT INTO baseline (serial, wwn, dev, kind, first_read, last_read, last_try, " + ", ".join(COLS) +
                  ", level, level_time, note) VALUES (?,?,?,?,?,?,?," + ",".join("?" * len(COLS)) + ",'healthy',?,?)",
                  (serial, r["wwn"], name, r["kind"], t, t, t) + tuple(r[k] for k in COLS) + (t, "first reading"))
        if not seed:
            event(c, t, "baseline", serial, "first SMART reading of %s as %s" % (lab, name))
        return
    st = dict(zip(("wwn", "hours", "level", "level_time", "note") + COLS[1:], row))
    reason = None
    if st["wwn"] and r["wwn"] and st["wwn"] != r["wwn"]:
        reason = "a different disk with the same serial (WWN %s -> %s)" % (st["wwn"], r["wwn"])
    elif st["hours"] is not None and r["hours"] is not None and r["hours"] + 1 < st["hours"]:
        reason = "power-on hours went down (%d -> %d)" % (st["hours"], r["hours"])
    if reason:
        c.execute("UPDATE baseline SET " + ", ".join("%s=?" % k for k in COLS) +
                  ", wwn=?, dev=?, kind=?, first_read=?, last_read=?, last_try=?, level='healthy', level_time=?, note=? WHERE serial=?",
                  tuple(r[k] for k in COLS) + (r["wwn"], name, r["kind"], t, t, t, t, "baseline taken again: " + reason, serial))
        event(c, t, "smart-reset", serial, "%s: baseline taken again, %s" % (lab, reason))
        return

    def known(k):
        return r[k] is not None and st[k] is not None

    delta = {}
    for k in COLS:
        delta[k] = r[k] - st[k] if known(k) else 0
    for k in MONOTONIC:
        if known(k) and r[k] < st[k]:
            event(c, t, "smart-reset", serial, "%s: %s went down %d -> %d (firmware or controller reset); new baseline" % (lab, NAMES[k], st[k], r[k]))
            delta[k] = 0

    def text(k):
        return "%s %d -> %d" % (NAMES[k], st[k], r[k])

    failing, watch = [], []
    if delta["pending"] > 0:
        failing.append(text("pending"))
    if delta["uncorr"] > 0:
        failing.append(text("uncorr"))
    if delta["realloc"] >= FAIL_REALLOC:
        failing.append(text("realloc"))
    if (r["nv_crit"] or 0) & ~(st["nv_crit"] or 0):
        failing.append("%s %d -> %d" % (NAMES["nv_crit"], st["nv_crit"] or 0, r["nv_crit"]))
    if delta["nv_media"] >= FAIL_MEDIA:
        failing.append(text("nv_media"))
    spare_fell = known("nv_spare") and r["nv_spare"] < st["nv_spare"]
    if spare_fell:
        thr = r["nv_spare_thr"] if r["nv_spare_thr"] is not None else st["nv_spare_thr"]
        if thr is not None and r["nv_spare"] <= thr < st["nv_spare"]:
            failing.append(text("nv_spare"))
        else:
            watch.append(text("nv_spare"))
    if 0 < delta["realloc"] < FAIL_REALLOC:
        watch.append(text("realloc"))
    if delta["crc"] > 0:
        watch.append(text("crc"))
    if 0 < delta["nv_media"] < FAIL_MEDIA:
        watch.append(text("nv_media"))
    if delta["nv_used"] >= WEAR_JUMP:
        watch.append(text("nv_used"))
    now_level = "failing" if failing else ("watch" if watch else "healthy")
    now_note = ", ".join(failing + watch)
    stored = st["level"]
    held_out = stored != "healthy" and t - (st["level_time"] or 0) >= HOLD_DAYS * 86400
    fresh = False
    if now_level != "healthy" and (RANK[now_level] >= RANK[stored] or held_out):
        # a finding at least as bad as the held level, or any finding once the hold has run out, is the level now
        level, level_time, note = now_level, t, now_note
        fresh = stored == "healthy" or RANK[now_level] > RANK[stored] or held_out
    elif held_out:
        level, level_time, note = "healthy", t, ""
    elif now_level != "healthy":
        # a lower finding during the hold: the held level stays, the finding is added to its note (never lost)
        old = st["note"] or ""
        level, level_time, note = stored, st["level_time"], (old + "; " if old else "") + now_note
    else:
        level, level_time, note = stored, st["level_time"], (st["note"] or "") if stored != "healthy" else ""
    if fresh:
        event(c, t, "smart-" + level, serial, "%s: %s since the last daily SMART check: %s"
              % (lab, "got worse" if level == "failing" else "changed", note))
    vals = [r[k] if r[k] is not None else st.get(k) for k in COLS[1:]]
    hours = r["hours"] if r["hours"] is not None else st["hours"]
    c.execute("UPDATE baseline SET hours=?, " + ", ".join("%s=?" % k for k in COLS[1:]) +
              ", wwn=?, dev=?, kind=?, last_read=?, last_try=?, level=?, level_time=?, note=? WHERE serial=?",
              [hours] + vals + [r["wwn"] or st["wwn"], name, r["kind"], t, t, level, level_time, note, serial])


def cmd_baseline():
    c = open_ro()
    if c is None:
        return 0
    try:
        for r in c.execute("SELECT b.serial, b.dev, b.kind, b.level, b.level_time, b.last_read, b.first_read, b.wwn, b.realloc, b.pending, "
                           "b.uncorr, b.crc, b.nv_crit, b.nv_media, b.nv_used, b.nv_spare, d.state, b.note "
                           "FROM baseline b LEFT JOIN disks d ON d.serial = b.serial "
                           "ORDER BY CASE b.level WHEN 'failing' THEN 0 WHEN 'watch' THEN 1 ELSE 2 END, b.dev, b.serial"):
            print("\t".join(clean(x) if x not in (None, "") else "-" for x in r))
    except sqlite3.Error:
        return 0
    return 0


def cmd_disks():
    c = open_ro()
    if c is None:
        return 0
    for r in c.execute("SELECT serial, model, size, dev, state, role, pool, first_seen, last_seen, worse, note FROM disks "
                       "ORDER BY CASE state WHEN 'missing' THEN 0 ELSE 1 END, dev, serial"):
        print("\t".join(clean(x) if x not in (None, "") else "-" for x in r))
    return 0


def cmd_events(args):
    c = open_ro()
    if c is None:
        return 0
    n = int(args[0]) if args and args[0].isdigit() else 30
    rows = c.execute("SELECT time, kind, subject, text FROM events ORDER BY id DESC LIMIT ?", (n,)).fetchall()
    for r in reversed(rows):
        print("\t".join(clean(x) for x in r))
    return 0


def find_disk(c, who):
    who = who.replace("/dev/", "")
    r = c.execute("SELECT serial, state, model FROM disks WHERE serial=? OR dev=? ORDER BY (serial=?) DESC, (state='missing') DESC",
                  (who, who, who)).fetchone()
    return r


def cmd_smart(args):
    c = open_ro()
    if c is None or not args:
        return 0
    r = find_disk(c, args[0])
    if not r:
        return 1
    for row in c.execute("SELECT time, realloc, pending, crc, temp, hours FROM smart WHERE serial=? ORDER BY time DESC LIMIT 200", (r[0],)):
        print("\t".join(clean(x) for x in row))
    return 0


def cmd_problems():
    c = open_ro()
    if c is None:
        return 0
    t = now()
    try:
        based = {r[0] for r in c.execute("SELECT serial FROM baseline")}
    except sqlite3.Error:
        based = set()
    for r in c.execute("SELECT serial, model, dev, last_seen, state, worse, note FROM disks"):
        serial, model, dev, last, state, worse, note = r
        if state == "missing":
            when = time.strftime("%Y-%m-%d", time.localtime(last))
            print("disk:%s:missing\tdisk %s is missing since %s (it was %s). Gone for good? Run: hs disk %s forget"
                  % (serial, label(model, serial), when, dev, serial))
        elif worse and serial not in based:
            print("disk:%s:worse\tdisk %s is getting worse: %s. Details: hs disk %s health" % (serial, label(model, serial), note, dev))
    try:
        rated = c.execute("SELECT b.serial, b.dev, b.level, b.note, d.model, d.state FROM baseline b LEFT JOIN disks d ON d.serial = b.serial "
                          "WHERE b.level IN ('watch', 'failing') ORDER BY b.serial").fetchall()
    except sqlite3.Error:
        rated = []
    for serial, dev, level, note, model, state in rated:
        if state == "missing":
            continue
        if level == "failing":
            print("disk:%s:smart-failing\tdisk %s got worse since the last daily SMART check: %s. Replace it soon. Details: hs disk %s health"
                  % (serial, label(model, serial), note, dev))
        else:
            print("disk:%s:smart-watch\tdisk %s changed since the last daily SMART check: %s. Details: hs disk baseline"
                  % (serial, label(model, serial), note))
    m = dict(c.execute("SELECT key, value FROM meta"))
    ok_t = num(m.get("collect_time"))
    if ok_t is not None and t - ok_t > STALE_S:
        print("state:stale\tthe disk inventory was not updated for %d minutes. Check: systemctl status hs-state-collect hs-deck-status"
              % ((t - ok_t) // 60))
    bt = num(m.get("baseline_time"))
    if bt is not None and t - bt > BASELINE_STALE_S:
        print("smart:stale\tthe daily SMART check has not run for %d days. Check: systemctl status hs-smart-baseline" % ((t - bt) // 86400))
    return 0


def cmd_deck_disks():
    """name bytes kind role temp as in the old deck document, only when the last collect is fresh (else nothing: the caller falls back)."""
    c = open_ro()
    if c is None:
        return 1
    m = dict(c.execute("SELECT key, value FROM meta"))
    ok_t = num(m.get("collect_time"))
    if ok_t is None or m.get("collect_ok") != "1" or now() - ok_t > int(os.environ.get("HS_STATE_FRESH", "120")):
        return 1
    for r in c.execute("SELECT dev, size, kind, role, temp FROM disks WHERE state != 'missing' ORDER BY dev"):
        print("\t".join([r[0], str(r[1] if r[1] is not None else "-"), r[2] or "-", r[3] or "-", str(r[4]) if r[4] is not None else "-"]))
    return 0


def cmd_inventory_json():
    c = open_ro()
    if c is None:
        print("null")
        return 0
    rows = c.execute("SELECT serial, model, dev, last_seen, state, worse, note FROM disks").fetchall()
    print(json.dumps({
        "known": len(rows),
        "missing": [{"serial": r[0], "model": r[1], "last_seen": r[3]} for r in rows if r[4] == "missing"],
        "worse": [{"serial": r[0], "dev": r[2], "note": r[6]} for r in rows if r[5] and r[4] != "missing"],
    }, separators=(",", ":")))
    return 0


def mask(serial):
    """The status endpoint is open to the home network: serial numbers leave the server only as their last four characters."""
    if not serial or serial.startswith("dev:"):
        return serial or ""
    return "..." + serial[-4:] if len(serial) > 4 else serial


def cmd_disks_json():
    c = open_ro()
    rows = [] if c is None else c.execute(
        "SELECT serial, model, size, dev, state, role, pool, first_seen, last_seen, worse, note FROM disks ORDER BY dev, serial").fetchall()
    print(json.dumps({"schema": 1, "disks": [
        {"id": mask(r[0]), "model": r[1], "size": r[2], "dev": r[3], "state": r[4], "role": r[5], "pool": r[6],
         "first_seen": r[7], "last_seen": r[8], "worse": bool(r[9]), "note": r[10] or ""} for r in rows]}, separators=(",", ":")))
    return 0


def cmd_events_json(args):
    c = open_ro()
    n = int(args[0]) if args and args[0].isdigit() else 50
    rows = [] if c is None else c.execute("SELECT time, kind, subject, text FROM events ORDER BY id DESC LIMIT ?", (n,)).fetchall()
    print(json.dumps({"schema": 1, "events": [
        {"time": r[0], "kind": r[1], "id": mask(r[2]), "text": re.sub(r"S/N (\S+?)\)", lambda m: "S/N " + mask(m.group(1)) + ")", r[3] or "")}
        for r in rows]}, separators=(",", ":")))
    return 0


def cmd_forget(args):
    if not args:
        print("usage: forget <serial|dev> [--yes]", file=sys.stderr)
        return 1
    c = open_rw()
    r = find_disk(c, args[0])
    if not r:
        print("no such disk in the inventory: %s" % args[0], file=sys.stderr)
        return 1
    if r[1] != "missing":
        print("%s is in the machine (state %s): only a missing disk can be forgotten" % (args[0], r[1]), file=sys.stderr)
        return 2
    with c:
        c.execute("DELETE FROM disks WHERE serial=?", (r[0],))
        c.execute("DELETE FROM smart WHERE serial=?", (r[0],))
        c.execute("DELETE FROM baseline WHERE serial=?", (r[0],))
        event(c, now(), "forgotten", r[0], "%s was removed from the list on purpose" % label(r[2], r[0]))
    print(r[0])
    return 0


# ---------------------------------------------------------------- history (the last 24 hours of the status document)
HIST_EXPECTED = int(os.environ.get("DH_EXPECTED", "360"))    # readings in a full hour: one every 10 seconds
HIST_KEEP = int(os.environ.get("DH_KEEP", "72"))              # finished hours kept


def median(values):
    v = sorted(x for x in values if x is not None)
    if not v:
        return None
    n = len(v)
    return v[n // 2] if n % 2 else (v[n // 2 - 1] + v[n // 2]) / 2


def tidy(x):
    """1.0 -> 1 so the JSON reads like the one jq made from the old text files."""
    return int(x) if isinstance(x, float) and x == int(x) else x


def migrate_history(c):
    """The old files (scripts/lib/deck-history.sh) become rows once: hours, the readings of the current hour, the last counters."""
    if c.execute("SELECT value FROM meta WHERE key='history_migrated'").fetchone():
        return
    d = os.environ.get("DH_DIR") or os.path.join(STATE_DIR, "deck-history")

    def val(s):
        return None if s in ("-", "") else float(s)

    def lines(name):
        try:
            with open(os.path.join(d, name), encoding="utf-8") as f:
                return [ln.split() for ln in f if ln.strip()]
        except OSError:
            return []
    for p in lines("hours"):
        if len(p) >= 8:
            c.execute("INSERT OR IGNORE INTO hours VALUES (?,?,?,?,?,?,?,?)",
                      (int(p[0]), val(p[1]), val(p[2]), val(p[3]), val(p[4]), val(p[5]), float(p[6]), int(p[7])))
    for p in lines("samples"):
        if len(p) >= 7:
            c.execute("INSERT INTO samples VALUES (?,?,?,?,?,?,?)",
                      (int(p[0]), val(p[1]), val(p[2]), val(p[3]), val(p[4]), val(p[5]), int(p[6])))
    for p in lines("last")[:1]:
        c.execute("INSERT OR REPLACE INTO meta VALUES ('hist_last',?)", (" ".join(p),))
    c.execute("INSERT OR REPLACE INTO meta VALUES ('history_migrated',?)", (str(now()),))
    for name in ("hours", "samples", "last"):       # the old files are kept, under another name, for the day somebody wants them
        try:
            os.replace(os.path.join(d, name), os.path.join(d, name + ".migrated"))
        except OSError:
            pass


def roll_hours(c, current_hour):
    for (h,) in c.execute("SELECT DISTINCT time / 3600 FROM samples WHERE time / 3600 < ?", (current_hour,)).fetchall():
        rows = c.execute("SELECT cpu, mem, gpu, rx, tx, boot FROM samples WHERE time / 3600 = ?", (h,)).fetchall()
        n = len(rows)
        med = [median([r[i] for r in rows]) for i in range(5)]
        c.execute("INSERT OR REPLACE INTO hours VALUES (?,?,?,?,?,?,?,?)",
                  (h, med[0], med[1], med[2], med[3], med[4], round(min(1.0, n / HIST_EXPECTED), 2), 1 if any(r[5] for r in rows) else 0))
    c.execute("DELETE FROM samples WHERE time / 3600 < ?", (current_hour,))
    c.execute("DELETE FROM hours WHERE hour NOT IN (SELECT hour FROM hours ORDER BY hour DESC LIMIT ?)", (HIST_KEEP,))


def cmd_history_record(args):
    """history-record NOW RX TX CPU_TOTAL CPU_IDLE MEM_TOTAL MEM_AVAILABLE GPU_UTIL UPTIME   (an empty argument = unknown)"""
    a = (args + [""] * 9)[:9]
    t, rx, tx, ct, ci, mt, ma, gpu, up = [num(x) for x in a]
    if t is None:
        return 1
    c = open_rw()
    with c:
        migrate_history(c)
        roll_hours(c, t // 3600)
        prev = c.execute("SELECT value FROM meta WHERE key='hist_last'").fetchone()
        pt = prx = ptx = pct = pci = pup = 0
        have_prev = False
        if prev:
            try:
                pt, prx, ptx, pct, pci, pup = [int(x) for x in prev[0].split()[:6]]
                have_prev = True
            except ValueError:
                pass
        cpu = mem = rxr = txr = None
        boot = 0
        if have_prev and t > pt:
            dt = t - pt
            if rx is not None and rx >= prx:
                rxr = (rx - prx) // dt
            if tx is not None and tx >= ptx:
                txr = (tx - ptx) // dt
            if ct is not None and ci is not None and ct > pct:
                cpu = int(100 * (1 - (ci - pci) / (ct - pct)) + 0.5)
            if up is not None and up < pup:
                boot = 1
        if mt is not None and ma is not None and mt > 0:
            mem = int(100 * (1 - ma / mt) + 0.5)
        c.execute("INSERT INTO samples VALUES (?,?,?,?,?,?,?)", (t, cpu, mem, gpu, rxr, txr, boot))
        c.execute("INSERT OR REPLACE INTO meta VALUES ('hist_last',?)",
                  (" ".join(str(x or 0) for x in (t, rx, tx, ct, ci, up)),))
    return 0


def cmd_history_json(args):
    t = num(args[0]) if args else now()
    hour = (t if t is not None else now()) // 3600
    c = open_ro()
    got = {}
    if c is not None:
        try:
            for r in c.execute("SELECT hour, cpu, mem, gpu, rx, tx, up, boot FROM hours WHERE hour >= ? AND hour < ?", (hour - 24, hour)):
                got[r[0]] = r
        except sqlite3.Error:
            pass
    hours = []
    for h in range(hour - 24, hour):
        r = got.get(h)
        hours.append(None if r is None else {"t": h * 3600, "cpu": tidy(r[1]), "mem": tidy(r[2]), "gpu": tidy(r[3]),
                                              "rx": tidy(r[4]), "tx": tidy(r[5]), "up": tidy(r[6]), "boot": bool(r[7])})
    print(json.dumps({"interval_s": 3600, "hours": hours}, separators=(",", ":")))
    return 0


USAGE_EVERY = int(os.environ.get("HS_USAGE_EVERY", "3600"))
USAGE_KEEP_DAYS = 400


def cmd_usage_record(args):
    """usage-record KEY USED SIZE: at most one reading per USAGE_EVERY seconds and key; a year and a bit is kept."""
    if len(args) < 3 or not re.fullmatch(r"[A-Za-z0-9:_./-]{1,64}", args[0]):
        return 1
    used, size = num(args[1]), num(args[2])
    if used is None or size is None or size <= 0:
        return 1
    t = now()
    c = open_rw()
    with c:
        last = c.execute("SELECT MAX(time) FROM usage WHERE key=?", (args[0],)).fetchone()[0]
        if last is not None and 0 <= t - last < USAGE_EVERY:
            return 0
        c.execute("INSERT INTO usage VALUES (?,?,?,?)", (t, args[0], used, size))
        c.execute("DELETE FROM usage WHERE time < ?", (t - USAGE_KEEP_DAYS * 86400,))
    return 0


def cmd_usage(args):
    """usage KEY [DAYS]: nothing (and exit 0) when there is no database or no reading."""
    if not args:
        return 1
    days = num(args[1]) if len(args) > 1 else 60
    c = open_ro()
    if c is None:
        return 0
    try:
        for r in c.execute("SELECT time, used, size FROM usage WHERE key=? AND time >= ? ORDER BY time",
                           (args[0], now() - (days or 60) * 86400)):
            print("%d\t%d\t%d" % r)
    except sqlite3.Error:
        pass
    return 0


def cmd_read_put(args):
    """read-put <key> [--ms N] [--rc N]: the payload is standard input. A key is the words of the read ("monitor disks")."""
    key, ms, rc = "", None, 0
    i = 0
    while i < len(args):
        if args[i] == "--ms" and i + 1 < len(args):
            ms = int(args[i + 1]); i += 2
        elif args[i] == "--rc" and i + 1 < len(args):
            rc = int(args[i + 1]); i += 2
        elif not key:
            key = args[i]; i += 1
        else:
            print("usage: read-put <key> [--ms N] [--rc N]", file=sys.stderr)
            return 1
    if not re.fullmatch(r"[a-z0-9-]+( [a-z0-9-]+){0,3}", key or ""):
        print("a key is the words of a read, like: monitor disks", file=sys.stderr)
        return 1
    payload = sys.stdin.read()
    if len(payload) > 4_000_000:
        print("the output is too big to keep", file=sys.stderr)
        return 1
    c = open_rw()
    with c:
        c.execute("INSERT INTO reads (key, payload, updated, ms, rc) VALUES (?, ?, ?, ?, ?) "
                  "ON CONFLICT(key) DO UPDATE SET payload = excluded.payload, updated = excluded.updated, ms = excluded.ms, rc = excluded.rc",
                  (key, payload, now(), ms, rc))
    return 0


def cmd_read_get(args):
    c = open_ro()
    if c is None or len(args) != 1:
        return 1
    try:
        row = c.execute("SELECT payload FROM reads WHERE key = ?", (args[0],)).fetchone()
    except sqlite3.Error:
        return 1
    if row is None:
        return 1
    sys.stdout.write(row[0])
    return 0


def cmd_reads():
    c = open_ro()
    if c is None:
        return 0
    try:
        for key, updated, ms, rc, size in c.execute("SELECT key, updated, ms, rc, length(payload) FROM reads ORDER BY updated"):
            print("%s\t%d\t%s\t%d\t%d" % (key, max(0, now() - updated), "-" if ms is None else ms, rc, size))
    except sqlite3.Error:
        pass
    return 0


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1
    cmd, args = argv[1], argv[2:]
    try:
        sys.stdout.reconfigure(newline="\n")     # no CRLF on a Windows workstation
    except (AttributeError, ValueError):
        pass
    if cmd == "collect":
        return collect(args)
    if cmd == "baseline-run":
        return cmd_baseline_run(args)
    if cmd == "baseline":
        return cmd_baseline()
    if cmd == "disks":
        return cmd_disks()
    if cmd == "events":
        return cmd_events(args)
    if cmd == "smart":
        return cmd_smart(args)
    if cmd == "problems":
        return cmd_problems()
    if cmd == "deck-disks":
        return cmd_deck_disks()
    if cmd == "inventory-json":
        return cmd_inventory_json()
    if cmd == "forget":
        return cmd_forget(args)
    if cmd == "disks-json":
        return cmd_disks_json()
    if cmd == "events-json":
        return cmd_events_json(args)
    if cmd == "history-record":
        return cmd_history_record(args)
    if cmd == "history":
        return cmd_history_json(args)
    if cmd == "usage-record":
        return cmd_usage_record(args)
    if cmd == "usage":
        return cmd_usage(args)
    if cmd == "read-put":
        return cmd_read_put(args)
    if cmd == "read-get":
        return cmd_read_get(args)
    if cmd == "reads":
        return cmd_reads()
    print("unknown command: %s" % cmd, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
