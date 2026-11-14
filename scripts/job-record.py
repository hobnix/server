#!/usr/bin/env python3
"""Job record writer (ADR docs/adr/0004-job-record.md, issue #131).

One JSON file per job in HS_JOBS_DIR (default /var/lib/hs/jobs), written atomically.
Machine-facing: prints the id or JSON on stdout, one line on stderr and exit 1 on any failure.
Never stores argv or environment, only the description the caller gives.

  new --slug S --desc D --unit U --source cli|web|timer|extension --initiator NAME
  new ... [--parent ID] [--kind orchestration|step]   (ADR 0018: a sub-job names its orchestration, both are optional)
  run ID | wait ID --seq N --key K --label L --kind text|secret|choice [--default D --pattern P --choices a,b --error E --attempt N]
  resume ID   (waiting -> running) | step ID N OF TEXT | progress ID DONE TOTAL UNIT | finish ID EXIT | get ID
  find-unit UNIT | cancel ID --by NAME --safe yes|no | cancelled ID (exit 0 when cancelled)
  error ID --category C --message M   (name why an ended job ended: input_timeout, input_rejected; Python writer only)
  reconcile   mark queued/running/waiting records whose unit is gone as interrupted (boot); never re-runs anything
"""
import argparse
import contextlib
import datetime
import json
import os
import random
import re
import shlex
import string
import subprocess
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
          "state", "exit", "step", "progress", "error", "result", "cancel", "version",
          "parent", "kind", "waiting")   # parent, kind, waiting: ADR 0018, optional and additive
ACTIVE = ("queued", "running", "waiting")
KINDS = ("orchestration", "step")
ASK_KINDS = ("text", "secret", "choice")


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
            try:
                with open(os.path.join(d, n), encoding="utf-8") as f:
                    if json.load(f).get("state") in ACTIVE:
                        continue   # a job that waits for an answer can wait for days: never pruned while active
            except (OSError, ValueError, AttributeError):
                pass
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
    if a.kind and a.kind not in KINDS:
        raise Fail("bad kind: %s" % a.kind)
    if a.parent:
        path_of(a.parent)   # shape check only: the parent may live in another directory state
    rec.update(parent=a.parent or None, kind=a.kind or None)
    save(rec)
    retention()
    sys.stdout.write(job_id + "\n")


def cmd_run(a):
    with locked(a.id):
        rec = load(a.id)
        rec["state"] = "running"
        rec["started"] = now_iso()
        save(rec)


def cmd_wait(a):
    """A question is pending (ADR 0018): state waiting and the question in `waiting`. Never an answer, never a default for a secret."""
    if a.kind not in ASK_KINDS:
        raise Fail("bad question kind: %s" % a.kind)
    with locked(a.id):
        rec = load(a.id)
        if rec.get("state") not in ("running", "waiting"):
            raise Fail("job is not running")
        choices = [c for c in a.choices.split(",") if c] if a.choices else None
        rec["state"] = "waiting"
        rec["waiting"] = {"seq": a.seq, "key": a.key, "label": a.label, "kind": a.kind,
                          "default": None if a.kind == "secret" else (a.default or None),
                          "pattern": a.pattern or None, "choices": choices or None,
                          "error": a.error or None, "attempt": a.attempt, "asked": now_iso()}
        save(rec)


def cmd_resume(a):
    with locked(a.id):
        rec = load(a.id)
        if rec.get("state") != "waiting":
            raise Fail("job is not waiting")
        rec["state"] = "running"
        rec["waiting"] = None
        save(rec)


def bump_records():
    """Count the change counter `reads:jobs-records` up (state-db.py topic-bump, ADR 0005 rule 5): the web interface reads the job list again.
    Best effort like event_emit: not root, no database, a slow one: nothing happens. Called only after the rate limit, so once a second at most."""
    if os.environ.get("HS_JOB_NOBUMP"):
        return
    try:
        subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "state-db.py"), "topic-bump", "reads:jobs-records"],
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
    except (OSError, subprocess.SubprocessError):
        pass


def cmd_step(a):
    if rate_limited(a.id, "step") and a.n != a.of:
        return
    with locked(a.id):
        rec = load(a.id)
        rec["step"] = {"n": a.n, "of": a.of, "text": a.text}
        save(rec)
    touch_stamp(a.id, "step")
    bump_records()


def cmd_progress(a):
    if rate_limited(a.id, "progress") and a.done != a.total:
        return
    with locked(a.id):
        rec = load(a.id)
        rec["progress"] = {"done": a.done, "total": a.total, "unit": a.unit}
        save(rec)
    touch_stamp(a.id, "progress")
    bump_records()


def cmd_finish(a):
    with locked(a.id):
        rec = load(a.id)
        rec["exit"] = a.exit
        rec["waiting"] = None
        if rec.get("state") == "cancelled":   # a cancel stays cancelled; the earlier end time and cancel block stay
            rec["ended"] = rec.get("ended") or now_iso()
        elif a.exit == 0:
            rec["ended"] = now_iso()
            rec["state"] = "ok"
            rec["error"] = None
        else:
            rec["ended"] = now_iso()
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


def cmd_error(a):
    """Name the reason of an ended job (ADR 0018: input_timeout, input_rejected). Only a record that ended; state and exit stay as they are."""
    with locked(a.id):
        rec = load(a.id)
        if rec.get("state") in ACTIVE:
            raise Fail("job has not ended")
        rec["error"] = {"category": a.category, "message": a.message}
        save(rec)


def cmd_find_unit(a):
    """Print the id of the newest queued/running record of a unit (highest id), else exit 1."""
    try:
        names = sorted((n[:-5] for n in os.listdir(jobs_dir()) if n.endswith(".json")), reverse=True)
    except OSError:
        names = []
    for job_id in names:
        try:
            rec = load(job_id)
        except Fail:
            continue
        # hs_job stores the unit without the .service suffix that systemctl and jobs-change.sh use
        if rec.get("unit") in (a.unit, a.unit[:-8] if a.unit.endswith(".service") else a.unit) and rec.get("state") in ACTIVE:
            sys.stdout.write(job_id + "\n")
            return
    raise Fail("no running job record for %s" % a.unit)


def cmd_cancel(a):
    with locked(a.id):
        rec = load(a.id)
        if rec.get("state") not in ACTIVE:
            raise Fail("job already finished")
        at = now_iso()
        rec["state"] = "cancelled"
        rec["waiting"] = None
        rec["ended"] = at
        rec["error"] = None
        rec["cancel"] = {"requested_by": a.by or None, "at": at, "safe": a.safe == "yes"}
        save(rec)


def cmd_uncancel(a):
    """The stop of the unit failed after the record was marked cancelled: the job still runs, so the record says running again."""
    with locked(a.id):
        rec = load(a.id)
        if rec.get("state") != "cancelled" or rec.get("exit") is not None:
            raise Fail("job is not cancelled, or it ended already")
        rec["state"] = "running" if rec.get("started") else "queued"
        rec["ended"] = None
        rec["cancel"] = None
        save(rec)


def cmd_cancelled(a):
    if load(a.id).get("state") != "cancelled":
        sys.exit(1)


def cmd_get(a):
    load(a.id)
    with open(path_of(a.id), encoding="utf-8") as f:
        sys.stdout.write(f.read())


def unit_alive(unit):
    """True when systemd says the unit is active or activating; any other answer (or no systemctl) means it is gone."""
    if not unit:
        return False
    try:
        r = subprocess.run(shlex.split(os.environ.get("HS_SYSTEMCTL") or "systemctl") + ["is-active", unit],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return False
    return r.stdout.decode("utf-8", "replace").strip() in ("active", "activating")


def boot_time():
    """Boot time as a UTC datetime from /proc/uptime (knob HS_UPTIME_FILE), or None when unreadable."""
    try:
        with open(os.environ.get("HS_UPTIME_FILE") or "/proc/uptime") as f:
            up = float(f.read().split()[0])
    except (OSError, ValueError, IndexError):
        return None
    return datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=up)


def parse_iso(s):
    try:
        return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except (TypeError, ValueError):
        return None


def one_line(s):
    return re.sub(r"[\t\r\n]+", " ", str(s if s is not None else "")).strip() or "-"


def cmd_reconcile(a):
    """Mark records whose unit is gone as interrupted (after a restart). Never re-runs anything. Prints id, slug, description per record."""
    d = jobs_dir()
    try:
        names = sorted(n for n in os.listdir(d) if n.endswith(".json"))
    except OSError:
        return
    boot = boot_time()
    bad = False
    for n in names:
        job_id = n[:-5]
        try:
            peek = load(job_id)   # no lock yet, so a finished record leaves no lock file behind
            if peek.get("state") not in ACTIVE:
                continue
            with locked(job_id):
                rec = load(job_id)
                if rec.get("state") not in ACTIVE:
                    continue
                began = parse_iso(rec.get("started") or rec.get("queued"))
                if boot is not None and began is not None and began >= boot:
                    continue   # started after this boot (a job may be between its record and its unit): not a restart victim
                if unit_alive(rec.get("unit")):
                    continue
                if boot is not None and began is not None and began < boot:
                    rec["ended"] = boot.strftime("%Y-%m-%dT%H:%M:%SZ")
                else:
                    rec["ended"] = now_iso()
                rec["state"] = "interrupted"
                rec["waiting"] = None
                rec["exit"] = None
                rec["error"] = {"category": "interrupted",
                                "message": "the job did not finish; the server restarted or the unit stopped"}
                save(rec)
            for kind in ("step", "progress"):
                try:
                    os.unlink(stamp_path(job_id, kind))
                except OSError:
                    pass
            try:
                os.unlink(os.path.join(d, "%s.lock" % job_id))
            except OSError:
                pass
            sys.stdout.write("%s\t%s\t%s\n" % (job_id, one_line(rec.get("slug")), one_line(rec.get("description"))))
        except Fail as e:
            sys.stderr.write("job-record: %s\n" % e)
            bad = True
    if bad:
        sys.exit(1)


def main():
    p = argparse.ArgumentParser(prog="job-record.py")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("new")
    s.add_argument("--slug", required=True)
    s.add_argument("--desc", required=True)
    s.add_argument("--unit", default="")
    s.add_argument("--source", default="cli")
    s.add_argument("--initiator", default="")
    s.add_argument("--parent", default="")
    s.add_argument("--kind", default="")
    s.set_defaults(fn=cmd_new)
    s = sub.add_parser("run"); s.add_argument("id"); s.set_defaults(fn=cmd_run)
    s = sub.add_parser("wait"); s.add_argument("id"); s.add_argument("--seq", type=int, required=True)
    s.add_argument("--key", required=True); s.add_argument("--label", required=True); s.add_argument("--kind", required=True)
    s.add_argument("--default", default=""); s.add_argument("--pattern", default=""); s.add_argument("--choices", default="")
    s.add_argument("--error", default=""); s.add_argument("--attempt", type=int, default=1); s.set_defaults(fn=cmd_wait)
    s = sub.add_parser("resume"); s.add_argument("id"); s.set_defaults(fn=cmd_resume)
    s = sub.add_parser("step"); s.add_argument("id"); s.add_argument("n", type=int)
    s.add_argument("of", type=int); s.add_argument("text"); s.set_defaults(fn=cmd_step)
    s = sub.add_parser("progress"); s.add_argument("id"); s.add_argument("done", type=int)
    s.add_argument("total", type=int); s.add_argument("unit"); s.set_defaults(fn=cmd_progress)
    s = sub.add_parser("finish"); s.add_argument("id"); s.add_argument("exit", type=int); s.set_defaults(fn=cmd_finish)
    s = sub.add_parser("get"); s.add_argument("id"); s.set_defaults(fn=cmd_get)
    s = sub.add_parser("reconcile"); s.set_defaults(fn=cmd_reconcile)
    s = sub.add_parser("error"); s.add_argument("id"); s.add_argument("--category", required=True)
    s.add_argument("--message", default=""); s.set_defaults(fn=cmd_error)
    s = sub.add_parser("find-unit"); s.add_argument("unit"); s.set_defaults(fn=cmd_find_unit)
    s = sub.add_parser("cancel"); s.add_argument("id"); s.add_argument("--by", default="")
    s.add_argument("--safe", choices=("yes", "no"), required=True); s.set_defaults(fn=cmd_cancel)
    s = sub.add_parser("uncancel"); s.add_argument("id"); s.set_defaults(fn=cmd_uncancel)
    s = sub.add_parser("cancelled"); s.add_argument("id"); s.set_defaults(fn=cmd_cancelled)
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
