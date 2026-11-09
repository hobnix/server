#!/usr/bin/env python3
"""List the job records (ADR 0004), newest first, as tab-separated lines (the machine-readable contract: empty field is "-").

usage: job-records.py [--state <state>] [--parent <id>] [<limit>]     (--parent: the sub-jobs of one orchestration, oldest first)     (limit default 50, at most 500)

Reads HS_JOBS_DIR (default /var/lib/hs/jobs) read-only; a file that is not a valid record is skipped.
Columns: id, slug, description, state, queued, started, ended, exit, step_n, step_of, step_text,
progress_done, progress_total, progress_unit.
"""
import json
import os
import re
import sys

ID = re.compile(r"[0-9]{8}-[0-9]{6}-[A-Za-z0-9-]+-[a-z]{4}")


def cell(v):
    if v is None:
        return "-"
    s = re.sub(r"[\t\r\n]+", " ", str(v)).strip()
    return s or "-"


def main():
    args = sys.argv[1:]
    state = ""
    parent = None
    limit = 50
    while args:
        a = args.pop(0)
        if a == "--state" and args:
            state = args.pop(0)
        elif a == "--parent" and args:
            parent = args.pop(0)
        elif a.isdigit():
            limit = min(int(a), 500)
        else:
            sys.stderr.write("job-records: bad arguments\n")
            return 1
    d = os.environ.get("HS_JOBS_DIR") or "/var/lib/hs/jobs"
    try:
        names = sorted((n[:-5] for n in os.listdir(d) if n.endswith(".json")), reverse=True)
    except OSError:
        return 0   # no directory yet: no jobs
    if parent is not None:
        if not ID.fullmatch(parent):
            sys.stderr.write("job-records: bad job id\n")
            return 1
        names.reverse()   # steps in the order they started
    shown = 0
    for jid in names:
        if shown >= limit:
            break
        if not ID.fullmatch(jid):
            continue
        try:
            with open(os.path.join(d, jid + ".json"), encoding="utf-8") as f:
                r = json.load(f)
        except (OSError, ValueError):
            continue
        if not isinstance(r, dict) or (state and r.get("state") != state) \
                or (parent is not None and r.get("parent") != parent):
            continue
        step = r.get("step") if isinstance(r.get("step"), dict) else {}
        prog = r.get("progress") if isinstance(r.get("progress"), dict) else {}
        row = [jid, r.get("slug"), r.get("description"), r.get("state"), r.get("queued"), r.get("started"),
               r.get("ended"), r.get("exit"), step.get("n"), step.get("of"), step.get("text"),
               prog.get("done"), prog.get("total"), prog.get("unit")]
        sys.stdout.write("\t".join(cell(c) for c in row) + "\n")
        shown += 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
