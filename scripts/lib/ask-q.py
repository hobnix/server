#!/usr/bin/env python3
"""The file side of the question and answer protocol (docs/PLAN-recipe-orchestrator.md, ADR 0018 rules 5 to 8).

A directory per orchestration, HS_ASK_DIR = <run dir>/ask/<orchestration id> (root, 0700, tmpfs):
  q/<seq>.json   a question (written atomically by the step that asks)
  a/<seq>        the answer: ONE line, 0600, written by `jobs answer`, read once and deleted by the step

  ask-q.py write DIR KEY KIND LABEL DEFAULT PATTERN CHOICES ERROR ATTEMPT JOBID   claim the next seq, write q/<seq>.json, print seq
  ask-q.py pending DIR      the oldest unanswered question as NUL separated fields:
                            seq key kind label default pattern choices error attempt jobid; nothing when there is none
  ask-q.py accept DIR SEQ KEY   the answer is ONE line on STANDARD INPUT (never argv); checks seq and key are a pending question, the shape
                            and a choice, writes a/<seq>. Exit 0 = stored, 3 = stale (no such pending question), 4 = refused (shape)
  ask-q.py take DIR SEQ     print the answer of a/<seq> (one line), delete the file and q/<seq>.json; exit 1 when there is none yet
  ask-q.py drop DIR SEQ     remove q/<seq>.json and a/<seq> (the step gave up)

The answer value is never printed except by `take`, never logged, never part of an error message."""
import json
import os
import sys
import tempfile


def die(code, msg=""):
    if msg:
        sys.stderr.write(msg + "\n")
    sys.exit(code)


def qdir(d):
    return os.path.join(d, "q")


def adir(d):
    return os.path.join(d, "a")


def ensure(d):
    for sub in (d, qdir(d), adir(d)):
        os.makedirs(sub, mode=0o700, exist_ok=True)


def seqs(d):
    out = []
    try:
        for n in os.listdir(qdir(d)):
            if n.endswith(".json") and n[:-5].isdigit():
                out.append(int(n[:-5]))
    except OSError:
        pass
    return sorted(out)


def load_q(d, seq):
    try:
        with open(os.path.join(qdir(d), "%d.json" % seq), encoding="utf-8") as f:
            q = json.load(f)
        return q if isinstance(q, dict) else None
    except (OSError, ValueError):
        return None


def cmd_write(d, key, kind, label, default, pattern, choices, error, attempt, jobid):
    if kind not in ("text", "secret", "choice"):
        die(2, "bad kind")
    ensure(d)
    existing = [int(n.split(".")[0]) for n in os.listdir(qdir(d)) if n.split(".")[0].isdigit()]
    n = max(existing or [0]) + 1
    while True:   # claim the number with an exclusive create: two steps asking at once get two numbers
        try:
            fd = os.open(os.path.join(qdir(d), "%d.claim" % n), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.close(fd)
            break
        except FileExistsError:
            n += 1
    q = {"v": 1, "seq": n, "id": jobid, "key": key, "label": label, "kind": kind,
         "default": None if kind == "secret" else (default or None), "pattern": pattern or None,
         "choices": [c for c in choices.split(",") if c] or None, "error": error or None, "attempt": int(attempt or 1)}
    fd, tmp = tempfile.mkstemp(prefix=".q", dir=qdir(d))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(q, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, os.path.join(qdir(d), "%d.json" % n))
    print(n)


def pending(d):
    for s in seqs(d):
        if os.path.exists(os.path.join(adir(d), str(s))):
            continue   # answered, the step has not picked it up yet
        q = load_q(d, s)
        if not q:
            continue
        f = lambda k: "" if q.get(k) is None else str(q[k]).replace("\x00", "")   # noqa: E731
        fields = [str(s), f("key"), f("kind"), f("label"), f("default"), f("pattern"), ",".join(q.get("choices") or []),
                  f("error"), f("attempt"), f("id")]
        sys.stdout.write("\x00".join(fields) + "\x00")
        return


def cmd_accept(d, seq, key):
    if not seq.isdigit():
        die(3, "stale")
    data = sys.stdin.buffer.read(4097)
    line = data.split(b"\n", 1)[0].rstrip(b"\r")
    try:
        value = line.decode("utf-8")
    except UnicodeDecodeError:
        die(4, "the answer is not text")
    if len(data) > 4096 or any(ord(c) < 32 or ord(c) == 127 for c in value):
        die(4, "the answer has a control character or is too long")
    s = int(seq)
    q = load_q(d, s)
    a = os.path.join(adir(d), str(s))
    if q is None or q.get("key") != key or os.path.exists(a):
        die(3, "stale")   # not the question that waits (any more), or answered already: harmless
    if q.get("kind") == "choice" and value not in (q.get("choices") or []):
        die(4, "not one of the choices")
    if q.get("kind") == "secret" and not value:
        die(4, "a secret cannot be empty")
    os.makedirs(adir(d), mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".a", dir=adir(d))
    os.chmod(tmp, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(value + "\n")
    try:
        os.link(tmp, a)   # exclusive: a double submit loses here, not by overwriting
    except FileExistsError:
        os.unlink(tmp)
        die(3, "stale")
    os.unlink(tmp)


def cmd_take(d, seq):
    a = os.path.join(adir(d), seq)
    try:
        with open(a, encoding="utf-8") as f:
            line = f.readline().rstrip("\n")
    except OSError:
        sys.exit(1)
    for p in (a, os.path.join(qdir(d), seq + ".json")):   # the .claim stays: a number is never used twice, so an old page cannot answer a new question
        try:
            os.unlink(p)
        except OSError:
            pass
    sys.stdout.write(line)


def cmd_drop(d, seq):
    for p in (os.path.join(adir(d), seq), os.path.join(qdir(d), seq + ".json")):
        try:
            os.unlink(p)
        except OSError:
            pass


def main(argv):
    if len(argv) < 3:
        die(2, "usage: ask-q.py write|pending|accept|take|drop DIR ...")
    cmd, d, rest = argv[1], argv[2], argv[3:]
    if cmd == "write" and len(rest) == 9:
        cmd_write(d, *rest)
    elif cmd == "pending" and not rest:
        pending(d)
    elif cmd == "accept" and len(rest) == 2:
        cmd_accept(d, *rest)
    elif cmd == "take" and len(rest) == 1 and rest[0].isdigit():
        cmd_take(d, rest[0])
    elif cmd == "drop" and len(rest) == 1 and rest[0].isdigit():
        cmd_drop(d, rest[0])
    else:
        die(2, "usage: ask-q.py write|pending|accept|take|drop DIR ...")


if __name__ == "__main__":
    main(sys.argv)
