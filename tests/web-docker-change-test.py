#!/usr/bin/env python3
"""scripts/web-serve.py, the `docker setup` entry of CHANGES: allowed and refused shapes, plan runs only `plan` (never `start`), a refusal of the
script reaches the browser with its reason, start runs `start`. Real HTTP server on a free port, fake `_run`. The script is tested in tests/docker-cap.sh."""
import importlib.util
import json
import os
import unittest

here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("web_login_test_base", os.path.join(here, "web-login-test.py"))
lt = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lt)
ws = lt.ws


class DockerChange(lt.Base):
    def setUp(self):
        super().setUp()
        self.calls = []
        self.answer = (0, "status\tok\nheading\tTurn Docker on\nstep\t1. Create the container docker (4096 MiB, 4 CPUs, nesting).\nlong\tyes\n")
        self.real_run = ws._run

        def fake(cmd, stdin=None, timeout=10):
            self.calls.append((cmd, stdin))
            return self.answer
        ws._run = fake
        _, d, r = self.login()
        self.ck = {"Cookie": self.cookie(r), "X-CSRF-Token": d["csrf"]}
        self.calls.clear()

    def tearDown(self):
        ws._run = self.real_run
        super().tearDown()

    def post(self, path, body):
        s, d, _ = self.req("POST", path, body, headers=self.ck)
        return s, json.loads(d)

    def test_plan_only_plans(self):
        s, d = self.post("/api/plan", {"area": "docker", "args": ["setup", "--set", "dockerManager=arcane", "--set", "dockerSize=s"]})
        self.assertEqual(s, 200)
        self.assertEqual(d["status"], "ok")
        self.assertEqual(len(self.calls), 1)
        cmd = self.calls[0][0]
        self.assertIn("plan", cmd)
        self.assertNotIn("start", cmd)
        self.assertEqual(cmd[-5:], ["setup", "--set", "dockerManager=arcane", "--set", "dockerSize=s"])

    def test_refusal_reaches_the_browser(self):
        self.answer = (1, "status\trefused\nreason\tDocker is on already.\n")
        s, d = self.post("/api/plan", {"area": "docker", "args": ["setup", "--set", "dockerManager=none"]})
        self.assertEqual(s, 200)
        self.assertEqual(d["status"], "refused")
        self.assertEqual(d["reason"], "Docker is on already.")
        self.assertEqual([c for c in self.calls if "start" in c[0]], [])

    def test_start_runs_start(self):
        self.answer = (0, "status\tstarted\nunit\ths-job-docker-enable-1.service\n")
        s, d = self.post("/api/start", {"area": "docker", "args": ["setup", "--set", "dockerManager=webui"]})
        self.assertEqual(s, 200)
        self.assertEqual(d["status"], "started")
        self.assertEqual(d["unit"], "hs-job-docker-enable-1.service")
        self.assertIn("start", self.calls[-1][0])

    def test_refused_shapes(self):
        bad = [
            ["setup", "--set", "dockerManager=foo"],
            ["setup", "--set", "dockerSize=xl"],
            ["setup", "--set", "dockerMemory=1"],
            ["setup", "--set", "dockerManager=webui;id"],
            ["setup", "--yes"],
            ["setup", "--confirm", "docker"],
            ["enable", "--set", "dockerManager=webui"],
            ["disable"],
            ["setup", "dockerManager=webui"],
        ]
        for a in bad:
            self.calls.clear()
            self.assertEqual(self.post("/api/plan", {"area": "docker", "args": a})[0], 400, a)
            self.assertEqual(self.post("/api/start", {"area": "docker", "args": a})[0], 400, a)
            self.assertEqual(self.calls, [], a)
        self.assertEqual(self.post("/api/start", {"area": "docker", "args": ["setup", "--set", "dockerManager=webui"], "stdin": "pw"})[0], 400)


if __name__ == "__main__":
    unittest.main(verbosity=1)
