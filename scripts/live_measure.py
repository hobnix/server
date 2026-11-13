#!/usr/bin/env python3
"""Measure the live state on the state database (ADR 0026 step 1, issue #481): scripts/live-measure.sh runs this.

For --seconds it looks at state.db read-only (sizes, the heartbeat row of the collector hs-live-db, the change counters, the table reads) and sends
one probe every --probe-every seconds: `state-db.py topic-bump live:probe`. The web interface (Events.record_probe) appends a line
"topic TAB gen TAB epoch-ms TAB streams" to the probe file when that counter reaches the stream queues; the time between the end of the bump and
that line is the change latency (the server end of "browser-visible"). Writes <out>.tsv (label TAB value, "-" = empty) and <out>.md.
Prints one progress line per minute. Stdlib only, no terminal styling. Exit 0 when done, 1 when there is no state.db.
Environment: HS_STATE_DB, HS_STATE_DIR, HS_WEB_PROBE_FILE, HS_STATE_PY (path of state-db.py), HS_MEASURE_LOST_S (seconds before a probe is lost, 10)."""
import argparse
import math
import os
import sqlite3
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
STATE_DIR = os.environ.get("HS_STATE_DIR", "/var/lib/hs")
DB = os.environ.get("HS_STATE_DB", os.path.join(STATE_DIR, "state.db"))
PROBE_FILE = os.environ.get("HS_WEB_PROBE_FILE", "/run/hs-web/probe.tsv")
STATE_PY = os.environ.get("HS_STATE_PY", os.path.join(HERE, "state-db.py"))
LOST_S = float(os.environ.get("HS_MEASURE_LOST_S", "10"))
BEAT_FIELDS = ("started", "beats", "docs", "fails", "bytes", "slow", "wait_ms")


def size(path):
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


def snapshot():
    """Read-only look: sizes, heartbeat row (dict or None), sum(gen) of the counters without live:probe, rows and payload bytes of `live`,
    {key: (updated, ts_err)} of `reads`."""
    snap = {"db": size(DB), "wal": size(DB + "-wal"), "beat": None, "gens": 0, "live_rows": 0, "live_bytes": 0, "reads": {}}
    c = sqlite3.connect("file:%s?mode=ro" % DB.replace("\\", "/"), uri=True, timeout=5)
    try:
        c.execute("PRAGMA query_only=1")

        def one(sql, default=None):
            try:
                return c.execute(sql).fetchone()
            except sqlite3.Error:
                return default

        row = one("SELECT %s FROM heartbeat WHERE name = 'hs-live'" % ", ".join(BEAT_FIELDS))
        if row:
            snap["beat"] = dict(zip(BEAT_FIELDS, row))
        row = one("SELECT COALESCE(SUM(gen), 0) FROM topics WHERE topic != 'live:probe'")
        snap["gens"] = int(row[0]) if row else 0
        row = one("SELECT COUNT(*), COALESCE(SUM(length(payload)), 0) FROM live")
        if row:
            snap["live_rows"], snap["live_bytes"] = int(row[0]), int(row[1])
        try:
            snap["reads"] = {k: (u, e) for k, u, e in c.execute("SELECT key, updated, ts_err FROM reads")}
        except sqlite3.Error:
            pass
    finally:
        c.close()
    return snap


def probe_gen():
    try:
        c = sqlite3.connect("file:%s?mode=ro" % DB.replace("\\", "/"), uri=True, timeout=5)
        try:
            row = c.execute("SELECT gen FROM topics WHERE topic = 'live:probe'").fetchone()
        finally:
            c.close()
        return int(row[0]) if row else None
    except sqlite3.Error:
        return None


class ProbeFile:
    """Follows the probe file: new lines since the last look; starts again from 0 when the file got smaller (the web rewrites it when big)."""

    def __init__(self, path):
        self.path, self.off = path, 0
        self.off = size(path) if path else 0       # lines from before this run do not count

    def new_lines(self):
        if not self.path:
            return []
        n = size(self.path)
        if n < self.off:
            self.off = 0
        if n == self.off:
            return []
        try:
            with open(self.path, "rb") as f:
                f.seek(self.off)
                data = f.read()
        except OSError:
            return []
        end = data.rfind(b"\n")
        if end < 0:
            return []
        self.off += end + 1
        out = []
        for line in data[:end].decode("utf-8", "replace").splitlines():
            p = line.split("\t")
            if len(p) >= 4 and p[0] == "live:probe" and p[1].isdigit() and p[2].isdigit() and p[3].isdigit():
                out.append((int(p[1]), int(p[2]), int(p[3])))
        return out


def pct(vals, q):
    if not vals:
        return None
    v = sorted(vals)
    return v[max(0, math.ceil(q * len(v)) - 1)]


def fmt(v, digits=1):
    if v is None:
        return "-"
    if isinstance(v, float):
        return ("%." + str(digits) + "f") % v
    return str(v)


def rows_of(args, start, end, probes, reads_changes, matched):
    minutes = args.seconds / 60.0
    lat = [m["lat"] for m in matched]
    wr = [p["ta"] - p["tb"] for p in probes]
    b0, b1 = start["beat"], end["beat"]
    same = b0 is not None and b1 is not None and b0["started"] == b1["started"]
    restarted = "-" if (b0 is None or b1 is None) else ("no" if same else "yes")

    def d(k):
        return (b1[k] - b0[k]) if same else None

    def per_min(v):
        return None if v is None else v / minutes

    commits = None
    mean_ms = None
    if same:
        commits = d("docs") + d("fails") + d("beats")
        mean_ms = (d("wait_ms") / commits) if commits else None
    kib = None if not same else d("bytes") / 1024.0 / minutes
    return [
        ("period minutes", fmt(minutes)),
        ("mode", args.mode),
        ("collector doc writes/min", fmt(per_min(d("docs")) if same else None)),
        ("collector failure writes/min", fmt(per_min(d("fails")) if same else None)),
        ("collector heartbeats/min", fmt(per_min(d("beats")) if same else None)),
        ("payload KiB/min", fmt(kib)),
        ("commits over 100 ms", fmt(d("slow") if same else None)),
        ("mean commit ms", fmt(mean_ms)),
        ("counter bumps/min (without probe)", fmt((end["gens"] - start["gens"]) / minutes)),
        ("old collector writes/min", fmt(reads_changes / minutes)),
        ("state.db growth KiB", fmt((end["db"] - start["db"]) / 1024.0)),
        ("WAL growth KiB", fmt((end["wal"] - start["wal"]) / 1024.0)),
        ("state.db end KiB", fmt(end["db"] / 1024.0)),
        ("WAL end KiB", fmt(end["wal"] / 1024.0)),
        ("probes sent", str(len(probes))),
        ("probes matched", str(len(matched))),
        ("probes lost", str(len(probes) - len(matched))),
        ("latency min ms", fmt(min(lat) if lat else None, 0)),
        ("latency median ms", fmt(statistics.median(lat) if lat else None, 0)),
        ("latency p95 ms", fmt(pct(lat, 0.95), 0)),
        ("latency max ms", fmt(max(lat) if lat else None, 0)),
        ("probe write median ms", fmt(statistics.median(wr) if wr else None, 0)),
        ("probe write max ms", fmt(max(wr) if wr else None, 0)),
        ("probes with a stream open", str(sum(1 for m in matched if m["streams"] > 0))),
        ("collector restarted during the run", restarted),
    ]


def write_files(out, args, rows):
    with open(out + ".tsv", "w", encoding="utf-8", newline="") as f:
        for k, v in rows:
            f.write("%s\t%s\n" % (k, v if v != "" else "-"))
    lines = [
        "# Live state on the state database, measurement (ADR 0026 step 1, issue #481)",
        "",
        "Period: %s minutes, mode: %s, probe every %s s." % (fmt(args.seconds / 60.0), args.mode, args.probe_every),
        "",
        "| What | Value |",
        "| --- | --- |",
    ] + ["| %s | %s |" % (k, v) for k, v in rows] + [
        "",
        "Limits:",
        "",
        "- In db mode nothing wakes a topic early (no refresh channel); topics are read at their intervals, so refresh-triggered reads are not in the write rate.",
        "- The latency ends where the web interface puts `changed` into the stream queues. The LAN hop and the browser render time are not included.",
        "- `probes with a stream open` counts the probes that found at least one open stream; with none open the latency is still measured at the hub.",
        "- The old collector's writes are counted from changes of `updated` / `ts_err` in the table `reads`; its unchanged runs show only as `updated` moves.",
        "- When the collector restarted during the run, its rows are `-`.",
        "",
    ]
    with open(out + ".md", "w", encoding="utf-8", newline="") as f:
        f.write("\n".join(lines))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, required=True)
    ap.add_argument("--probe-every", type=float, default=10)
    ap.add_argument("--out", required=True)
    ap.add_argument("--mode", default="off")
    args = ap.parse_args()
    if not os.path.exists(DB):
        print("no state database at %s" % DB)
        return 1
    start = snapshot()
    pf = ProbeFile(PROBE_FILE)
    pending, probes, matched = {}, [], []
    reads_changes, prev_reads = 0, start["reads"]
    t_start = time.time()
    next_probe, next_minute, minute = t_start, t_start + 60, 0

    def collect_lines():
        for gen, ms, streams in pf.new_lines():
            p = pending.pop(gen, None)
            if p:
                p["lat"] = max(0, ms - p["ta"])
                p["streams"] = streams
                matched.append(p)

    def expire(now):
        for g in [g for g, p in pending.items() if now - p["ta"] / 1000.0 > LOST_S]:
            del pending[g]

    def look():
        nonlocal reads_changes, prev_reads
        s = snapshot()
        reads_changes += sum(1 for k, v in s["reads"].items() if prev_reads.get(k) != v)
        prev_reads = s["reads"]

    while time.time() - t_start < args.seconds:
        now = time.time()
        if now >= next_probe:
            tb = int(time.time() * 1000)
            subprocess.run([sys.executable, STATE_PY, "topic-bump", "live:probe"], capture_output=True, env=dict(os.environ, HS_STATE_DB=DB))
            ta = int(time.time() * 1000)
            gen = probe_gen()
            p = {"tb": tb, "ta": ta}
            probes.append(p)
            if gen is not None:
                pending[gen] = p
            next_probe += args.probe_every
        collect_lines()
        expire(time.time())
        look()
        if time.time() >= next_minute:
            minute += 1
            med = statistics.median([m["lat"] for m in matched]) if matched else None
            print("minute %d of %s: %d probes, median %s ms" % (minute, fmt(args.seconds / 60.0, 0), len(probes), fmt(med, 0)), flush=True)
            next_minute += 60
        time.sleep(min(0.2, max(0.0, next_probe - time.time())))
    # probes still waiting get their time to arrive
    deadline = time.time() + LOST_S
    while pending and time.time() < deadline:
        collect_lines()
        time.sleep(0.2)
    collect_lines()
    end = snapshot()
    rows = rows_of(args, start, end, probes, reads_changes, matched)
    write_files(args.out, args, rows)
    return 0


if __name__ == "__main__":
    sys.exit(main())
