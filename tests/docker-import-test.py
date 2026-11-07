#!/usr/bin/env python3
import json, os, subprocess, sys, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
HELPER = os.path.join(ROOT, "scripts", "lib", "docker_import.py")
DIR = "/shares/apps/stacks/demo"


def run(cfg):
    p = subprocess.run([sys.executable, "-I", HELPER, "--app-dir", DIR], input=json.dumps(cfg).encode(),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert p.returncode == 0, p.stderr
    return [l.split("\t") for l in p.stdout.decode().splitlines()]


def svc(**kw):
    s = {"image": "nginx:1"}
    s.update(kw)
    return {"services": {"web": s}}


def levels(rows, kind=None):
    return [r[1] for r in rows if kind is None or r[0] == kind]


class Import(unittest.TestCase):
    def test_clean(self):
        rows = run(svc(ports=[{"target": 80, "published": "8080", "protocol": "tcp"}],
                       volumes=[{"type": "bind", "source": DIR + "/data", "target": "/d"}],
                       networks={"default": None}))
        self.assertEqual(set(levels(rows)), {"info"})
        kinds = {r[0] for r in rows}
        self.assertTrue({"service", "port", "volume", "network"} <= kinds)
        self.assertIn("8080:80/tcp", [r[3] for r in rows if r[0] == "port"])
        self.assertTrue(all(len(r) == 4 and all(r) for r in rows))

    def test_named_volume(self):
        cfg = svc(volumes=[{"type": "volume", "source": "db", "target": "/v"}])
        cfg["volumes"] = {"db": {}}
        rows = run(cfg)
        errs = [r for r in rows if r[1] == "error"]
        self.assertEqual(len(errs), 1)
        self.assertIn("named volume db not supported, use ./data/db bind", errs[0][3])

    def test_docker_sock_refused(self):
        for src in ("/var/run/docker.sock", "/run/docker.sock"):
            rows = run(svc(volumes=[{"type": "bind", "source": src, "target": "/s", "read_only": True}]))
            self.assertIn("refuse", levels(rows, "danger"))

    def test_sock_parent_refused(self):
        for src in ("/run", "/var/run", "/var/run/", "/run/../var/run"):
            rows = run(svc(volumes=[{"type": "bind", "source": src, "target": "/s"}]))
            self.assertIn("refuse", levels(rows, "danger"), src)

    def test_device_path_normalized(self):
        rows = run(svc(devices=["/dev/dri/../sda:/x"]))
        self.assertIn("risky", levels(rows, "danger"))

    def test_volumes_from_risky(self):
        self.assertIn("risky", levels(run(svc(volumes_from=["other"])), "danger"))

    def test_privileged_refused(self):
        self.assertIn("refuse", levels(run(svc(privileged=True)), "danger"))

    def test_host_paths_refused(self):
        for src in ("/", "/etc", "/proc/x", "/sys", "/boot"):
            rows = run(svc(volumes=[{"type": "bind", "source": src, "target": "/h"}]))
            self.assertIn("refuse", levels(rows, "danger"), src)

    def test_host_network_risky(self):
        rows = run(svc(network_mode="host"))
        self.assertEqual(levels(rows, "danger"), ["risky"])

    def test_other_risky(self):
        for kw in ({"pid": "host"}, {"ipc": "host"}, {"cap_add": ["SYS_ADMIN"]}, {"cap_add": ["ALL"]}, {"cap_add": ["NET_ADMIN"]},
                   {"devices": [{"source": "/dev/sda", "target": "/dev/sda"}]}, {"security_opt": ["seccomp:unconfined"]},
                   {"security_opt": ["apparmor=unconfined"]}, {"userns_mode": "host"}):
            self.assertIn("risky", levels(run(svc(**kw)), "danger"), kw)

    def test_dri_device_fine(self):
        rows = run(svc(devices=[{"source": "/dev/dri", "target": "/dev/dri"}]))
        self.assertNotIn("risky", levels(rows))

    def test_bind_outside_risky_inside_fine(self):
        out = run(svc(volumes=[{"type": "bind", "source": "/srv/media", "target": "/m"}]))
        self.assertEqual(levels(out, "danger"), ["risky"])
        self.assertTrue(any("OUTSIDE" in r[3] for r in out))
        inn = run(svc(volumes=[{"type": "bind", "source": DIR + "/x", "target": "/m", "read_only": True}]))
        self.assertEqual(levels(inn, "danger"), [])
        self.assertTrue(any("inside the app folder" in r[3] and "ro" in r[3] for r in inn))
        sib = run(svc(volumes=[{"type": "bind", "source": DIR + "-other/x", "target": "/m"}]))
        self.assertEqual(levels(sib, "danger"), ["risky"])

    def test_unknown_key_listed(self):
        rows = run(svc(gpus="all"))
        un = [r for r in rows if r[0] == "unsupported"]
        self.assertEqual(len(un), 1)
        self.assertEqual(un[0][1], "warn")
        self.assertIn("not imported/untested: gpus", un[0][3])

    def test_unpublished_port_error(self):
        rows = run(svc(ports=[{"target": 80, "protocol": "tcp"}]))
        self.assertIn("error", levels(rows, "port"))

    def test_env_names_only(self):
        rows = run(svc(environment={"DB_PASSWORD": "hunter2-secret", "TZ": "Europe/Vienna"}))
        text = "\n".join("\t".join(r) for r in rows)
        self.assertIn("DB_PASSWORD", text)
        self.assertNotIn("hunter2-secret", text)
        self.assertNotIn("Europe/Vienna", text)

    def test_bad_json(self):
        p = subprocess.run([sys.executable, "-I", HELPER, "--app-dir", DIR], input=b"{", stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(p.returncode, 2)


if __name__ == "__main__":
    unittest.main()
