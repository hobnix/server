#!/usr/bin/env python3
"""Logic of the nested test harness (scripts/dev/nested.sh, docs/adr/0023-nested-test-harness.md, issue #262).

Everything here that does not need virtualization is a plain function so tests/nested-test.py can run it without Incus or KVM:
  preflight   can this machine run nested VMs at all?                     (exit 0 yes, 3 no)
  iso-check   does the file look like an ISO 9660 image?                  (exit 0 yes, 1 no)
  plan        the stages and steps a scenario would run, as text          (exit 0, 2 unknown scenario)
  drive       run one stage of a scenario over the serial console of a VM (exit 0 passed, 1 a step failed, 4 console broke)

UNVERIFIED: the console driver has only ever talked to a fake console (tests/nested-test.py), never to a real Incus VM.
Exit codes of the whole harness: 0 passed, 1 a check failed, 2 usage, 3 cannot run here (fall back to `t vm`), 4 harness or Incus error.
"""
import argparse
import json
import os
import re
import select
import subprocess
import sys
import time

EXIT_OK, EXIT_FAIL, EXIT_USAGE, EXIT_NOHOST, EXIT_INFRA = 0, 1, 2, 3, 4

ANSI = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-9;?]*[ -/]*[@-~]|\x1bP[^\x1b]*\x1b\\")
PROMPT_ISO = r"\[nixos@[^\]]*\]\$ "      # the auto-login shell of the NixOS installer image
LOGIN = r"\n[^\n]*login: $"


# ---------------------------------------------------------------- preflight

def read_first(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def preflight(env=None, which=None):
    """Return a list of (name, ok, detail). `env` and `which` are injectable: HS_NESTED_ROOT replaces / (tests), which is shutil.which."""
    import shutil
    env = os.environ if env is None else env
    which = which or shutil.which
    root = env.get("HS_NESTED_ROOT", "/")
    out = []
    kvm = os.path.exists(os.path.join(root, "dev/kvm"))
    out.append(("kvm", kvm, "/dev/kvm exists" if kvm else "no /dev/kvm: enable virtualization (and nested virtualization inside a VM)"))
    nested, detail = None, "no kvm_intel or kvm_amd module parameter found"
    for mod in ("kvm_intel", "kvm_amd"):
        v = read_first(os.path.join(root, "sys/module", mod, "parameters/nested"))
        if v is not None:
            nested = v in ("1", "Y", "y")
            detail = "%s nested=%s" % (mod, v)
            break
    # a physical host with /dev/kvm but no readable parameter (other architectures) is not a failure; a parameter that says 0 is
    out.append(("nested", nested is not False and kvm, detail if nested is not None else (detail + " (not blocking when /dev/kvm exists)")))
    for tool in ("incus", "ssh-keygen", "python3"):
        have = which(tool) is not None
        out.append((tool, have, "found" if have else "%s is not installed" % tool))
    return out


def preflight_ok(results):
    return all(ok for _, ok, _ in results)


# ---------------------------------------------------------------- iso check

def iso_check(path):
    """(ok, text): the ISO 9660 signature CD001 at byte 32769 and a plausible size."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            f.seek(32769)
            sig = f.read(5)
    except OSError as e:
        return False, "cannot read %s: %s" % (path, e.strerror)
    if sig != b"CD001":
        return False, "%s is not an ISO 9660 image (signature at byte 32769 is %r)" % (path, sig)
    if size < 50_000_000:
        return False, "%s is only %d bytes: not a complete installer image" % (path, size)
    return True, "%s: ISO 9660, %d bytes" % (path, size)


# ---------------------------------------------------------------- scenarios

def pick_disk(lsblk_out):
    """The install target: the largest disk in `lsblk -dnb -e 7,11 -o NAME,SIZE` (loop devices and the optical drive are already left out)."""
    best = None
    for line in lsblk_out.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1].isdigit():
            if best is None or int(parts[1]) > best[1]:
                best = (parts[0], int(parts[1]))
    return best[0] if best else None


def shq(s):
    return "'" + s.replace("'", "'\\''") + "'"


def step(kind, text, **kw):
    d = {"kind": kind, "text": text}
    d.update(kw)
    return d


def build_scenario(stage, params):
    """The steps of one stage. Kinds: wait (regex on the console), send (raw line), run (command, rc must be 0 unless expect_rc),
    capture (command, output kept in a variable), run_var (a command with {var} placeholders). Deliberately data, so it can be reviewed
    and tested without a VM."""
    host = params.get("hostname", "nested-test")
    if stage == "iso":      # ISO boot check (#175) and the unattended install (needs the flags of hs-install; the answers file is not read yet)
        pw, key = params["password"], params["pubkey"]
        install = ("HS_INSTALL_PASSWORD=%s hs-install --role minimal --disk {disk} --confirm-disk {disk} --hostname %s --key %s --timezone UTC --preset minimal"
                   % (shq(pw), shq(host), shq(key)))
        return [
            step("wait", PROMPT_ISO, timeout=420, what="the installer ISO boots to its shell"),
            step("send", "sudo -i"),
            step("run", "command -v hs-install", what="hs-install is on the ISO"),
            step("run", "test -f /etc/hs-installer/docs/install.md", what="the repository copy is on the ISO"),
            step("capture", "lsblk -dnb -e 7,11 -o NAME,SIZE", var="lsblk", what="a target disk is visible"),
            step("pick_disk", "", var="disk", src="lsblk", what="a disk was found"),
            step("run_var", install, timeout=1800, what="unattended hs-install finishes"),
            # the console may close before the marker comes back: the shell is stopped as soon as the shutdown starts (rerun of 2026-11-10)
            step("run", "sync && poweroff", expect_rc=None, may_close=True, what="power off after the install"),
        ]
    if stage == "smoke":    # the installed system boots from its disk
        user, pw = "adminuser", params["password"]
        return [
            step("wait", LOGIN, timeout=420, what="the installed system reaches a login prompt"),
            step("send", user),
            step("wait", r"[Pp]assword: ?$", timeout=30, what="the password prompt"),
            step("send_secret", pw),
            step("wait", r"\[%s@[^\]]*\]\$ " % user, timeout=60, what="adminuser is logged in"),
            step("run", "test \"$(hostname)\" = %s" % shq(host), what="the hostname is the one that was installed"),
            step("run", "test -f /etc/nixos/machine.toml", what="machine.toml is in /etc/nixos"),
            step("run", "test -d /etc/nixos/scripts", what="the repository copy is in /etc/nixos"),
            step("run", "systemctl is-system-running --wait | grep -Eq '^(running|degraded)$'", timeout=300,
                 what="systemd finished starting (running or degraded)"),
        ]
    raise KeyError(stage)


STAGES = ("iso", "smoke")


# ---------------------------------------------------------------- console driver

class Redactor:
    def __init__(self, secrets):
        self.secrets = [s for s in secrets if s]

    def __call__(self, text):
        for s in self.secrets:
            text = text.replace(s, "***")
        return text


class Timeout(Exception):
    pass


class Closed(Exception):
    pass


class Console:
    """Expect-style wrapper around a transport with read(timeout) -> str | '' (nothing yet) | None (closed) and write(str)."""

    def __init__(self, transport, log=None, redact=None, clock=time.monotonic):
        self.t, self.log, self.redact, self.clock = transport, log, redact or (lambda s: s), clock
        self.buf = ""
        self.logbuf = ""
        self.seq = 0

    def _pump(self, timeout):
        chunk = self.t.read(timeout)
        if chunk is None:
            raise Closed("console closed")
        if chunk:
            chunk = chunk.replace("\r", "")
            self.buf = ANSI.sub("", self.buf + chunk)   # the serial console carries colour and OSC sequences
            if self.log:
                # whole lines only: the console delivers a typed line in small pieces, and a secret split over two pieces was not redacted
                self.logbuf += chunk
                cut = self.logbuf.rfind("\n") + 1
                if cut:
                    self.log.write(self.redact(self.logbuf[:cut]))
                    self.log.flush()
                    self.logbuf = self.logbuf[cut:]
        return chunk

    def flush_log(self):
        """Write the unfinished last line (a prompt, the output before a timeout) to the log."""
        if self.log and self.logbuf:
            self.log.write(self.redact(self.logbuf))
            self.log.flush()
        self.logbuf = ""

    def expect(self, regex, timeout):
        """Wait until `regex` matches the buffered output; returns the text before and including the match and drops it from the buffer."""
        end = self.clock() + timeout
        rx = re.compile(regex)
        while True:
            m = rx.search(self.buf)
            if m:
                got, self.buf = self.buf[:m.end()], self.buf[m.end():]
                return got
            left = end - self.clock()
            if left <= 0:
                raise Timeout("no match for %r within %ss; last output: %r" % (regex, timeout, self.buf[-200:]))
            self._pump(min(left, 1.0))

    def send(self, line):
        self.t.write(line + "\n")

    def run(self, cmd, timeout=60):
        """Run a shell command and return (rc, output). A unique marker carries the exit code; the typed command line is echoed by the tty
        but holds `$?` unexpanded, so only the real marker matches."""
        self.seq += 1
        tag = "HSN%d" % self.seq
        self.send("%s; echo \"__%s__ rc=$?\"" % (cmd, tag))
        got = self.expect(r"__%s__ rc=(\d+)" % tag, timeout)
        rc = int(re.search(r"__%s__ rc=(\d+)" % tag, got).group(1))
        out = got.split("\n", 1)[1] if "\n" in got else ""
        out = re.sub(r"\n?[^\n]*__%s__ rc=\d+$" % tag, "", out)
        return rc, out


def run_steps(console, steps, params_vars=None, report=None):
    """Run the steps in order. Returns (ok, results); stops at the first failed step. results: list of dicts for result.json."""
    vars_ = dict(params_vars or {})
    results = []
    for s in steps:
        what = "(secret)" if s["kind"] == "send_secret" else (s.get("what") or s["text"][:60])
        rec = {"step": what, "kind": s["kind"], "ok": False}
        try:
            k = s["kind"]
            if k == "wait":
                console.expect(s["text"], s.get("timeout", 60))
                rec["ok"] = True
            elif k == "send":
                console.send(s["text"])
                rec["ok"] = True
            elif k == "send_secret":
                console.send(s["text"])
                rec["ok"] = True
            elif k in ("run", "run_var", "capture"):
                cmd = s["text"].format(**vars_) if k == "run_var" else s["text"]
                rc, out = console.run(cmd, s.get("timeout", 60))
                want = s.get("expect_rc", 0)
                rec["rc"] = rc
                if k == "capture":
                    vars_[s["var"]] = out
                rec["ok"] = want is None or rc == want
            elif k == "pick_disk":
                d = pick_disk(vars_.get(s["src"], ""))
                if d:
                    vars_[s["var"]] = d
                    rec["value"] = d
                rec["ok"] = d is not None
            else:
                raise ValueError("unknown step kind %r" % k)
        except Timeout as e:
            rec["error"] = str(e)
        except Closed:
            if not s.get("may_close"):
                raise
            rec["ok"] = rec["closed"] = True
        rec["detail"] = None
        results.append(rec)
        if report:
            report(rec)
        if not rec["ok"]:
            return False, results
    return True, results


class PtyTransport:
    """`incus console <vm>` on a pty: the serial console of the VM as a stream."""

    def __init__(self, argv):
        import pty
        self.master, slave = pty.openpty()
        self.proc = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave, close_fds=True)
        os.close(slave)

    def read(self, timeout):
        r, _, _ = select.select([self.master], [], [], timeout)
        if not r:
            return "" if self.proc.poll() is None else None
        try:
            data = os.read(self.master, 65536)
        except OSError:
            return None
        return data.decode("utf-8", "replace") if data else None

    def write(self, text):
        os.write(self.master, text.encode())

    def close(self):
        try:
            self.proc.terminate()
            self.proc.wait(5)
        except Exception:
            self.proc.kill()


def drive(stage, vm, logdir, password, pubkey, hostname, incus):
    steps = build_scenario(stage, {"password": password, "pubkey": pubkey, "hostname": hostname})
    os.makedirs(logdir, exist_ok=True)
    redact = Redactor([password])
    with open(os.path.join(logdir, "console-%s.log" % stage), "w") as log:
        try:
            transport = PtyTransport([incus, "console", vm])
        except OSError as e:
            print("cannot start %s console: %s" % (incus, e), file=sys.stderr)
            return EXIT_INFRA
        con = Console(transport, log=log, redact=redact)
        try:
            ok, results = run_steps(con, steps, report=lambda r: print("  %s  %s" % ("ok  " if r["ok"] else "FAIL", r["step"]), flush=True))
        except Closed:
            print("the console closed (did the VM stop?)", file=sys.stderr)
            return EXIT_INFRA
        finally:
            con.flush_log()
            transport.close()
    with open(os.path.join(logdir, "result-%s.json" % stage), "w") as f:
        json.dump({"stage": stage, "ok": ok, "steps": results}, f, indent=1)
    return EXIT_OK if ok else EXIT_FAIL


def main(argv):
    ap = argparse.ArgumentParser(prog="nested_lib")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("preflight")
    p = sub.add_parser("iso-check")
    p.add_argument("file")
    p = sub.add_parser("plan")
    p.add_argument("stage")
    p = sub.add_parser("drive")
    p.add_argument("stage")
    p.add_argument("--vm", required=True)
    p.add_argument("--logdir", required=True)
    p.add_argument("--hostname", default="nested-test")
    p.add_argument("--incus", default=os.environ.get("HS_NESTED_INCUS", "incus"))
    a = ap.parse_args(argv)
    if a.cmd == "preflight":
        res = preflight()
        for name, ok, detail in res:
            print("%s\t%s\t%s" % ("ok" if ok else "MISSING", name, detail))
        return EXIT_OK if preflight_ok(res) else EXIT_NOHOST
    if a.cmd == "iso-check":
        ok, text = iso_check(a.file)
        print(text)
        return EXIT_OK if ok else EXIT_FAIL
    if a.cmd == "plan":
        try:
            steps = build_scenario(a.stage, {"password": "<password>", "pubkey": "<pubkey>"})
        except KeyError:
            print("unknown stage %r (stages: %s)" % (a.stage, ", ".join(STAGES)), file=sys.stderr)
            return EXIT_USAGE
        for s in steps:
            print("%s\t%s" % (s["kind"], s.get("what") or s["text"]))
        return EXIT_OK
    # drive: the throwaway password and the public key come from the environment, never from argv
    pw, key = os.environ.get("HS_NESTED_PASSWORD", ""), os.environ.get("HS_NESTED_PUBKEY", "")
    if not pw or (a.stage == "iso" and not key):
        print("HS_NESTED_PASSWORD (and HS_NESTED_PUBKEY for stage iso) must be set", file=sys.stderr)
        return EXIT_USAGE
    if a.stage not in STAGES:
        print("unknown stage %r" % a.stage, file=sys.stderr)
        return EXIT_USAGE
    return drive(a.stage, a.vm, a.logdir, pw, key, a.hostname, a.incus)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
