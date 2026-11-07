#!/usr/bin/env python3
"""A test service extension (docs/adr/0011). argv[1] picks the behaviour; every message of the core is appended to $SVC_LOG."""
import json
import os
import queue
import signal
import sys
import threading
import time

mode = sys.argv[1]
log = open(os.environ["SVC_LOG"], "a")


def say(**m):
    m.setdefault("v", 1)
    sys.stdout.write(json.dumps(m) + "\n")
    sys.stdout.flush()


init = json.loads(sys.stdin.readline())
log.write(json.dumps(init) + "\n"); log.flush()
if mode == "slowready":
    time.sleep(60)
if mode == "stubborn":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
if mode == "garbagefirst":
    sys.stdout.write("junk\n"); sys.stdout.flush()
    time.sleep(60)
if mode == "earlyack":
    say(type="log", level="info", text="before ready")
    time.sleep(60)
say(type="ready")
if mode == "crash":
    time.sleep(0.3)
    sys.exit(3)
if mode == "badmsg":
    time.sleep(0.3)
    sys.stdout.write("garbage\n"); sys.stdout.flush()
    time.sleep(60)
if mode == "longline":
    sys.stdout.write("x" * (2 << 20)); sys.stdout.flush()
    time.sleep(60)
if mode == "deaf":           # stops reading stdin while events pile up
    time.sleep(60)
if mode == "ackbad":
    say(type="ack", id=99)
    time.sleep(60)
if mode == "emit":
    say(type="emit", kind="pkg.fixsvc.seen", subject="x")
    say(type="snapshot", topic="state", data={"n": 1})
last = 0
inbox = queue.Queue()
threading.Thread(target=lambda: [inbox.put(l) for l in sys.stdin] + [inbox.put(None)], daemon=True).start()
while True:
    try:
        line = inbox.get(timeout=0.2)
    except queue.Empty:
        line = ""
    if line is None:
        sys.exit(0)                 # stdin closed: the core is gone
    if line:
        m = json.loads(line)
        log.write(json.dumps(m) + "\n"); log.flush()
        if m["type"] == "shutdown":
            if mode == "stubborn":
                continue
            say(type="log", level="info", text="bye")
            sys.exit(0)
        if m["type"] == "event" and mode != "noack":
            say(type="ack", id=m["id"])
    if mode == "unhealthy":
        say(type="health", ok=False, text="disk full")
    elif mode not in ("silent", "noack_silent"):
        if time.time() - last > 0.2:
            say(type="health", ok=True)
            last = time.time()
