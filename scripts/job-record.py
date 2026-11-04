#!/usr/bin/env python3
"""Job record writer (ADR docs/adr/0004-job-record.md, issue #131).

One JSON file per job in HS_JOBS_DIR (default /var/lib/hs/jobs), written atomically.
Machine-facing: prints the id or JSON on stdout, one line on stderr and exit 1 on any failure.
Never stores argv or environment, only the description the caller gives.

  new --slug S --desc D --unit U --source cli|web|timer|extension --initiator NAME
  run ID | step ID N OF TEXT | progress ID DONE TOTAL UNIT | finish ID EXIT | get ID
"""
import argparse
import contextlib
import datetime
import json
import os
import random
import re
import string
import sys
import time

try:
    import fcntl
except ImportError:   # not Linux (a developer machine): no lock, one writer per job anyway
    fcntl = None

KEEP_COUNT = 200
KEEP_DAYS = 30
RATE_SECONDS = float(os.environ.get("HS_JOB_RATE", "1"))   # the test sets a long time so it cannot depend on speed
SOURCES = ("cli", "web", "timer", "extension")
FIELDS = ("id", "slug", "description", "source", "initiator", "unit", "queued", "started", "ended",
          "state", "exit", "step", "progress", "error", "result", "cancel", "version")


class Fail(Exception):
    pass


def jobs_dir():
    return os.environ.get("HS_JOBS_DIR") or "/var/lib/hs/jobs"


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def path_of(job_id):
    if not re.fullmatch(r"[0-9]{8}-[0-9]{6}-[A-Za-z0-9-]+-[a-z]{4}", job_id or ""):
        raise Fail("bad job id")
    return os.path.join(jobs_dir(), job_id + ".json")


def ensure_dir():
    d = jobs_dir()
    try:
        os.makedirs(d, mode=0o755, exist_ok=True)
        os.chmod(d, 0o755)
    except OSError as e:
        raise Fail("cannot create %s: %s" % (d, e.strerror))


def load(job_id):
    p = path_of(job_id)
    try:
        with open(p, encoding="utf-8") as f:
            rec = json.load(f)
    except OSError as e:
        raise Fail("cannot read record %s: %s" % (job_id, e.strerror))
    except ValueError:
        raise Fail("record %s is not valid JSON" % job_id)
    if not isinstance(rec, dict):
        raise Fail("record %s is not an object" % job_id)
    return rec


def save(rec):
    p = path_of(rec["id"])
    tmp = "%s.%d.tmp" % (p, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({k: rec.get(k) for k in FIELDS}, f, ensure_ascii=False, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o644)
        os.replace(tmp, p)
    except OSError as e:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise Fail("cannot write record: %s" % e.strerror)


@contextlib.contextmanager
def locked(job_id):
    """Read-modify-write of one record under an exclusive lock, so a background step writer and the wrapper's finish never overwrite each other."""
    if fcntl is None:
        yield
        return
    try:
        fd = os.open(os.path.join(jobs_dir(), "%s.lock" % job_id), os.O_CREAT | os.O_WRONLY, 0o644)
    except OSError as e:
        raise Fail("cannot lock record: %s" % e.strerror)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def stamp_path(job_id, kind):
    return os.path.join(jobs_dir(), "%s.%s.stamp" % (job_id, kind))


def rate_limited(job_id, kind):
    """True when the last write of this kind was less than 1 s ago (the stamp file's mtime)."""
    try:
        return time.time() - os.stat(stamp_path(job_id, kind)).st_mtime < RATE_SECONDS
    except OSError:
        return False


def touch_stamp(job_id, kind):
    try:
        with open(stamp_path(job_id, kind), "w"):
            pass
    except OSError:
        pass


def retention():
    """Remove records beyond the newest KEEP_COUNT that are also older than KEEP_DAYS."""
    d = jobs_dir()
    try:
        names = [n for n in os.listdir(d) if n.endswith(".json")]
    except OSError:
        return
    items = []
    for n in names:
        try:
            items.append((os.stat(os.path.join(d, n)).st_mtime, n))
        except OSError:
            pass
    items.sort(reverse=True)
    limit = time.time() - KEEP_DAYS * 86400
    for mtime, n in items[KEEP_COUNT:]:
        if mtime < limit:
            base = n[:-5]
            for victim in [n] + [x for x in os.listdir(d) if x.startswith(base + ".") and x != n]:
                try:
                    os.unlink(os.path.join(d, victim))
                except OSError:
                    pass


def cmd_new(a):
    if a.source not in SOURCES:
        raise Fail("bad source: %s" % a.source)
    ensure_dir()
    ts = datetime.datetime.now(datetime.timezone.utc)
    slug = re.sub(r"[^A-Za-z0-9]+", "-", a.slug).strip("-") or "job"
    suffix = "".join(random.choice(string.ascii_lowercase) for _ in range(4))
    job_id = "%s-%s-%s" % (ts.strftime("%Y%m%d-%H%M%S"), slug, suffix)
    rec = {k: None for k in FIELDS}
    rec.update(id=job_id, slug=slug, description=a.desc, source=a.source, initiator=a.initiator or None,
               unit=a.unit or None, queued=ts.strftime("%Y-%m-%dT%H:%M:%SZ"), state="queued", version=1)
    save(rec)
    retention()
    sys.stdout.write(job_id + "\n")


def cmd_run(a):
    with locked(a.id):
        rec = load(a.id)
        rec["state"] = "running"
        rec["started"] = now_iso()
        save(rec)


def cmd_step(a):
    if rate_limited(a.id, "step") and a.n != a.of:
        return
    with locked(a.id):
        rec = load(a.id)
        rec["step"] = {"n": a.n, "of": a.of, "text": a.text}
        save(rec)
    touch_stamp(a.id, "step")


def cmd_progress(a):
    if rate_limited(a.id, "progress") and a.done != a.total:
        return
    with locked(a.id):
        rec = load(a.id)
        rec["progress"] = {"done": a.done, "total": a.total, "unit": a.unit}
        save(rec)
    touch_stamp(a.id, "progress")


def cmd_finish(a):
    with locked(a.id):
        rec = load(a.id)
        rec["ended"] = now_iso()
        rec["exit"] = a.exit
        if a.exit == 0:
            rec["state"] = "ok"
            rec["error"] = None
        else:
            rec["state"] = "failed"
            rec["error"] = {"category": "exit", "message": "exit status %d" % a.exit}
        save(rec)
    for kind in ("step", "progress"):
        try:
            os.unlink(stamp_path(a.id, kind))
        except OSError:
            pass
    try:
        os.unlink(os.path.join(jobs_dir(), "%s.lock" % a.id))
    except OSError:
        pass


def cmd_get(a):
    load(a.id)
    with open(path_of(a.id), encoding="utf-8") as f:
        sys.stdout.write(f.read())


def main():
    p = argparse.ArgumentParser(prog="job-record.py")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("new")
    s.add_argument("--slug", required=True)
    s.add_argument("--desc", required=True)
    s.add_argument("--unit", default="")
    s.add_argument("--source", default="cli")
    s.add_argument("--initiator", default="")
    s.set_defaults(fn=cmd_new)
    s = sub.add_parser("run"); s.add_argument("id"); s.set_defaults(fn=cmd_run)
    s = sub.add_parser("step"); s.add_argument("id"); s.add_argument("n", type=int)
    s.add_argument("of", type=int); s.add_argument("text"); s.set_defaults(fn=cmd_step)
    s = sub.add_parser("progress"); s.add_argument("id"); s.add_argument("done", type=int)
    s.add_argument("total", type=int); s.add_argument("unit"); s.set_defaults(fn=cmd_progress)
    s = sub.add_parser("finish"); s.add_argument("id"); s.add_argument("exit", type=int); s.set_defaults(fn=cmd_finish)
    s = sub.add_parser("get"); s.add_argument("id"); s.set_defaults(fn=cmd_get)
    try:
        a = p.parse_args()
    except SystemExit as e:
        if e.code not in (0, None):
            sys.stderr.write("job-record: bad arguments\n")
            sys.exit(1)
        raise
    try:
        a.fn(a)
    except Fail as e:
        sys.stderr.write("job-record: %s\n" % e)
        sys.exit(1)
    except Exception as e:  # any other failure: one line, exit 1
        sys.stderr.write("job-record: %s\n" % e)
        sys.exit(1)


if __name__ == "__main__":
    main()
