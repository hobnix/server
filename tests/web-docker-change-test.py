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


class DockerAppChange(lt.Base):
    def setUp(self):
        super().setUp()
        self.calls = []
        self.answer = (0, "status\tok\nheading\tstart arr\nstep\tStart the containers of arr\nlong\tno\n")
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

    def test_all_actions_allowed(self):
        for action in ("start", "stop", "restart", "pull"):
            self.calls.clear()
            self.answer = (0, "status\tok\n")
            s, d = self.post("/api/plan", {"area": "docker-app", "args": ["arr", action]})
            self.assertEqual(s, 200, action)
            self.assertEqual(d["status"], "ok", action)
            self.assertEqual(len(self.calls), 1, action)

    def test_refused_shapes(self):
        bad = (["arr"], ["arr", "deploy"], ["BadApp", "start"], ["arr", "start", "extra"])
        for a in bad:
            self.calls.clear()
            self.assertEqual(self.post("/api/plan", {"area": "docker-app", "args": list(a)})[0], 400, a)
            self.assertEqual(self.post("/api/start", {"area": "docker-app", "args": list(a)})[0], 400, a)
            self.assertEqual(self.calls, [], a)
        self.assertEqual(self.post("/api/start", {"area": "docker-app", "args": ["arr", "start"], "stdin": "x"})[0], 400)

    def test_valid_plan_argv(self):
        self.answer = (0, "status\tok\n")
        s, d = self.post("/api/plan", {"area": "docker-app", "args": ["arr", "pull"]})
        self.assertEqual(s, 200)
        cmd = self.calls[0][0]
        self.assertTrue(cmd[-4:] == ["docker-app", "plan", "arr", "pull"] or cmd[-2:] == ["arr", "pull"], cmd)

    def test_valid_start_argv(self):
        self.answer = (0, "status\tdone\n")
        s, d = self.post("/api/start", {"area": "docker-app", "args": ["arr", "restart"]})
        self.assertEqual(s, 200)
        self.assertIn("start", self.calls[0][0])

    def test_delete_data_flag(self):
        self.answer = (0, "status\tok\n")
        for args in (["arr", "delete"], ["arr", "delete", "--delete-data"]):
            self.assertEqual(self.post("/api/plan", {"area": "docker-app", "args": args})[0], 200, args)
        self.assertEqual(self.post("/api/plan", {"area": "docker-app", "args": ["arr", "delete", "--force"]})[0], 400)
        self.assertEqual(self.post("/api/plan", {"area": "docker-app", "args": ["arr", "rebuild", "--delete-data"]})[0], 400)

    def test_registry_entries(self):
        self.answer = (0, "status\tok\n")
        add = ["add", "ghcr.io", "--user", "wolf"]
        s, d = self.post("/api/plan", {"area": "docker-registry", "args": add})
        self.assertEqual(s, 200)
        self.assertIn("docker-registry", self.calls[-1][0])
        s, d = self.post("/api/start", {"area": "docker-registry", "args": add, "stdin": "ghp_secrettoken"})
        self.assertEqual(s, 200)
        self.assertNotIn("ghp_secrettoken", " ".join(self.calls[-1][0]))          # the token is on stdin only
        self.assertIn(b"ghp_secrettoken", self.calls[-1][1])
        self.assertEqual(self.post("/api/plan", {"area": "docker-registry", "args": ["remove", "ghcr.io"]})[0], 200)
        # plans that carried a token are never cached
        self.assertFalse(ws.plan_cacheable("docker-registry", add, "x"))
        self.assertFalse(ws.plan_cacheable("docker-registry", add, None))      # the entry takes stdin
        bad = (["add", "Bad_Host", "--user", "wolf"], ["add", "ghcr.io", "--user", "a b"],
               ["add", "ghcr.io", "--user", "wolf", "--token", "x"], ["remove", "x y"], ["drop", "ghcr.io"])
        for a in bad:
            self.assertEqual(self.post("/api/plan", {"area": "docker-registry", "args": a})[0], 400, a)
        # a token on a remove, and the read
        self.assertEqual(self.post("/api/start", {"area": "docker-registry", "args": ["remove", "ghcr.io"], "stdin": "x"})[0], 400)

    def test_reads(self):
        s, d, _ = self.req("GET", "/api/sys/docker/apps", headers=self.ck)
        self.assertEqual(s, 200)
        s, d, _ = self.req("GET", "/api/sys/docker/logs/arr?lines=100", headers=self.ck)
        self.assertEqual(s, 200)
        s, d, _ = self.req("GET", "/api/sys/docker/logs/BadApp", headers=self.ck)
        self.assertEqual(s, 404)
        s, d, _ = self.req("GET", "/api/sys/docker/logs/arr?lines=abc", headers=self.ck)
        self.assertEqual(s, 404)
        s, d, _ = self.req("GET", "/api/sys/docker/logs/arr?lines=12345", headers=self.ck)
        self.assertEqual(s, 404)


class DockerAppDocument(lt.Base):
    def setUp(self):
        super().setUp()
        self.calls = []
        self.answer = (0, "status\tok\n")
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
        try:
            d = json.loads(d)
        except Exception:
            d = d
        return s, d

    def test_allowed_document_plan(self):
        body = {"area": "docker-app", "args": ["arr", "app-save", "--rev", "new"],
                "document": {"compose": "services:\n  x:\n    image: y\n", "set": {"FOO": "bar"}, "remove": []}}
        s, d = self.post("/api/plan", body)
        self.assertEqual(s, 200)
        self.assertEqual(d["status"], "ok")
        cmd, stdin = self.calls[0]
        self.assertIn("plan", cmd)
        # stdin is the serialized bytes
        self.assertIsInstance(stdin, (bytes, bytearray, str))

    def test_refused_shapes(self):
        bad_docs = [
            {"compose": "x" * 262145, "set": {}, "remove": []},
            {"compose": "a\x00b", "set": {}, "remove": []},
            {"compose": "x", "set": {"1BAD": "v"}, "remove": []},
            {"compose": "x", "set": {"A": "a" * 4097}, "remove": []},
            {"compose": "x", "set": {"A": "a\nb"}, "remove": []},
            {"compose": "x", "set": {}, "remove": ["1BAD"]},
        ]
        for doc in bad_docs:
            self.calls.clear()
            body = {"area": "docker-app", "args": ["arr", "app-save", "--rev", "new"], "document": doc}
            self.assertEqual(self.post("/api/plan", body)[0], 400, doc)
            self.assertEqual(self.calls, [], doc)
        # document with stdin or selection
        self.assertEqual(self.post("/api/plan", {"area": "docker-app", "args": ["arr", "app-save", "--rev", "new"], "document": {"compose": "x", "set": {}, "remove": []}, "stdin": "pw"})[0], 400)
        # missing fields
        self.assertEqual(self.post("/api/plan", {"area": "docker-app", "args": ["arr", "app-save", "--rev", "new"], "document": {"compose": "x"}})[0], 400)
        # bad rev
        self.assertEqual(self.post("/api/plan", {"area": "docker-app", "args": ["arr", "app-save", "--rev", "ZZZZ"], "document": {"compose": "x", "set": {}, "remove": []}})[0], 400)
        # document on rebuild rejected
        self.assertEqual(self.post("/api/plan", {"area": "docker-app", "args": ["arr", "rebuild"], "document": {"compose": "x", "set": {}, "remove": []}})[0], 400)
        # too many names
        big = {f"N{i}": "v" for i in range(201)}
        self.assertEqual(self.post("/api/plan", {"area": "docker-app", "args": ["arr", "app-save", "--rev", "new"], "document": {"compose": "x", "set": big, "remove": []}})[0], 400)

    def test_env_text_document(self):
        doc = {"compose": "services:\n  x:\n    image: y\n", "env": "A=1\nB=two words\n"}
        body = {"area": "docker-app", "args": ["arr", "app-save", "--rev", "new"], "document": doc}
        s, d = self.post("/api/plan", body)
        self.assertEqual(s, 200)
        cmd, stdin = self.calls[0]
        self.assertEqual(stdin, doc["compose"].encode() + b"\0*" + doc["env"].encode() + b"\0")

    def test_env_text_refused(self):
        base = {"area": "docker-app", "args": ["arr", "app-save", "--rev", "new"]}
        for doc in (
            {"compose": "x", "env": "A=1\r\n"},
            {"compose": "x", "env": "A=\x00"},
            {"compose": "x", "env": "A" * 65537},
            {"compose": "x", "env": 5},
            {"compose": "x", "env": "A=1", "set": {}},
            {"compose": "x", "env": "A=1", "set": {}, "remove": []},
        ):
            self.calls.clear()
            self.assertEqual(self.post("/api/plan", {**base, "document": doc})[0], 400, doc)
            self.assertEqual(self.calls, [], doc)
        self.assertEqual(self.post("/api/plan", {**base, "document": {"compose": "x", "env": "A" * 65536}})[0], 200)

    def test_plan_cacheable_false(self):
        # document plans are never cached: call plan twice -> _run twice
        body = {"area": "docker-app", "args": ["arr", "app-save", "--rev", "new"], "document": {"compose": "x", "set": {}, "remove": []}}
        self.post("/api/plan", body)
        self.post("/api/plan", body)
        self.assertEqual(len(self.calls), 2)


if __name__ == "__main__":
    unittest.main(verbosity=1)
