#!/usr/bin/env python3
"""A test extension that speaks the command protocol v1 (docs/adr/0010). The first word of the request's command picks the behaviour."""
import json
import signal
import sys
import time


def say(**m):
    m.setdefault("v", 1)
    sys.stdout.write(json.dumps(m) + "\n")
    sys.stdout.flush()


if len(sys.argv) > 1 and sys.argv[1] == "noread":
    time.sleep(60)
req = json.loads(sys.stdin.readline())
if req.get("v") != 1:
    say(type="result", ok=False, error={"code": "unsupported_version", "message": "only v1", "supported": [1]})
    sys.exit(1)
cmd = (req["command"] or [""])[0]
if cmd == "echo":
    say(type="progress", fraction=0.5, text="halfway")
    say(type="log", level="info", text="hello")
    say(type="event", kind="pkg.fixproto.said", subject="x")
    say(type="result", ok=True, data={"argv": req["argv"], "lang": req["lang"], "id": req["id"]}, text="done")
elif cmd == "fail":
    say(type="result", ok=False, error={"code": "failed", "message": "it broke"})
    sys.exit(1)
elif cmd == "slow":           # ignores nothing: dies on SIGTERM, so a timeout and a cancel are both quick
    time.sleep(60)
elif cmd == "polite":         # answers a SIGTERM with its own result inside the grace time
    def bye(*_):
        say(type="result", ok=False, error={"code": "cancelled", "message": "stopped by the core"})
        sys.exit(1)
    signal.signal(signal.SIGTERM, bye)
    say(type="progress", text="started")
    time.sleep(60)
elif cmd == "stubborn":       # ignores SIGTERM: only SIGKILL stops it
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    say(type="progress", text="started")
    time.sleep(60)
elif cmd == "garbage":
    sys.stdout.write("not json\n")
elif cmd == "noresult":
    say(type="progress", text="and then nothing")
elif cmd == "after":
    say(type="result", ok=True)
    say(type="log", level="info", text="late")
elif cmd == "badexit":
    say(type="result", ok=True)
    sys.exit(3)
elif cmd == "two":
    say(type="result", ok=True)
    say(type="result", ok=True)
elif cmd == "okexit1":
    say(type="result", ok=True)
    sys.exit(1)
elif cmd == "failexit0":
    say(type="result", ok=False, error={"code": "failed", "message": "x"})
elif cmd == "badfield":
    say(type="event", kind="core.disk", subject="x")
elif cmd == "badcode":
    say(type="result", ok=False, error={"code": "made_up", "message": "x"})
    sys.exit(1)
elif cmd == "partial":
    sys.stdout.write('{"v":1,"type":"prog')
    sys.stdout.flush()
elif cmd == "noread":         # never reads a large request: neither a timeout nor a cancel may block on it
    time.sleep(60)
elif cmd == "linger":         # answers, then does not exit
    say(type="result", ok=True)
    time.sleep(60)
elif cmd == "huge":
    sys.stdout.write("x" * (2 << 20))
    sys.stdout.flush()
    time.sleep(5)
else:
    say(type="result", ok=False, error={"code": "not_found", "message": "no such command"})
    sys.exit(1)
