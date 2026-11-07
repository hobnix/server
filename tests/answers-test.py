#!/usr/bin/env python3
import os, shutil, subprocess, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
HELPER = os.path.join(ROOT, "scripts", "lib", "answers.py")
SCRIPT = os.path.join(ROOT, "scripts", "answers.sh")
PUB = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample admin@example.com"
SECRET = "hunter2-very-secret"


class Answers(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, text, name="a.toml"):
        p = os.path.join(self.d, name)
        with open(p, "w") as f:
            f.write(text)
        return p

    def check(self, text):
        p = self.write(text)
        r = subprocess.run([sys.executable, "-I", HELPER, "check", p], stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, text=True, env=dict(os.environ, HS_ZONEINFO_DIR=os.path.join(self.d, "nozone")))
        return r.returncode, r.stdout

    def secretfile(self, mode=0o600, content=SECRET + "\n"):
        p = os.path.join(self.d, "pw")
        with open(p, "w") as f:
            f.write(content)
        os.chmod(p, mode)
        return p

    def assertErr(self, text, where, needle):
        rc, out = self.check(text)
        self.assertEqual(rc, 1, out)
        lines = [l.split("\t") for l in out.splitlines() if l.startswith("error\t")]
        self.assertTrue(any(l[1] == where and needle in l[2] for l in lines), out)
        for l in out.splitlines():
            self.assertEqual(len(l.split("\t")), 3, l)
            self.assertTrue(all(l.split("\t")), l)
        return out

    def test_minimal(self):
        rc, out = self.check("version = 1\n")
        self.assertEqual(rc, 0, out)

    def test_full(self):
        pw = self.secretfile()
        rc, out = self.check('''version = 1
[install]
role = "homeserver"
disk = "nvme0n1"
confirm_disk = "nvme0n1"
hostname = "nas"
timezone = "Europe/Vienna"
preset = "minimal"
nic = "enp3s0"
smb_allow = "192.168.1.0/24"
bios = false
[ssh]
key = "%s"
[secrets]
admin_password_file = "%s"
''' % (PUB, pw))
        self.assertEqual(rc, 0, out)
        self.assertNotIn("error", out)

    def test_version(self):
        self.assertErr("[install]\nrole = \"edge\"\n", "version", "missing")
        self.assertErr("version = 2\n", "version", "unknown version")

    def test_unknown_key(self):
        self.assertErr("version = 1\nfoo = 1\n", "foo", "unknown key")
        self.assertErr("version = 1\n[install]\nhostnme = \"x\"\n", "install.hostnme", "unknown key")
        self.assertErr("version = 1\n[nope]\na = 1\n", "nope", "unknown key")

    def test_hostname(self):
        self.assertErr('version = 1\n[install]\nhostname = "-bad_name"\n', "install.hostname", "name of letters")

    def test_role(self):
        self.assertErr('version = 1\n[install]\nrole = "server"\n', "install.role", "one of")

    def test_confirm_disk(self):
        self.assertErr('version = 1\n[install]\ndisk = "sda"\nconfirm_disk = "sdb"\n', "install.confirm_disk", "must equal")
        rc, out = self.check('version = 1\n[install]\ndisk = "sda"\n')
        self.assertEqual(rc, 0)
        self.assertIn("warn\tinstall.confirm_disk", out)

    def test_ssh_forms(self):
        kf = os.path.join(self.d, "id.pub")
        with open(kf, "w") as f:
            f.write(PUB + "\n")
        self.assertErr('version = 1\n[ssh]\nkey = "%s"\nkey_file = "%s"\n' % (PUB, kf), "ssh", "exactly one")
        rc, out = self.check('version = 1\n[ssh]\n')
        self.assertEqual(rc, 0)
        self.assertIn("warn\tssh", out)
        rc, out = self.check('version = 1\n[ssh]\nkey_file = "%s"\n' % kf)
        self.assertEqual(rc, 0, out)
        self.assertErr('version = 1\n[ssh]\nkey_file = "%s/none"\n' % self.d, "ssh.key_file", "not found")
        self.assertErr('version = 1\n[ssh]\nkey = "hello"\n', "ssh.key", "not a public")

    def test_inline_secret(self):
        out = self.assertErr('version = 1\n[secrets]\nadmin_password = "%s"\n' % SECRET, "secrets.admin_password", "never inline")
        self.assertNotIn(SECRET, out)
        out = self.assertErr('version = 1\n[install]\ntoken = "%s"\n' % SECRET, "install.token", "token_file")
        self.assertNotIn(SECRET, out)
        self.assertErr('version = 1\npassword = "%s"\n' % SECRET, "password", "never inline")

    def test_secret_file(self):
        t = 'version = 1\n[secrets]\nadmin_password_file = "%s"\n'
        self.assertErr(t % os.path.join(self.d, "none"), "secrets.admin_password_file", "not found")
        self.assertErr(t % self.secretfile(0o644), "secrets.admin_password_file", "mode is 644")
        self.assertErr(t % self.secretfile(0o600, ""), "secrets.admin_password_file", "empty")
        rc, out = self.check(t % self.secretfile(0o400))
        self.assertEqual(rc, 0, out)
        self.assertNotIn(SECRET, out)

    def test_bad_toml(self):
        p = self.write('version = 1\n[install\nx = "%s"\n' % SECRET)
        r = subprocess.run([sys.executable, "-I", HELPER, "check", p], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.assertEqual(r.returncode, 2)
        self.assertNotIn(SECRET, r.stdout + r.stderr)
        r = subprocess.run([sys.executable, "-I", HELPER, "check", os.path.join(self.d, "none")], stdout=subprocess.PIPE, text=True)
        self.assertEqual(r.returncode, 2)

    @unittest.skipUnless(shutil.which("column"), "column missing (ui.sh table)")
    def test_script(self):
        pw = self.secretfile()
        p = self.write('version = 1\n[install]\ndisk = "sda"\nconfirm_disk = "sdb"\n[secrets]\nadmin_password_file = "%s"\n' % pw)
        env = dict(os.environ, HS_PLAIN="1", HS_LANG="en")
        r = subprocess.run(["bash", SCRIPT, p], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env, stdin=subprocess.DEVNULL)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("install.confirm_disk", r.stdout)
        self.assertNotIn(SECRET, r.stdout)
        p = self.write("version = 1\n", "ok.toml")
        r = subprocess.run(["bash", SCRIPT, p], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env, stdin=subprocess.DEVNULL)
        self.assertEqual(r.returncode, 0, r.stdout)
        p = self.write("[bad", "bad.toml")
        r = subprocess.run(["bash", SCRIPT, p], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env, stdin=subprocess.DEVNULL)
        self.assertEqual(r.returncode, 2, r.stdout)


if __name__ == "__main__":
    unittest.main()
