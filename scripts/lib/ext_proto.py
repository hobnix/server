#!/usr/bin/env python3
"""Reference runner of the command-extension protocol, version 1 (docs/adr/0010-extension-command-protocol.md). Python stdlib only.

The core side of one call: start the extension process, send ONE request line on its stdin, read JSON lines from its stdout until the
`result` line, enforce the timeout and the cancellation rules, and map the outcome to an exit code. It is NOT wired into `hs ext` yet
(see the ADR, "Open points"); the format is what is fixed here, with tests/ext-proto.sh as proof.

  ext_proto.py call [--timeout SECONDS] [--grace SECONDS] [--command WORD]... [--lang en|de] [--caller cli|web|boot] -- PROGRAM [ARG...]
      The words after --command are the command words of the request; the arguments after `--` that the program is started with are
      its argv. The request's `argv` is set with --arg VALUE (repeatable). Progress and log lines are copied to stdout as they come,
      then ONE final line {"v":1,"type":"outcome",...} says what the core makes of the call. Exit code: 0 ok, 1 the extension
      answered ok=false, 124 timeout, 130 cancelled (SIGTERM or SIGINT to this runner), 70 protocol error, 69 the program did not start.

Schema of the messages: docs/api/ext-protocol-v1.schema.json. Knobs for tests: none (every limit is an option or a constant below).
"""
import argparse
import json
import os
import re
import selectors
import signal
import subprocess
import sys
import threading
import time
import uuid

VERSION = 1
MAX_REQUEST = 1 << 20          # bytes of the request line
MAX_LINE = 1 << 20             # bytes of one output line
MAX_TOTAL = 16 << 20           # bytes of all stdout
MAX_STDERR = 64 << 10          # bytes of stderr kept (the rest is read and dropped)
DEFAULT_TIMEOUT = 30           # seconds
MAX_TIMEOUT = 3600
DEFAULT_GRACE = 5              # seconds between SIGTERM and SIGKILL
TYPES = ("progress", "log", "event", "result")
LEVELS = ("debug", "info", "warn", "error")
ERROR_CODES = ("failed", "not_found", "bad_request", "unsupported_version", "cancelled", "timeout", "protocol_error")
WORD = re.compile(r"^[a-z0-9][a-z0-9-]*$")
KIND = re.compile(r"^pkg\.[a-z][a-z0-9-]*\.[a-z][a-z0-9-]*$")
EXIT = {"ok": 0, "failed": 1, "timeout": 124, "cancelled": 130, "protocol_error": 70, "spawn_failed": 69}


def make_request(command, argv, lang="en", caller="cli", timeout=DEFAULT_TIMEOUT):
    command = list(command)
    if not command or not all(WORD.match(w) for w in command):
        raise ValueError("command needs at least one word of a-z, 0-9 and -")
    if lang not in ("en", "de") or caller not in ("cli", "web", "boot"):
        raise ValueError("lang is en|de, caller is cli|web|boot")
    timeout = max(1, min(float(timeout), MAX_TIMEOUT))
    return {"v": VERSION, "type": "request", "id": uuid.uuid4().hex[:16], "command": command, "argv": [str(a) for a in argv],
            "lang": lang, "caller": caller, "timeout_ms": int(timeout * 1000)}


def check_message(m):
    """None when the stdout line is a valid message of version 1, else the reason."""
    if not isinstance(m, dict):
        return "a message is a JSON object"
    if m.get("v") != VERSION:
        return f"v must be {VERSION}"
    t = m.get("type")
    if t not in TYPES:
        return f"unknown type {t!r}"
    if t == "progress":
        f = m.get("fraction")
        if f is not None and (isinstance(f, bool) or not isinstance(f, (int, float)) or not 0 <= f <= 1):
            return "progress.fraction is a number from 0 to 1"
        if not isinstance(m.get("text", ""), str) or len(m.get("text", "")) > 200:
            return "progress.text is a string of at most 200 characters"
    elif t == "log":
        if m.get("level") not in LEVELS or not isinstance(m.get("text"), str) or len(m["text"]) > 1000:
            return "log needs level (debug|info|warn|error) and text of at most 1000 characters"
    elif t == "event":
        if not isinstance(m.get("kind"), str) or not KIND.match(m["kind"]) or not isinstance(m.get("subject"), str):
            return "event needs kind (pkg.<package>.<what>) and subject (a string)"
        if "level" in m and m["level"] not in ("info", "warn", "error"):
            return "event.level is info|warn|error"
        if "payload" in m and not isinstance(m["payload"], dict):
            return "event.payload is an object"
        if "text" in m and not isinstance(m["text"], str):
            return "event.text is a string"
    elif t == "result":
        if not isinstance(m.get("ok"), bool):
            return "result.ok is a boolean"
        if not m["ok"]:
            e = m.get("error")
            if not isinstance(e, dict) or e.get("code") not in ERROR_CODES or not isinstance(e.get("message"), str):
                return "result with ok=false needs error.code (a known code) and error.message"
        elif "error" in m:
            return "result with ok=true has no error"
    return None


def _stop(proc, grace):
    """SIGTERM to the process group, SIGKILL after the grace time. Returns once the process is gone."""
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        proc.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        pass
    try:   # the group may still hold children of the extension: SIGKILL it either way
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    proc.wait()


def run(argv_prog, request, timeout=DEFAULT_TIMEOUT, grace=DEFAULT_GRACE, on_message=None, cancel=None):
    """Run one call. `cancel` is a threading.Event; when set the extension is stopped like on SIGTERM. Returns the outcome dict:
    {"ok": bool, "code": ok|failed|timeout|cancelled|protocol_error|spawn_failed, "result": the result message or None,
    "messages": [progress/log/event messages], "stderr": str, "exit": the process exit status or None, "reason": str}."""
    timeout = max(1, min(float(timeout), MAX_TIMEOUT))
    cancel = cancel or threading.Event()
    out = {"ok": False, "code": "protocol_error", "result": None, "messages": [], "stderr": "", "exit": None, "reason": ""}
    line = json.dumps(request, separators=(",", ":")).encode() + b"\n"
    if len(line) > MAX_REQUEST:
        out["reason"] = "request too large"
        return out
    try:
        proc = subprocess.Popen(argv_prog, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                start_new_session=True)
    except OSError as e:
        out.update(code="spawn_failed", reason=str(e))
        return out
    err = bytearray()

    def drain():
        while True:
            b = proc.stderr.read(4096)
            if not b:
                return
            if len(err) < MAX_STDERR:
                err.extend(b[:MAX_STDERR - len(err)])
    th = threading.Thread(target=drain, daemon=True)
    th.start()
    def feed():   # in a thread: an extension that never reads a large request must not block the timeout or a cancel
        try:
            proc.stdin.write(line)
            proc.stdin.close()
        except (BrokenPipeError, OSError, ValueError):
            pass   # the extension did not read its request; the missing result is reported below
    threading.Thread(target=feed, daemon=True).start()

    try:
        deadline = time.monotonic() + timeout
        sel = selectors.DefaultSelector()
        sel.register(proc.stdout, selectors.EVENT_READ)
        fd = proc.stdout.fileno()
        buf = b""
        total = 0
        final = None            # the reason the core stopped the process: timeout | cancelled | protocol_error
        eof = False
        while not eof and final is None:
            if cancel.is_set():
                final = "cancelled"
                break
            left = deadline - time.monotonic()
            if left <= 0:
                final = "timeout"
                break
            if not sel.select(min(left, 0.1)):
                continue
            chunk = os.read(fd, 65536)
            if not chunk:
                eof = True
                break
            total += len(chunk)
            buf += chunk
            if total > MAX_TOTAL or (b"\n" not in buf and len(buf) > MAX_LINE):
                out["reason"] = "output too large"
                final = "protocol_error"
                break
            while b"\n" in buf and final is None:
                raw, buf = buf.split(b"\n", 1)
                if not raw.strip():
                    continue
                if len(raw) > MAX_LINE:
                    out["reason"], final = "line too long", "protocol_error"
                    break
                if out["result"] is not None:
                    out["reason"], final = "output after the result", "protocol_error"
                    break
                try:
                    m = json.loads(raw)
                except ValueError:
                    out["reason"], final = "stdout line is not JSON", "protocol_error"
                    break
                why = check_message(m)
                if why:
                    out["reason"], final = why, "protocol_error"
                    break
                if m["type"] == "result":
                    out["result"] = m
                else:
                    out["messages"].append(m)
                    if on_message:
                        try:
                            on_message(m)
                        except Exception:   # a reader that went away must not abort the call
                            on_message = None
        if final is None and buf.strip():
            try:
                m = json.loads(buf)
                why = check_message(m)
                if why or m["type"] != "result" or out["result"] is not None:
                    out["reason"], final = why or "line without newline", "protocol_error"
                else:
                    out["result"] = m
            except ValueError:
                out["reason"], final = "stdout ends in a partial line", "protocol_error"
        if final is not None:
            _stop(proc, grace)
            if final in ("timeout", "cancelled") and out["result"] is None:   # an answer written inside the grace time is kept for the report
                for raw in (buf + proc.stdout.read(MAX_LINE)).splitlines():
                    try:
                        m = json.loads(raw)
                    except ValueError:
                        continue
                    if check_message(m) is None and m["type"] == "result":
                        out["result"] = m
                        break
        else:
            while proc.poll() is None and final is None:   # the result is in or stdout is closed: wait, but stay cancellable
                if cancel.is_set():
                    final = "cancelled"
                elif time.monotonic() >= deadline:
                    final = "timeout"
                else:
                    time.sleep(0.05)
            if final:
                _stop(proc, grace)
    finally:
        if proc.poll() is None:   # an error above must not leave the extension running
            _stop(proc, 0)
    th.join(timeout=2)
    out["exit"] = proc.returncode
    out["stderr"] = err.decode("utf-8", "replace")
    res = out["result"]
    if final in ("timeout", "cancelled"):
        out.update(code=final, reason=f"stopped: {final}")
    elif final == "protocol_error":
        out["code"] = "protocol_error"
    elif res is None:
        out.update(code="protocol_error", reason=out["reason"] or "no result line before the process ended")
    elif res["ok"] and proc.returncode == 0:
        out.update(ok=True, code="ok", reason="")
    elif not res["ok"] and proc.returncode == 1:
        out.update(code="failed", reason=res["error"]["message"])
    else:
        out.update(code="protocol_error", reason=f"result ok={res['ok']} but exit status {proc.returncode}")
    return out


def main(argv):
    ap = argparse.ArgumentParser(prog="ext_proto.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("call")
    c.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT)
    c.add_argument("--grace", type=float, default=DEFAULT_GRACE)
    c.add_argument("--command", action="append", default=[])
    c.add_argument("--arg", action="append", default=[])
    c.add_argument("--lang", default="en")
    c.add_argument("--caller", default="cli")
    c.add_argument("prog", nargs=argparse.REMAINDER)
    a = ap.parse_args(argv)
    prog = a.prog[1:] if a.prog[:1] == ["--"] else a.prog
    if not prog:
        print("usage: ext_proto.py call [options] -- PROGRAM [ARG...]", file=sys.stderr)
        return 2
    cancel = threading.Event()
    for s in (signal.SIGTERM, signal.SIGINT):
        signal.signal(s, lambda *_: cancel.set())
    try:
        req = make_request(a.command, a.arg, a.lang, a.caller, a.timeout)
    except ValueError as e:
        print(f"ext_proto.py: {e}", file=sys.stderr)
        return 2

    def show(m):
        sys.stdout.write(json.dumps(m, separators=(",", ":")) + "\n")
        sys.stdout.flush()
    o = run(prog, req, a.timeout, a.grace, show, cancel)
    show({"v": VERSION, "type": "outcome", "ok": o["ok"], "code": o["code"], "reason": o["reason"], "exit": o["exit"],
          "result": o["result"], "stderr": o["stderr"]})
    return EXIT[o["code"]]


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
