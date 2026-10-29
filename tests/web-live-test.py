#!/usr/bin/env python3
"""scripts/web-serve.py: the StateStore interface. Mode off answers exactly as before (same calls, same X-HS-Age); a store set on app.store is
what `_sys` uses. Real HTTP server on a free port, fake helpers, `_run` replaced (no processes)."""
import http.client
import importlib.util
import json
import os
import tempfile
import threading
import unittest

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("web_serve", os.path.join(here, "..", "scripts", "web-serve.py"))
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)
os.environ["HS_WEB_QUIET"] = "1"
os.environ["HS_STATE_DIR"] = tempfile.mkdtemp()


class FakeAuth:
    def __init__(self, cfg):
        self.cfg = cfg

    def storage_locked(self):
        return False

    def domain_password_ok(self, user, password):
        return user == "anna" and password == "pw"

    def domain_is_admin(self, user):
        return user == "anna"

    def local_password_ok(self, user, password):
        return False


class Fake:
    """what `hs sys <words>` would print; every call is counted"""

    def __init__(self):
        self.calls = []

    def __call__(self, cmd, stdin=None, timeout=10):
        self.calls.append(tuple(cmd[2:]))
        return 0, "a\tb\n"


class FakeStore(ws.StateStore):
    def __init__(self):
        self.asked = []

    def get(self, spec, argv, key, fresh=False):
        self.asked.append((tuple(key), fresh))
        return 200, {"from": "fake"}, 7, (("X-HS-Stale", "99"),)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.tmp, "assets"))
        cfg = ws.Config()
        cfg.root, cfg.workgroup, cfg.realm, cfg.fail_delay = self.tmp, "HOME", "ad.home.lan", 0
        cfg.hs = "/nonexistent/hs"
        self.cfg = cfg
        self.fake, self.real_run = Fake(), ws._run
        ws._run = self.fake
        self.app = ws.App(cfg, FakeAuth(cfg))
        self.srv = ws.Server(("127.0.0.1", 0), ws.make_handler(self.app))
        self.port = self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        r = self.req("POST", "/api/login", {"realm": "domain", "user": "anna", "password": "pw"})[2]
        self.ck = {"Cookie": (r.getheader("Set-Cookie") or "").split(";")[0]}
        self.fake.calls.clear()

    def tearDown(self):
        ws._run = self.real_run
        self.srv.shutdown()
        self.srv.server_close()

    def req(self, method, path, body=None, headers=None):
        h = dict(headers or {})
        if body is not None:
            h["Content-Type"] = "application/json"
        if method == "POST":
            h.setdefault("Origin", "http://127.0.0.1:%d" % self.port)
        c = http.client.HTTPConnection("127.0.0.1", self.port)
        c.request(method, path, json.dumps(body) if body is not None else None, h)
        r = c.getresponse()
        out = (r.status, r.read(), r)
        c.close()
        return out


class OffMode(Base):
    def test_config_defaults(self):
        self.assertEqual(ws.Config().live, "")
        self.assertFalse(ws.features(ws.Config())["live"])
        self.assertEqual(ws.Config().events_max, 32)
        self.assertEqual(ws.Config().live_socket, "/run/redis-hobnix/redis.sock")

    def test_the_default_store_is_off(self):
        self.assertIsInstance(self.app.store, ws.OffStore)
        self.assertIs(self.app.store.reads, self.app.reads)
        self.assertIsNone(self.app.store.subscribe(lambda t, g: None))
        self.assertIsNone(self.app.store.request("status"))

    def test_status_is_read_directly_with_the_cache_age(self):
        s, d, r = self.req("GET", "/api/sys/status", headers=self.ck)
        self.assertEqual(s, 200)
        self.assertEqual(self.fake.calls, [("status",)])
        self.assertEqual(r.getheader("X-HS-Age"), "0")
        self.assertIsNone(r.getheader("X-HS-Stale"))
        self.req("GET", "/api/sys/status", headers=self.ck)
        self.assertEqual(self.fake.calls, [("status",)])          # the second ask comes from the short cache

    def test_fresh_runs_again(self):
        self.req("GET", "/api/sys/status", headers=self.ck)
        s, d, r = self.req("GET", "/api/sys/status?fresh=1", headers=self.ck)
        self.assertEqual((s, r.getheader("X-HS-Age")), (200, "0"))
        self.assertEqual(len(self.fake.calls), 2)

    def test_the_status_read_has_a_topic(self):
        self.assertEqual(ws.READS[("status",)]["topic"], "status")


class FakeStoreUsed(Base):
    def test_sys_goes_through_app_store(self):
        self.app.store = FakeStore()
        s, d, r = self.req("GET", "/api/sys/status", headers=self.ck)
        self.assertEqual((s, json.loads(d)), (200, {"from": "fake"}))
        self.assertEqual(r.getheader("X-HS-Age"), "7")
        self.assertEqual(r.getheader("X-HS-Stale"), "99")
        self.assertEqual(self.app.store.asked, [(("status",), False)])
        self.assertEqual(self.fake.calls, [])
        self.req("GET", "/api/sys/status?fresh=1", headers=self.ck)
        self.assertEqual(self.app.store.asked[-1], (("status",), True))

    def test_still_needs_a_session(self):
        self.app.store = FakeStore()
        self.assertEqual(self.req("GET", "/api/sys/status")[0], 401)
        self.assertEqual(self.app.store.asked, [])


class FakeRedis:
    """what the Redis socket holds: keys and the PUBLISH log; down = every connection is refused"""

    def __init__(self):
        self.keys, self.published, self.down, self.on_publish = {}, [], False, None


class FakeResp:
    redis = None

    def __init__(self, path=None, timeout=1.0):
        if FakeResp.redis.down:
            raise OSError("cannot connect")

    def cmd(self, *a):
        if a[0] == "GET":
            return FakeResp.redis.keys.get(a[1])
        if a[0] == "PUBLISH":
            FakeResp.redis.published.append((a[1], a[2]))
            if FakeResp.redis.on_publish:
                FakeResp.redis.on_publish(a[2])
            return 1

    def close(self):
        pass


def doc(out="a\tb\n", gen=1, age=3, **kw):
    import time
    d = {"ts": time.time() - age, "gen": gen, "rc": 0, "out": out, "err": None, "ts_err": None}
    d.update(kw)
    return json.dumps(d)


class RedisBase(Base):
    def setUp(self):
        self.redis = FakeRedis()
        FakeResp.redis = self.redis
        self.real_resp, ws.ls.Resp = ws.ls.Resp, FakeResp
        self.real_wait = ws.RedisStore.FRESH_WAIT
        os.environ["HS_WEB_LIVE"] = "redis"
        super().setUp()

    def tearDown(self):
        super().tearDown()
        ws.ls.Resp = self.real_resp
        ws.RedisStore.FRESH_WAIT = self.real_wait
        os.environ.pop("HS_WEB_LIVE", None)


class RedisMode(RedisBase):
    def test_store_and_feature(self):
        self.assertIsInstance(self.app.store, ws.RedisStore)
        self.assertTrue(ws.features(self.cfg)["live"])
        os.environ.pop("HS_WEB_LIVE")
        self.assertFalse(ws.features(ws.Config())["live"])

    def test_status_comes_from_the_key(self):
        self.redis.keys["hs:v1:status"] = doc("x\ty\n", age=4)
        s, d, r = self.req("GET", "/api/sys/status", headers=self.ck)
        self.assertEqual((s, json.loads(d)["rows"]), (200, [["x", "y"]]))
        self.assertIn(r.getheader("X-HS-Age"), ("4", "5"))
        self.assertIsNone(r.getheader("X-HS-Stale"))
        self.assertEqual(self.fake.calls, [])

    def test_redis_down_is_503(self):
        self.redis.down = True
        s, d, r = self.req("GET", "/api/sys/status", headers=self.ck)
        self.assertEqual((s, json.loads(d)["error"]), (503, "state service down"))
        self.assertEqual(self.fake.calls, [])

    def test_missing_key_asks_for_a_refresh(self):
        s, d, r = self.req("GET", "/api/sys/status", headers=self.ck)
        self.assertEqual((s, json.loads(d)), (503, {"error": "refreshing", "retry_after": 2}))
        self.assertEqual(r.getheader("Retry-After"), "2")
        self.assertEqual(self.redis.published, [("hs:v1:refresh", "status")])

    def test_newer_error_marks_it_stale(self):
        import time
        self.redis.keys["hs:v1:status"] = doc(age=60, err="boom", ts_err=time.time() - 5)
        s, d, r = self.req("GET", "/api/sys/status", headers=self.ck)
        self.assertEqual(s, 200)
        self.assertTrue(r.getheader("X-HS-Stale"))
        self.redis.keys["hs:v1:status"] = doc(age=5, err="old", ts_err=time.time() - 60)
        self.assertIsNone(self.req("GET", "/api/sys/status", headers=self.ck)[2].getheader("X-HS-Stale"))

    def test_fresh_waits_for_a_new_gen(self):
        self.redis.keys["hs:v1:status"] = doc("old\n", gen=1)
        self.redis.on_publish = lambda t: self.redis.keys.__setitem__("hs:v1:status", doc("new\n", gen=2, age=0))
        s, d, r = self.req("GET", "/api/sys/status?fresh=1", headers=self.ck)
        self.assertEqual((s, json.loads(d)["rows"]), (200, [["new"]]))
        self.assertEqual(self.redis.published, [("hs:v1:refresh", "status")])

    def test_fresh_gives_up_and_serves_what_it_has(self):
        ws.RedisStore.FRESH_WAIT = 0.3
        self.redis.keys["hs:v1:status"] = doc("old\n", gen=1)
        s, d, r = self.req("GET", "/api/sys/status?fresh=1", headers=self.ck)
        self.assertEqual((s, json.loads(d)["rows"]), (200, [["old"]]))

    def test_reads_without_a_topic_still_run(self):
        s, d, r = self.req("GET", "/api/sys/ct/list", headers=self.ck)
        self.assertEqual(s, 200)
        self.assertEqual(self.fake.calls, [("ct", "list")])

    def test_warm_up_skips_topics(self):
        self.assertNotIn(("status",), [tuple(a[2]) for a in self.app.reads.warm_targets()])

    def test_a_started_change_asks_for_everything(self):
        ch = dict(self.ck, **{"X-CSRF-Token": self.csrf()})
        self.assertEqual(self.req("POST", "/api/plan", {"area": "ct", "args": ["web1", "restart"]}, ch)[0], 200)
        self.assertEqual(self.redis.published, [])
        self.assertEqual(self.req("POST", "/api/start", {"area": "ct", "args": ["web1", "restart"]}, ch)[0], 200)
        self.assertEqual(self.redis.published, [("hs:v1:refresh", "*")])

    def test_login_facts_read_the_stored_status(self):
        self.redis.keys["hs:v1:status"] = doc("instances\t3\t4\n")
        facts = ws.Facts(self.cfg)._read(False)
        self.assertEqual(facts[0]["text"], "3 of 4 instances running")
        self.assertEqual(self.fake.calls, [])

    def test_login_facts_fall_back_to_the_command(self):
        ws.Facts(self.cfg)._read(False)
        self.assertEqual(self.fake.calls[0], ("status",))

    def csrf(self):
        return json.loads(self.req("GET", "/api/session", headers=self.ck)[1])["csrf"]


class Hub(RedisBase):
    """Events._run against the fake Redis: backoff and the catch-up after a reconnect."""

    def run_hub(self, subscribes):
        waits, seen = [], []
        hub = ws.Events(self.cfg)
        q = hub.add()
        script = list(subscribes)

        class R(FakeResp):
            def subscribe(self, channel):
                step = script.pop(0)
                if step is None:
                    raise OSError("down")
                for m in step:
                    yield channel, m
                raise OSError("lost")

        class Stop(Exception):
            pass

        def sleep(t):
            waits.append(t)
            if not script:
                raise Stop()
        hub.sleep = sleep
        ws.ls.Resp = R
        try:
            hub._run()
        except Stop:
            pass
        while not q.empty():
            seen.append(q.get())
        return waits, seen

    def test_backoff_doubles_and_is_capped(self):
        waits, _ = self.run_hub([None] * 8)
        self.assertEqual(waits, [1, 2, 4, 8, 16, 30, 30, 30])

    def test_a_message_resets_the_backoff(self):
        waits, _ = self.run_hub([None, None, ["status 1"], None])
        self.assertEqual(waits, [1, 2, 1, 2])

    def test_reconnect_announces_every_topic(self):
        self.redis.keys["hs:v1:status"] = doc(gen=7)
        waits, seen = self.run_hub([["status 8"], ["status 9"]])
        topics = [r[0] for r in ws.ls.topics()]
        self.assertEqual(seen.count(("up",)), 2)
        self.assertEqual(seen.count(("down",)), 2)
        self.assertIn(("changed", "status", 7), seen)
        self.assertEqual(len([m for m in seen if m[0] == "changed" and m[2] in (7, 0)]), 2 * len(topics))


class Events(RedisBase):
    def open(self, path="/api/events", headers=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        c.request("GET", path, headers=headers if headers is not None else self.ck)
        return c, c.getresponse()

    def test_needs_a_session(self):
        self.assertEqual(self.req("GET", "/api/events")[0], 401)

    def test_foreign_origin_is_refused(self):
        s = self.req("GET", "/api/events", headers=dict(self.ck, Origin="http://evil.example"))[0]
        self.assertEqual(s, 403)

    def test_off_mode_is_404(self):
        self.cfg.live = ""
        self.assertEqual(self.req("GET", "/api/events", headers=self.ck)[0], 404)

    def test_too_many_streams(self):
        self.cfg.events_max = 0
        self.assertEqual(self.req("GET", "/api/events", headers=self.ck)[0], 503)

    def test_a_changed_frame_arrives(self):
        c, r = self.open(headers=dict(self.ck, Origin="http://127.0.0.1:%d" % self.port))
        try:
            self.assertEqual((r.status, r.getheader("Content-Type")), (200, "text/event-stream"))
            self.assertEqual(r.fp.readline(), b"retry: 3000\n")
            r.fp.readline()
            for _ in range(100):
                if self.app.events.queues:
                    break
                threading.Event().wait(0.02)
            self.app.events.feed("changed", "status", 5)
            self.assertEqual(r.fp.readline(), b"event: changed\n")
            self.assertEqual(json.loads(r.fp.readline()[len(b"data: "):]), {"topic": "status", "gen": 5})
        finally:
            c.close()

    def test_the_counter_goes_back(self):
        c, r = self.open()
        r.fp.readline()
        r.close()
        c.close()
        for _ in range(100):
            self.app.events.feed("down")
            if self.app.event_streams == 0:
                break
            threading.Event().wait(0.05)
        self.assertEqual(self.app.event_streams, 0)


if __name__ == "__main__":
    unittest.main()
