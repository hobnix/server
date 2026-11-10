#!/usr/bin/env python3
"""scripts/dev/nested_lib.py and scripts/dev/nested.sh with a fake console and a fake incus: no KVM, no Incus, no ISO."""
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "scripts", "dev"))
import nested_lib as n  # noqa: E402

SCRIPT = os.path.join(ROOT, "scripts", "dev", "nested.sh")
LIB = os.path.join(ROOT, "scripts", "dev", "nested_lib.py")


class FakeTransport:
    """Plays a shell: answers every `cmd; echo "__TAG__ rc=$?"` line with output and the marker."""

    def __init__(self, banner="", rc_for=None, outputs=None):
        self.queue = [banner] if banner else []
        self.rc_for = rc_for or (lambda cmd: 0)
        self.outputs = outputs or {}
        self.sent = []
        self.closed = False

    def read(self, timeout):
        if self.queue:
            return self.queue.pop(0)
        return "" if not self.closed else None

    def write(self, text):
        self.sent.append(text)
        line = text.rstrip("\n")
        self.queue.append(line + "\r\n")     # the tty echoes what is typed
        m = n.re.search(r'^(.*); echo "__(\w+)__ rc=\$\?"$', line)
        if m:
            cmd, tag = m.groups()
            out = "".join(v for k, v in self.outputs.items() if k in cmd)
            self.queue.append("%s__%s__ rc=%d\r\n" % (out, tag, self.rc_for(cmd)))


class Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        self.t += 0.5
        return self.t


class ConsoleTests(unittest.TestCase):
    def test_run_returns_rc_and_output(self):
        c = n.Console(FakeTransport(outputs={"lsblk": "sda 100\n"}))
        self.assertEqual(c.run("lsblk"), (0, "sda 100"))

    def test_run_nonzero_rc(self):
        c = n.Console(FakeTransport(rc_for=lambda cmd: 3))
        self.assertEqual(c.run("false")[0], 3)

    def test_echoed_command_is_not_mistaken_for_the_marker(self):
        t = FakeTransport(rc_for=lambda cmd: 5)
        c = n.Console(t)
        self.assertEqual(c.run("x")[0], 5)     # the echo holds `$?`, the marker holds the number

    def test_expect_timeout(self):
        c = n.Console(FakeTransport(banner="boot..."), clock=Clock())
        with self.assertRaises(n.Timeout):
            c.expect("login:", 3)

    def test_closed_console(self):
        t = FakeTransport()
        t.closed = True
        with self.assertRaises(n.Closed):
            n.Console(t, clock=Clock()).expect("x", 5)

    def test_log_is_redacted(self):
        log = io.StringIO()
        c = n.Console(FakeTransport(banner="pw is hunter2 ok\n"), log=log, redact=n.Redactor(["hunter2"]))
        c.expect("ok", 5)
        self.assertIn("pw is *** ok", log.getvalue())
        self.assertNotIn("hunter2", log.getvalue())

    def test_log_is_redacted_when_the_secret_comes_in_pieces(self):
        # a serial console delivers the echo of a typed line in small pieces (first hardware run, 2026-11-10: the password was in the log)
        log = io.StringIO()
        t = FakeTransport()
        t.queue = ["PW='hun", "ter", "2' cmd\n", "done\n", "tail"]
        c = n.Console(t, log=log, redact=n.Redactor(["hunter2"]))
        c.expect("tail", 5)
        self.assertEqual(log.getvalue(), "PW='***' cmd\ndone\n")
        c.flush_log()                              # the unfinished last line is written at the end
        self.assertEqual(log.getvalue(), "PW='***' cmd\ndone\ntail")

    def test_prompt_with_colour_and_title_sequences_matches(self):
        banner = "\x1b]0;nixos@nixos: ~\x07\x1b[1;32m[nixos@nixos:~]$\x1b[0m "
        c = n.Console(FakeTransport(banner=banner), clock=Clock())
        self.assertIn("[nixos@nixos:~]$ ", c.expect(n.PROMPT_ISO, 3))


class ScenarioTests(unittest.TestCase):
    P = {"password": "pw1", "pubkey": "ssh-ed25519 AAAA test", "hostname": "box"}

    def test_pick_disk_largest(self):
        self.assertEqual(n.pick_disk("sda 21474836480\nsdb 1073741824\n"), "sda")
        self.assertEqual(n.pick_disk("vda 5\nvdb 9\n"), "vdb")
        self.assertIsNone(n.pick_disk(""))
        self.assertIsNone(n.pick_disk("garbage\n"))

    def test_shq(self):
        self.assertEqual(n.shq("a'b"), "'a'\\''b'")

    def test_install_step_confirms_the_same_disk_name(self):
        steps = n.build_scenario("iso", self.P)
        inst = [s for s in steps if "hs-install" in s["text"] and s["kind"] == "run_var"][0]
        self.assertEqual(inst["text"].count("{disk}"), 2)
        self.assertIn("--confirm-disk {disk}", inst["text"])

    def test_install_step_leaves_no_question_open(self):
        # hs-install asks for what no option gives when it has a terminal, and the console is one
        steps = n.build_scenario("iso", self.P)
        inst = [s for s in steps if "hs-install" in s["text"] and s["kind"] == "run_var"][0]
        for flag in ("--role ", "--hostname ", "--key ", "--timezone ", "--preset "):
            self.assertIn(flag, inst["text"])

    def test_no_step_edits_the_boot_entries(self):
        # the installed system brings its own serial console (install.nix): the harness tests it as it is
        self.assertFalse([s for s in n.build_scenario("iso", self.P) if "/mnt/boot" in s["text"]])

    def test_console_that_closes_at_power_off_is_not_a_failure(self):
        class Off(FakeTransport):
            def write(self, text):
                if "poweroff" in text:
                    self.closed, self.queue = True, []
                else:
                    super().write(text)
        t = Off(banner="[nixos@nixos:~]$ ", outputs={"lsblk": "sda 21474836480\n"})
        ok, res = n.run_steps(n.Console(t, clock=Clock()), n.build_scenario("iso", self.P))
        self.assertTrue(ok, res)
        self.assertTrue(res[-1].get("closed"))

    def test_console_that_closes_elsewhere_is_an_error(self):
        t = FakeTransport()
        t.closed = True
        with self.assertRaises(n.Closed):
            n.run_steps(n.Console(t, clock=Clock()), [n.step("wait", "login:", timeout=5, what="w")])

    def test_unknown_stage(self):
        with self.assertRaises(KeyError):
            n.build_scenario("nope", self.P)

    def test_full_iso_stage_against_fake(self):
        t = FakeTransport(banner="[nixos@nixos:~]$ ", outputs={"lsblk": "sda 21474836480\n"})
        c = n.Console(t)
        ok, res = n.run_steps(c, n.build_scenario("iso", self.P))
        self.assertTrue(ok, res)
        sent = "".join(t.sent)
        self.assertIn("--disk sda --confirm-disk sda", sent)
        self.assertIn("sudo -i", sent)

    def test_failing_step_stops_the_run(self):
        t = FakeTransport(banner="[nixos@nixos:~]$ ", rc_for=lambda cmd: 1 if "HS_INSTALL_PASSWORD" in cmd else 0,
                          outputs={"lsblk": "sda 100\n"})
        ok, res = n.run_steps(n.Console(t), n.build_scenario("iso", self.P))
        self.assertFalse(ok)
        self.assertEqual(res[-1]["step"], "unattended hs-install finishes")
        self.assertNotIn("poweroff", "".join(t.sent))

    def test_no_disk_found_fails_before_install(self):
        t = FakeTransport(banner="[nixos@nixos:~]$ ")
        ok, res = n.run_steps(n.Console(t), n.build_scenario("iso", self.P))
        self.assertFalse(ok)
        self.assertNotIn("hs-install --role", "".join(t.sent))

    def test_timeout_is_a_failed_step(self):
        c = n.Console(FakeTransport(banner="nothing"), clock=Clock())
        ok, res = n.run_steps(c, [n.step("wait", "login:", timeout=2, what="w")])
        self.assertFalse(ok)
        self.assertIn("error", res[0])


class HostTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def fake_root(self, kvm=True, nested="Y"):
        r = os.path.join(self.d, "root")
        os.makedirs(os.path.join(r, "dev"), exist_ok=True)
        if kvm:
            open(os.path.join(r, "dev/kvm"), "w").close()
        if nested is not None:
            p = os.path.join(r, "sys/module/kvm_intel/parameters")
            os.makedirs(p, exist_ok=True)
            open(os.path.join(p, "nested"), "w").write(nested + "\n")
        return r

    def test_preflight_ok(self):
        res = n.preflight({"HS_NESTED_ROOT": self.fake_root()}, which=lambda t: "/bin/" + t)
        self.assertTrue(n.preflight_ok(res), res)

    def test_preflight_no_kvm(self):
        res = n.preflight({"HS_NESTED_ROOT": self.fake_root(kvm=False)}, which=lambda t: "/bin/" + t)
        self.assertFalse(n.preflight_ok(res))

    def test_preflight_nested_off(self):
        res = n.preflight({"HS_NESTED_ROOT": self.fake_root(nested="N")}, which=lambda t: "/bin/" + t)
        self.assertFalse(n.preflight_ok(res))

    def test_preflight_no_incus(self):
        res = n.preflight({"HS_NESTED_ROOT": self.fake_root()}, which=lambda t: None if t == "incus" else "/bin/" + t)
        self.assertEqual([r[0] for r in res if not r[1]], ["incus"])

    def iso(self, name, sig=b"CD001", size=60_000_000):
        p = os.path.join(self.d, name)
        with open(p, "wb") as f:
            f.truncate(size)
            f.seek(32769)
            f.write(sig)
        return p

    def test_iso_check(self):
        self.assertTrue(n.iso_check(self.iso("a.iso"))[0])
        self.assertFalse(n.iso_check(self.iso("b.iso", sig=b"XXXXX"))[0])
        self.assertFalse(n.iso_check(self.iso("c.iso", size=40000))[0])
        self.assertFalse(n.iso_check(os.path.join(self.d, "missing.iso"))[0])


FAKE_INCUS = r'''#!/usr/bin/env python3
import os, re, sys
st = os.environ["FAKE_STATE"]
def get(k, d=""):
    try: return open(os.path.join(st, k)).read().strip()
    except OSError: return d
def put(k, v): open(os.path.join(st, k), "w").write(v)
with open(os.path.join(st, "calls"), "a") as f: f.write(" ".join(sys.argv[1:]) + "\n")
a = sys.argv[1:]
if a[0] == "list": print(get("state", "STOPPED")); sys.exit(0)
if a[0] == "start": put("state", "RUNNING"); sys.exit(0)
if a[0] in ("init", "delete"): sys.exit(1 if os.environ.get("FAKE_INIT_FAILS") and a[0] == "init" else 0)
if a[0] == "config": sys.exit(0)
if a[0] != "console": sys.exit(9)
installed = get("installed") == "1"
fail = os.environ.get("FAKE_FAIL_CMD", "")
out = sys.stdout
def say(s): out.write(s); out.flush()
if installed: say("\nnested-test login: ")
else: say("[nixos@nixos:~]$ ")
for line in sys.stdin:
    line = line.rstrip("\r\n")
    if installed and not get("user"):
        put("user", line); say("Password: "); continue
    if installed and get("user") == line and not get("pw"): continue
    if installed and not get("pw"):
        put("pw", line); say("[adminuser@nested-test:~]$ "); continue
    if line == "sudo -i": say("[root@nixos:~]# "); continue
    m = re.match(r'^(.*); echo "__(\w+)__ rc=\$\?"$', line)
    if not m: continue
    cmd, tag = m.groups()
    rc = 1 if fail and fail in cmd else 0
    if "lsblk" in cmd: say("sda 21474836480\n")
    if "poweroff" in cmd:
        put("state", "STOPPED"); put("installed", "1"); say("__%s__ rc=0\n" % tag); sys.exit(0)
    say("__%s__ rc=%d\n" % (tag, rc))
'''


@unittest.skipUnless(shutil.which("ssh-keygen"), "ssh-keygen missing")
class RunTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = self.d = self.tmp.name
        self.state = os.path.join(d, "state")
        os.makedirs(self.state)
        os.makedirs(os.path.join(d, "root/dev"))
        open(os.path.join(d, "root/dev/kvm"), "w").close()
        os.makedirs(os.path.join(d, "bin"))
        self.fake = os.path.join(d, "bin", "incus")
        open(self.fake, "w").write(FAKE_INCUS)
        os.chmod(self.fake, 0o755)
        # a copy of the scripts so .work/ lands in the temp dir, not in the repository
        self.repo = os.path.join(d, "repo")
        os.makedirs(os.path.join(self.repo, "scripts/dev"))
        for f in ("nested.sh", "nested_lib.py"):
            shutil.copy(os.path.join(ROOT, "scripts/dev", f), os.path.join(self.repo, "scripts/dev", f))
        self.iso = os.path.join(d, "x.iso")
        with open(self.iso, "wb") as f:
            f.truncate(60_000_000)
            f.seek(32769)
            f.write(b"CD001")

    def tearDown(self):
        self.tmp.cleanup()

    def run_sh(self, *args, **env):
        e = dict(os.environ, HS_NESTED_ROOT=os.path.join(self.d, "root"), HS_NESTED_INCUS=self.fake,
                 FAKE_STATE=self.state, PATH=os.path.join(self.d, "bin") + os.pathsep + os.environ["PATH"])
        e.pop("HS_NESTED_ISO", None)
        e.update(env)
        return subprocess.run(["bash", os.path.join(self.repo, "scripts/dev/nested.sh"), *args], env=e,
                              capture_output=True, text=True, timeout=120)

    def logs(self):
        run = os.path.realpath(os.path.join(self.repo, ".work/nested/latest"))
        return run

    def test_usage(self):
        self.assertEqual(self.run_sh().returncode, 2)
        self.assertEqual(self.run_sh("run", "--bogus").returncode, 2)
        self.assertEqual(self.run_sh("run", "--stage", "smoke").returncode, 2)
        self.assertEqual(self.run_sh("plan", "nope").returncode, 2)

    def test_plan_prints_steps_without_secrets(self):
        r = self.run_sh("plan")
        self.assertEqual(r.returncode, 0)
        self.assertIn("unattended hs-install finishes", r.stdout)
        self.assertIn("== smoke", r.stdout)

    def test_no_kvm_is_exit_3(self):
        os.remove(os.path.join(self.d, "root/dev/kvm"))
        r = self.run_sh("run", "--iso", self.iso)
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertIn("scripts/dev/t vm", r.stdout)

    def test_bad_iso_is_exit_4(self):
        open(self.iso, "wb").write(b"x")
        self.assertEqual(self.run_sh("run", "--iso", self.iso).returncode, 4)

    def test_full_run_passes_and_keeps_logs(self):
        r = self.run_sh("run", "--iso", self.iso)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        calls = open(os.path.join(self.state, "calls")).read()
        self.assertIn("config device add", calls)
        self.assertIn("config device remove", calls)   # the ISO is detached before the second boot
        self.assertIn("delete -f", calls)               # cleaned up
        run = self.logs()
        for f in ("run.log", "console-iso.log", "console-smoke.log", "result-iso.json", "result-smoke.json"):
            self.assertTrue(os.path.exists(os.path.join(run, f)), f)
        pw = open(os.path.join(run, "password")).read().strip()
        for f in ("run.log", "console-iso.log", "console-smoke.log"):
            self.assertNotIn(pw, open(os.path.join(run, f)).read(), "password leaked into " + f)
        self.assertTrue(json.load(open(os.path.join(run, "result-smoke.json")))["ok"])

    def test_failed_check_is_exit_1_and_nothing_is_installed_after(self):
        r = self.run_sh("run", "--iso", self.iso, FAKE_FAIL_CMD="hs-installer/docs")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.logs(), "console-smoke.log")))

    def test_incus_failure_is_exit_4(self):
        self.assertEqual(self.run_sh("run", "--iso", self.iso, FAKE_INIT_FAILS="1").returncode, 4)

    def test_keep_does_not_delete(self):
        self.assertEqual(self.run_sh("run", "--iso", self.iso, "--keep").returncode, 0)
        self.assertNotIn("delete -f", open(os.path.join(self.state, "calls")).read())


if __name__ == "__main__":
    unittest.main()
