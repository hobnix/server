#!/usr/bin/env python3
"""Reference supervisor of ONE service extension, protocol version 1 (docs/adr/0010-extension-service-lifecycle.md). Python stdlib only.

It is the bridge a unit would run (`hs ext svc-run <name>`, not built yet): start the service process, send `init`, wait for `ready`,
deliver the events the service subscribed to from the event log with at-least-once acks and a cursor file, watch the heartbeat, and stop the
service (shutdown message, SIGTERM to the process group, SIGKILL). Restarting after a crash is NOT done here: the unit does it (systemd Restart=).

  ext_service.py run --name N [--subscribe GLOB]... [--events FILE] [--cursor FILE] [--ready-timeout S] [--health-interval S]
                     [--missed N] [--grace S] [--run-for S] -- PROGRAM [ARG...]
     --events FILE   a JSON Lines file of event-log rows (id, time, source, kind, subject, level, text, payload): the stand-in for the log
     --run-for S     stop after S seconds (a test knob); otherwise SIGTERM/SIGINT stops it
  Output: every state change as {"v":1,"type":"state","state":...} and every message the service sent (`log`, `emit`, `snapshot`), then one
  {"type":"final",...}. Exit code: 0 stopped on request, 1 the service exited or broke the protocol, 75 it never became ready.

Schema of the messages: docs/api/ext-service-v1.schema.json.
"""
import argparse
import fnmatch
import json
import os
import queue
import re
import signal
import subprocess
import sys
import threading
import time

VERSION = 1
MAX_LINE = 1 << 20
WINDOW = 100                    # events sent but not yet acknowledged, at most
KIND = re.compile(r"^pkg\.[a-z][a-z0-9-]*\.[a-z][a-z0-9-]*$")
STATES = ("starting", "running", "degraded", "stopping", "stopped", "failed")
FROM_SERVICE = ("ready", "health", "ack", "log", "emit", "snapshot")


def check_message(m):
    """None when m is a valid message from the service, else the reason."""
    if not isinstance(m, dict) or m.get("v") != VERSION:
        return f"a message is a JSON object with v {VERSION}"
    t = m.get("type")
    if t not in FROM_SERVICE:
        return f"unknown type {t!r}"
    if t == "health" and (not isinstance(m.get("ok"), bool) or not isinstance(m.get("text", ""), str)):
        return "health needs ok (boolean)"
    if t == "ack" and (isinstance(m.get("id"), bool) or not isinstance(m.get("id"), int) or m["id"] < 1):
        return "ack needs id (a positive integer)"
    if t == "log" and (m.get("level") not in ("debug", "info", "warn", "error") or not isinstance(m.get("text"), str)):
        return "log needs level and text"
    if t == "emit" and (not isinstance(m.get("kind"), str) or not KIND.match(m["kind"]) or not isinstance(m.get("subject"), str)):
        return "emit needs kind (pkg.<package>.<what>) and subject"
    if t == "snapshot" and (not isinstance(m.get("topic"), str) or not re.match(r"^[a-z0-9-]{1,60}$", m["topic"]) or "data" not in m):
        return "snapshot needs topic (a-z, 0-9, -) and data"
    return None


def read_cursor(path):
    try:
        return max(0, int(open(path).read().strip() or 0))
    except (OSError, ValueError):
        return 0


def write_cursor(path, n):
    tmp = f"{path}.tmp"
    with open(tmp, "w") as f:
        f.write(f"{n}\n")
    os.replace(tmp, path)


def file_events(path):
    """The stand-in event log: fetch(after, limit) -> rows with id > after, oldest first."""
    def fetch(after, limit):
        rows = []
        try:
            for line in open(path):
                if line.strip():
                    r = json.loads(line)
                    if r["id"] > after:
                        rows.append(r)
        except OSError:
            pass
        rows.sort(key=lambda r: r["id"])
        return rows[:limit]
    return fetch


def supervise(prog, name, subscribe=(), fetch=None, cursor_file=None, ready_timeout=30.0, health_interval=30.0, missed=3,
              grace=10.0, stop=None, on_state=None, on_message=None, lang="en"):
    """Run the service until `stop` is set or it ends. Returns {"state", "code", "reason", "exit"}."""
    stop = stop or threading.Event()
    state = {"v": None}

    def set_state(s, why=""):
        if state["v"] != s:
            state["v"] = s
            if on_state:
                on_state(s, why)
    set_state("starting")
    try:
        proc = subprocess.Popen(prog, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError as e:
        set_state("failed", str(e))
        return {"state": "failed", "code": "spawn_failed", "reason": str(e), "exit": None}
    lines = queue.Queue()

    def reader():
        for raw in proc.stdout:
            lines.put(raw)
            if len(raw) > MAX_LINE:
                break
        lines.put(None)
    threading.Thread(target=reader, daemon=True).start()

    def send(m):
        try:
            proc.stdin.write((json.dumps({"v": VERSION, **m}, separators=(",", ":")) + "\n").encode())
            proc.stdin.flush()
        except (BrokenPipeError, OSError, ValueError):
            pass
    send({"type": "init", "name": name, "lang": lang, "subscribe": list(subscribe), "health_interval": health_interval})

    cursor = read_cursor(cursor_file) if cursor_file else 0
    sent = cursor              # the highest id sent
    inflight = []              # ids sent and not yet acked, ascending
    acked = set()
    ready = False
    t0 = time.monotonic()
    last_health = t0
    result = None
    while result is None:
        if stop.is_set():
            result = ("stopped", "stopped", "stopped on request")
            break
        try:
            raw = lines.get(timeout=0.05)
        except queue.Empty:
            raw = b""
        now = time.monotonic()
        if raw is None:
            result = ("failed", "exited", f"the service ended (exit {proc.poll()})")
            break
        if raw.strip():
            try:
                m = json.loads(raw)
            except ValueError:
                m = None
            why = check_message(m) if m is not None else "stdout line is not JSON"
            if why:
                result = ("failed", "protocol_error", why)
                break
            t = m["type"]
            if t == "ready":
                if not ready:
                    ready = True
                    last_health = now
                    set_state("running")
            elif not ready:
                result = ("failed", "protocol_error", f"{t} before ready")
                break
            elif t == "health":
                last_health = now
                set_state("running" if m["ok"] else "degraded", m.get("text", ""))
            elif t == "ack":
                if m["id"] in inflight:
                    acked.add(m["id"])
                    while inflight and inflight[0] in acked:
                        cursor = inflight.pop(0)
                        acked.discard(cursor)
                        if cursor_file:
                            write_cursor(cursor_file, cursor)
                else:
                    result = ("failed", "protocol_error", f"ack of {m['id']}, which was not sent")
                    break
            elif on_message:
                on_message(m)
        if not ready:
            if now - t0 > ready_timeout:
                result = ("failed", "start_timeout", f"no ready within {ready_timeout:g} s")
            continue
        if now - last_health > health_interval * missed:
            set_state("degraded", "heartbeat missed")
        if subscribe and fetch and len(inflight) < WINDOW:
            for r in fetch(sent, WINDOW - len(inflight)):
                sent = r["id"]
                if any(fnmatch.fnmatchcase(f"{r['source']}.{r['kind']}", g) for g in subscribe):
                    inflight.append(r["id"])
                    send({"type": "event", **{k: r.get(k) for k in ("id", "time", "source", "kind", "subject", "level", "text", "payload")}})
        if not inflight and sent > cursor:   # everything up to `sent` was acknowledged or not wanted: the cursor moves
            cursor = sent
            if cursor_file:
                write_cursor(cursor_file, cursor)
    final_state, code, reason = result
    if final_state == "stopped":
        set_state("stopping")
        send({"type": "shutdown", "grace_ms": int(grace * 1000)})
        try:
            proc.stdin.close()
        except OSError:
            pass
        try:
            proc.wait(timeout=grace)       # the service ends by itself after `shutdown`
        except subprocess.TimeoutExpired:
            pass
    for sig, wait in ((signal.SIGTERM, 2.0), (signal.SIGKILL, 0)):   # a service still alive gets SIGTERM, then SIGKILL, as a command (ADR 0009)
        if proc.poll() is not None:
            break
        try:
            os.killpg(proc.pid, sig)
        except (ProcessLookupError, PermissionError):
            pass
        if wait:
            try:
                proc.wait(timeout=wait)
            except subprocess.TimeoutExpired:
                pass
    try:
        os.killpg(proc.pid, signal.SIGKILL)    # children of the service
    except (ProcessLookupError, PermissionError):
        pass
    proc.wait()
    set_state(final_state, reason)
    return {"state": final_state, "code": code, "reason": reason, "exit": proc.returncode}


def main(argv):
    ap = argparse.ArgumentParser(prog="ext_service.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--name", required=True)
    r.add_argument("--subscribe", action="append", default=[])
    r.add_argument("--events")
    r.add_argument("--cursor")
    r.add_argument("--ready-timeout", type=float, default=30)
    r.add_argument("--health-interval", type=float, default=30)
    r.add_argument("--missed", type=int, default=3)
    r.add_argument("--grace", type=float, default=10)
    r.add_argument("--run-for", type=float)
    r.add_argument("prog", nargs=argparse.REMAINDER)
    a = ap.parse_args(argv)
    prog = a.prog[1:] if a.prog[:1] == ["--"] else a.prog
    if not prog or not re.match(r"^[a-z][a-z0-9-]{0,40}$", a.name):
        print("usage: ext_service.py run --name N [options] -- PROGRAM [ARG...]", file=sys.stderr)
        return 2
    stop = threading.Event()
    for s in (signal.SIGTERM, signal.SIGINT):
        signal.signal(s, lambda *_: stop.set())
    if a.run_for:
        tm = threading.Timer(a.run_for, stop.set)
        tm.daemon = True
        tm.start()

    def out(o):
        sys.stdout.write(json.dumps(o, separators=(",", ":")) + "\n")
        sys.stdout.flush()
    res = supervise(prog, a.name, a.subscribe, file_events(a.events) if a.events else None, a.cursor, a.ready_timeout,
                    a.health_interval, a.missed, a.grace, stop,
                    on_state=lambda s, why: out({"v": VERSION, "type": "state", "state": s, "reason": why}),
                    on_message=out)
    out({"v": VERSION, "type": "final", **res})
    return 0 if res["state"] == "stopped" else 75 if res["code"] == "start_timeout" else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
