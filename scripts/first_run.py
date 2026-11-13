#!/usr/bin/env python3
"""First-run state and the one-time console token of the web setup (docs/adr/0022-first-run-console-token.md, issue #183).

Used by web-serve.py (`POST /api/setup`, the `setup` part of `GET /api/hello`) and on the console:

  first_run.py issue    make a NEW token (the old one stops working), print it once between two marker lines; this is what a boot unit runs
  first_run.py status   one line: none | pending <seconds left> | expired | done <user>
  first_run.py reset    forget the flag (root on the console: the next `issue` starts a setup again)
  first_run.py wizard   one line: open | done | none (is the web wizard after the password still to be shown)
  first_run.py wizard-done   close the wizard (idempotent)

The file ($HS_STATE_DIR/first-run.json, mode 0600, written atomically) holds only the sha256 of the token, never the token. No file means
"not a first-run server": an upgraded server never shows the setup. Standard library only; the clock and the random source are
parameters so the tests need no sleeping and no real randomness.
"""
import hashlib
import json
import os
import secrets
import sys
import tempfile
import threading
import time

ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"        # no 0 O 1 I: the token is read from a screen and typed
GROUPS, GROUP_LEN = 4, 5                              # 20 characters of 32 = 100 bits
TTL = 3600                                            # seconds a token lives
MAX_FAILS = 5                                         # wrong tokens before the token is burned (a new one must be issued on the console)
MIN_PASSWORD = 10

# results of redeem()
OK, BAD, EXPIRED, BURNED, DONE, NONE, FAILED = "ok", "bad", "expired", "burned", "done", "none", "failed"


def new_token(rng=secrets):
    return "-".join("".join(rng.choice(ALPHABET) for _ in range(GROUP_LEN)) for _ in range(GROUPS))


def normalize(token):
    """What a person types: any case, with or without dashes and spaces. None when it cannot be a token."""
    if not isinstance(token, str) or len(token) > 64:
        return None
    t = "".join(c for c in token.upper() if c not in "- \t")
    return t if len(t) == GROUPS * GROUP_LEN and all(c in ALPHABET for c in t) else None


def _hash(t):
    return hashlib.sha256(("hs-first-run:" + t).encode()).hexdigest()


def password_problem(password):
    """None when the password may be set, else the sentence to show."""
    if not isinstance(password, str) or len(password) < MIN_PASSWORD:
        return "The password needs at least %d characters." % MIN_PASSWORD
    if len(password) > 256 or any(ord(c) < 32 or ord(c) == 127 for c in password):
        return "The password may be up to 256 characters, on one line."
    return None


class FirstRun:
    def __init__(self, path, ttl=TTL, max_fails=MAX_FAILS, clock=time.time, rng=secrets):
        self.path, self.ttl, self.max_fails, self.clock, self.rng = path, ttl, max_fails, clock, rng
        self.lock = threading.Lock()

    # --- file
    def _read(self):
        if not self.path:
            return None
        try:
            with open(self.path) as f:
                d = json.load(f)
            return d if isinstance(d, dict) and d.get("state") in ("pending", "done") else None
        except (OSError, ValueError):
            return None

    def _write(self, d):
        folder = os.path.dirname(self.path) or "."
        fd, tmp = tempfile.mkstemp(dir=folder, prefix=".first-run-")
        try:
            with os.fdopen(fd, "w") as f:
                json.dump(d, f)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(tmp, 0o600)
            os.replace(tmp, self.path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    # --- questions
    def status(self):
        """{state: none|pending|expired|burned|done, expires_in?: seconds, user?: name}. Never the hash."""
        d = self._read()
        if d is None:
            return {"state": NONE}
        if d["state"] == "done":
            return {"state": DONE, "user": d.get("user", "")}
        if d.get("fails", 0) >= self.max_fails:
            return {"state": BURNED}
        left = int(d.get("expires", 0) - self.clock())
        return {"state": "pending", "expires_in": left} if left > 0 else {"state": EXPIRED}

    def is_open(self):
        """True while a token can still be redeemed (what the sign-in page asks)."""
        return self.status()["state"] == "pending"

    # --- changes
    def issue(self):
        """A new token; the previous one (if any) is dead. Refused (None) on a server whose setup is done."""
        with self.lock:
            d = self._read()
            if d is not None and d["state"] == "done":
                return None
            token = new_token(self.rng)
            self._write({"state": "pending", "hash": _hash(normalize(token)), "issued": self.clock(), "expires": self.clock() + self.ttl, "fails": 0})
            return token

    def arm(self):
        """Mark a fresh install as waiting for its first setup, without a token (the installer has none to show). The state reads `expired`
        until the boot unit issues the first one. Never touches a flag that exists (a done setup stays done)."""
        with self.lock:
            if self._read() is not None:
                return False
            self._write({"state": "pending", "hash": "", "issued": 0, "expires": 0, "fails": 0})
            return True

    def reset(self):
        with self.lock:
            try:
                os.unlink(self.path)
            except FileNotFoundError:
                pass

    def redeem(self, token, action):
        """Check the token and, only if it is good, run action() while holding the lock; when it returns a user name the token is consumed
        and the setup is done (bound to that name). Returns (result, user). A failed action keeps the token usable.
        Wrong tokens count: MAX_FAILS of them burn the token for good (issue a new one on the console)."""
        with self.lock:
            d = self._read()
            if d is None:
                return NONE, None
            if d["state"] == "done":
                return DONE, None
            if d.get("fails", 0) >= self.max_fails:
                return BURNED, None
            if d.get("expires", 0) <= self.clock():
                return EXPIRED, None
            t = normalize(token)
            if t is None or not secrets.compare_digest(_hash(t), str(d.get("hash", ""))):
                d["fails"] = d.get("fails", 0) + 1
                self._write(d)
                return (BURNED if d["fails"] >= self.max_fails else BAD), None
            user = action()
            if not user:
                return FAILED, None
            self._write({"state": "done", "user": user, "done": self.clock(), "wizard": "open"})
            return OK, user

    def wizard(self):
        """none | open | done: whether the first-run web wizard is still to be shown. A done record without the field (a server set up before
        the wizard existed) counts as done."""
        d = self._read()
        if d is None or d["state"] != "done":
            return NONE
        w = d.get("wizard", "done")
        return w if w in ("open", "done") else "done"

    def finish_wizard(self):
        """Close the wizard: True when it was open, False otherwise (idempotent)."""
        with self.lock:
            d = self._read()
            if d is None or d["state"] != "done" or d.get("wizard", "done") != "open":
                return False
            d["wizard"] = "done"
            self._write(d)
            return True


def banner(token, ttl, urls=()):
    """The text for the console: nothing else ever carries the token."""
    return "\n".join([
        "",
        "================ HOBNIX FIRST SETUP ================",
        " Open the server's web address in a browser and enter",
        " this one-time code (valid %d minutes, works once):" % (ttl // 60),
        "",
    ] + [" Address: %s" % u for u in urls] + ([""] if urls else []) + [
        "     %s" % token,
        "",
        " Not you? Do not enter it anywhere else. Run",
        " `hs setup-code issue` here to replace it.",
        "====================================================",
        "",
    ])


def main(argv):
    path = os.environ.get("HS_FIRST_RUN_FILE", os.path.join(os.environ.get("HS_STATE_DIR", "/var/lib/hs"), "first-run.json"))
    fr = FirstRun(path)
    cmd = argv[1] if len(argv) > 1 else "status"
    if cmd == "issue":
        urls = [a[len("--url="):] for a in argv[2:] if a.startswith("--url=")]
        if "--only-pending" in argv[2:] and fr.status()["state"] in (NONE, DONE):
            return 1   # the boot unit: no flag (not a first-run server) or a done setup: print nothing, not even on stderr
        token = fr.issue()
        if token is None:
            sys.stderr.write("The first setup is already done.\n")
            return 1
        sys.stdout.write(banner(token, fr.ttl, urls))
        return 0
    if cmd == "arm":
        fr.arm()
        return 0
    if cmd == "status":
        s = fr.status()
        sys.stdout.write("%s\t%s\n" % (s["state"], s.get("expires_in", s.get("user", "-"))))
        return 0
    if cmd == "reset":
        fr.reset()
        return 0
    if cmd == "wizard":
        sys.stdout.write(fr.wizard() + "\n")
        return 0
    if cmd == "wizard-done":
        fr.finish_wizard()
        return 0
    sys.stderr.write("usage: first_run.py issue|status|arm|reset|wizard|wizard-done\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
