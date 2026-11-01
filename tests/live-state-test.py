#!/usr/bin/env python3
"""scripts/live_state.py and scripts/live-collect.py with a fake store and a stub run (no Redis, no processes)."""
import importlib.util
import io
import json
import os
import socket
import tempfile
import threading
import unittest

here = os.path.dirname(os.path.abspath(__file__))
scripts = os.path.join(here, "..", "scripts")
import sys
sys.path.insert(0, scripts)
import live_state as ls  # noqa: E402

spec = importlib.util.spec_from_file_location("live_collect", os.path.join(scripts, "live-collect.py"))
lc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lc)


class FakeResp:
    def __init__(self):
        self.data = {}
        self.published = []

    def cmd(self, *a):
        if a[0] == "GET":
            return self.data.get(a[1])
        if a[0] == "SET":
            self.data[a[1]] = a[2]
            return "OK"
        if a[0] == "PUBLISH":
            self.published.append((a[1], a[2]))
            return 1
        raise AssertionError(a)

    def close(self):
        pass


class Collect(unittest.TestCase):
    rows = [("status", ["status"], 15, "run"), ("slow", ["slow"], 60, "skip")]

    def make(self, results):
        calls = []

        def run(words):
            calls.append(words)
            return results.pop(0)
        st = FakeResp()
        return lc.Collector(st, run=run, topic_rows=self.rows), st, calls

    def test_success_sets_key_and_publishes(self):
        c, st, _ = self.make([(0, "ok\n", ""), (0, "ok2\n", "")])
        self.assertTrue(c.collect("status", ["status"]))
        d = json.loads(st.data["hs:v1:status"])
        self.assertEqual((d["gen"], d["rc"], d["out"], d["err"]), (1, 0, "ok\n", None))
        c.collect("status", ["status"])
        self.assertEqual(json.loads(st.data["hs:v1:status"])["gen"], 2)
        self.assertEqual(st.published, [("hs:v1:changed", "status 1"), ("hs:v1:changed", "status 2")])

    def test_nonzero_with_output_counts_as_data(self):
        c, st, _ = self.make([(1, "partial", "boom")])
        self.assertTrue(c.collect("status", ["status"]))
        self.assertEqual(json.loads(st.data["hs:v1:status"])["rc"], 1)

    def test_failure_keeps_data_and_sets_err(self):
        c, st, _ = self.make([(0, "good", ""), (2, "", "x" * 300)])
        c.collect("status", ["status"])
        old = json.loads(st.data["hs:v1:status"])
        self.assertFalse(c.collect("status", ["status"]))
        d = json.loads(st.data["hs:v1:status"])
        self.assertEqual((d["out"], d["ts"], d["gen"]), ("good", old["ts"], 1))
        self.assertEqual(len(d["err"]), 200)
        self.assertGreaterEqual(d["ts_err"], d["ts"])
        self.assertEqual(len(st.published), 1)

    def test_locked_skip_runs_nothing(self):
        marker = os.path.join(tempfile.mkdtemp(), "locked")
        open(marker, "w").close()
        os.environ["HS_LOCKED_MARKER"] = marker
        try:
            c, st, calls = self.make([(0, "x", ""), (0, "y", "")])
            self.assertFalse(c.collect("slow", ["slow"], "skip"))
            self.assertEqual(calls, [])
            self.assertTrue(c.collect("status", ["status"], "run"))
        finally:
            del os.environ["HS_LOCKED_MARKER"]

    def test_refresh_wakes_the_right_topic(self):
        c, _, _ = self.make([])
        c.refresh("slow")
        self.assertFalse(c.events["status"].is_set())
        self.assertTrue(c.events["slow"].is_set())
        c.refresh("*")
        self.assertTrue(c.events["status"].is_set())


class Reconnect(unittest.TestCase):
    def test_old_store_is_closed_before_the_new_one(self):
        closed, fresh = [], FakeResp()

        class Dead:
            def cmd(self, *a):
                raise OSError("gone")

            def close(self):
                closed.append(1)

        class Stop:
            def __init__(self, c):
                self.c = c

            def is_set(self):
                return bool(closed and self.c.store is fresh)

            def wait(self, t=None):
                return False

        c = lc.Collector(Dead(), run=lambda w: (0, "x\n", ""), topic_rows=[("status", ["status"], 15, "run")],
                         connect=lambda: fresh)
        c.stop = Stop(c)
        c.loop("status", ["status"], 15, "run")
        self.assertEqual(closed, [1])
        self.assertIs(c.store, fresh)


class Groups(unittest.TestCase):
    rows = [("a", ["a"], 15, "run"), ("b", ["b"], 15, "run"), ("c", ["c"], 15, "run"), ("d", ["d"], 15, "run")]
    info = {"a": {"cap": None, "groups": {"disks"}}, "b": {"cap": None, "groups": {"any"}},
            "c": {"cap": None, "groups": {"shares", "disks"}}, "d": {"cap": "nosuchcap", "groups": {"disks"}}}

    def make(self, run=None, **kw):
        return lc.Collector(FakeResp(), run=run or (lambda w: (0, "x", "")), topic_rows=self.rows, topic_info=self.info, **kw)

    def set_of(self, c):
        return sorted(t for t, ev in c.events.items() if ev.is_set())

    def test_group_wakes_its_topics_and_any(self):
        c = self.make()
        c.refresh("@disks")
        self.assertEqual(self.set_of(c), ["a", "b", "c", "d"])
        c = self.make()
        c.refresh("@shares")
        self.assertEqual(self.set_of(c), ["b", "c"])
        c = self.make()
        c.refresh("@nothing")
        self.assertEqual(self.set_of(c), ["b"])

    def test_system_groups_wake_the_system_topics(self):
        rows, info = ls.topics(), ls.topic_info()
        c = lc.Collector(FakeResp(), run=lambda w: (0, "x", ""), topic_rows=rows, topic_info=info)
        c.refresh("@jobs")
        woken = self.set_of(c)
        for t in ("jobs-running", "jobs-list", "deck", "status", "live", "health-next", "setup-list"):
            self.assertIn(t, woken)
        for t in ("ups", "hardware", "ssh-keys", "pool-info-bulk"):
            self.assertNotIn(t, woken)
        c = lc.Collector(FakeResp(), run=lambda w: (0, "x", ""), topic_rows=rows, topic_info=info)
        c.refresh("@security")
        self.assertIn("ssh-keys", self.set_of(c))
        self.assertIn("config-list", self.set_of(c))

    def test_exact_name_and_all(self):
        c = self.make()
        c.refresh("a")
        self.assertEqual(self.set_of(c), ["a"])
        c.refresh("*")
        self.assertEqual(len(self.set_of(c)), 4)

    def test_cap_off_topic_is_not_run(self):
        calls = []
        c = self.make(run=lambda w: calls.append(w) or (0, "x", ""))
        ls._CAP_CACHE["nosuchcap"] = (__import__("time").time(), False)
        try:
            self.assertFalse(c.collect("d", ["d"]))
            self.assertEqual((calls, c.store.data), ([], {}))
            self.assertTrue(c.collect("a", ["a"]))
        finally:
            ls._CAP_CACHE.clear()

    def test_semaphore_limits_parallel_reads(self):
        import time
        state = {"now": 0, "max": 0}
        lk = threading.Lock()

        def run(words):
            with lk:
                state["now"] += 1
                state["max"] = max(state["max"], state["now"])
            time.sleep(0.05)
            with lk:
                state["now"] -= 1
            return 0, "x", ""
        os.environ["HS_LIVE_PARALLEL"] = "2"
        try:
            c = self.make(run=run)
        finally:
            del os.environ["HS_LIVE_PARALLEL"]
        ts = [threading.Thread(target=c.collect, args=(t, [t])) for t in "aabbcc"]
        for t in ts:
            t.start()
        for t in ts:
            t.join()
        self.assertLessEqual(state["max"], 2)
        self.assertGreaterEqual(state["max"], 1)


SYSTEM_TOPICS = {'deck': 5, 'jobs-running': 10, 'jobs-list': 30, 'health-next': 30, 'health-list': 60, 'hardware': 15, 'ups': 30, 'system-updates': 60, 'system-config': 300, 'setup-list': 30, 'config-list': 60, 'parts-list': 60, 'node-list': 30, 'ssh-keys': 60, 'expiry': 300, 'notify-channels': 60, 'notify-providers': 3600}


class Cli(unittest.TestCase):
    def test_six_column_parse(self):
        info = ls.topic_info()
        self.assertEqual(info["status"], {"cap": None, "groups": {"any"}})
        self.assertEqual(info["temp-disks"]["groups"], {"disks", "shares"})
        self.assertEqual(info["vault-list"]["groups"], {"security"})
        self.assertEqual(set(info), {t[0] for t in ls.topics()})

    def test_system_topics_info(self):
        info = ls.topic_info()
        self.assertEqual(set(SYSTEM_TOPICS) - set(info), set())
        self.assertEqual(info["deck"], {"cap": None, "groups": {"any"}})
        self.assertEqual(info["jobs-running"]["groups"], {"any", "jobs"})
        self.assertEqual(info["config-list"]["groups"], {"system", "network", "security", "backup"})
        self.assertEqual(info["notify-channels"], {"cap": "notifications", "groups": {"system"}})
        self.assertEqual(info["notify-providers"], {"cap": "notifications", "groups": set()})
        rows = {t[0]: t for t in ls.topics()}
        self.assertEqual(rows["system-updates"][3], "skip")
        self.assertEqual(rows["ups"][1], ["ups", "status"])

    def test_topic_info_cap_and_dash(self):
        p = os.path.join(tempfile.mkdtemp(), "t.tsv")
        with open(p, "w") as f:
            f.write("# c\nx\tx\t5\trun\tgateway\tnetwork,any\ny\ty\t5\trun\n")
        self.assertEqual(ls.topic_info(p), {"x": {"cap": "gateway", "groups": {"network", "any"}}, "y": {"cap": None, "groups": set()}})

    def test_check_skips_cap_off_topic(self):
        import time
        p = os.path.join(tempfile.mkdtemp(), "t.tsv")
        with open(p, "w") as f:
            f.write("old\told\t5\trun\tnosuchcap\tdisks\n")
        real_t, real_i = ls.topics, ls.topic_info
        ls.topics, ls.topic_info = (lambda: real_t(p)), (lambda: real_i(p))
        ls._CAP_CACHE["nosuchcap"] = (time.time(), False)
        out = io.StringIO()
        st = FakeResp()
        st.data["hs:v1:old"] = json.dumps({"ts": time.time() - 999, "gen": 1, "rc": 0, "out": "x", "err": None, "ts_err": None})
        try:
            self.assertEqual(ls.cli_check(conn=st, out=out), 0)
            self.assertEqual(out.getvalue(), "")
        finally:
            ls.topics, ls.topic_info = real_t, real_i
            ls._CAP_CACHE.clear()

    def fake(self, ts, err=None, ts_err=None):
        st = FakeResp()
        st.data["hs:v1:status"] = json.dumps({"ts": ts, "gen": 4, "rc": 0, "out": "x", "err": err, "ts_err": ts_err})
        return st

    def test_topics_skip_comments(self):
        self.assertEqual(ls.topics(), [
            ('status', ['status'], 15, 'run'),
            ('live', ['live', 'status'], 5, 'run'),
            ('monitor-disks', ['monitor', 'disks'], 15, 'run'),
            ('disk-health', ['disk-health', 'list'], 30, 'run'),
            ('disk-inventory', ['state', 'disks'], 30, 'run'),
            ('disk-marks', ['disk', 'marks'], 15, 'run'),
            ('pool-info-bulk', ['pool', 'info', 'bulk'], 15, 'skip'),
            ('pool-info-fast', ['pool', 'info', 'fast'], 15, 'skip'),
            ('pool-members-bulk', ['pool', 'members', 'bulk'], 15, 'skip'),
            ('pool-members-fast', ['pool', 'members', 'fast'], 15, 'skip'),
            ('pool-state-bulk', ['pool', 'state', 'bulk'], 10, 'run'),
            ('pool-state-fast', ['pool', 'state', 'fast'], 10, 'run'),
            ('shares-overview', ['shares', 'overview'], 30, 'skip'),
            ('shares-deleted', ['shares', 'deleted'], 60, 'skip'),
            ('shares-principals', ['shares', 'principals'], 60, 'skip'),
            ('encryption', ['encryption', 'list'], 30, 'run'),
            ('vault-list', ['vault', 'list'], 60, 'run'),
            ('vault-usage', ['vault', 'usage'], 30, 'run'),
            ('vault-uses', ['vault', 'uses'], 60, 'run'),
            ('state-history', ['state', 'history'], 30, 'run'),
            ('fm-locations', ['fm', 'locations'], 15, 'run'),
            ('temp-disks', ['temp-disk', 'raw'], 30, 'run'),
            ('deck', ['deck'], 5, 'run'),
            ('jobs-running', ['jobs', 'running'], 10, 'run'),
            ('jobs-list', ['jobs', 'list'], 30, 'run'),
            ('health-next', ['health', 'next'], 30, 'run'),
            ('health-list', ['health', 'list'], 60, 'run'),
            ('hardware', ['hardware'], 15, 'run'),
            ('ups', ['ups', 'status'], 30, 'run'),
            ('system-updates', ['system', 'updates'], 60, 'skip'),
            ('system-config', ['system', 'config'], 300, 'run'),
            ('setup-list', ['setup', 'list'], 30, 'run'),
            ('config-list', ['config', 'list'], 60, 'run'),
            ('parts-list', ['parts', 'list'], 60, 'run'),
            ('node-list', ['node', 'list'], 30, 'run'),
            ('ssh-keys', ['ssh-key', 'list'], 60, 'run'),
            ('expiry', ['expiry', 'list'], 300, 'run'),
            ('notify-channels', ['notify', 'channels'], 60, 'run'),
            ('notify-providers', ['notify', 'providers'], 3600, 'run'),
        ])

    def test_status_shape(self):
        import time
        out = io.StringIO()
        self.assertEqual(ls.cli_status(self.fake(time.time() - 7), out), 0)
        lines = out.getvalue().rstrip("\n").split("\n")
        self.assertEqual(len(lines), 39)
        status = [l for l in lines if l.startswith("status\t")][0].split("\t")
        live = [l for l in lines if l.startswith("live\t")][0].split("\t")
        self.assertEqual(len(status), 7)
        self.assertEqual((status[0], status[1], status[3], status[4], status[5], status[6]), ("status", "15", "4", "0", "-", "-"))
        self.assertIn(int(status[2]), (7, 8))
        self.assertEqual((live[0], live[1], live[3], live[4], live[5], live[6]), ("live", "5", "0", "-", "-", "-"))
        self.assertEqual(live[2], "-1")

    def test_status_without_data(self):
        out = io.StringIO()
        ls.cli_status(FakeResp(), out)
        lines = sorted(out.getvalue().rstrip("\n").split("\n"))
        old = ['disk-health	30	-1	0	-	-	-', 'disk-inventory	30	-1	0	-	-	-', 'disk-marks	15	-1	0	-	-	-', 'encryption	30	-1	0	-	-	-', 'fm-locations	15	-1	0	-	-	-', 'live	5	-1	0	-	-	-', 'monitor-disks	15	-1	0	-	-	-', 'pool-info-bulk	15	-1	0	-	-	-', 'pool-info-fast	15	-1	0	-	-	-', 'pool-members-bulk	15	-1	0	-	-	-', 'pool-members-fast	15	-1	0	-	-	-', 'pool-state-bulk	10	-1	0	-	-	-', 'pool-state-fast	10	-1	0	-	-	-', 'shares-deleted	60	-1	0	-	-	-', 'shares-overview	30	-1	0	-	-	-', 'shares-principals	60	-1	0	-	-	-', 'state-history	30	-1	0	-	-	-', 'status	15	-1	0	-	-	-', 'temp-disks	30	-1	0	-	-	-', 'vault-list	60	-1	0	-	-	-', 'vault-usage	30	-1	0	-	-	-', 'vault-uses	60	-1	0	-	-	-']
        self.assertEqual(lines, sorted(old + ["%s	%s	-1	0	-	-	-" % (t, iv) for t, iv in SYSTEM_TOPICS.items()]))

    def test_check_fresh_stale_down(self):
        import time
        out = io.StringIO()
        self.assertEqual(ls.cli_check(self.fake(time.time() - 5), out), 0)
        self.assertEqual(out.getvalue(), "")
        self.assertEqual(ls.cli_check(self.fake(time.time() - 100), out), 1)
        self.assertTrue(out.getvalue().startswith("live:stale:status\t"))
        out = io.StringIO()
        os.environ["HS_LIVE_SOCKET"] = "/nonexistent/none.sock"
        try:
            self.assertEqual(ls.cli_check(None, out), 1)
        finally:
            del os.environ["HS_LIVE_SOCKET"]
        self.assertTrue(out.getvalue().startswith("live:down\t"))

    def test_check_includes_stale_live_topic(self):
        import time
        st = FakeResp()
        st.data["hs:v1:status"] = json.dumps({"ts": time.time() - 5, "gen": 1, "rc": 0, "out": "x", "err": None, "ts_err": None})
        st.data["hs:v1:live"] = json.dumps({"ts": time.time() - 20, "gen": 1, "rc": 0, "out": "x", "err": None, "ts_err": None})
        out = io.StringIO()
        self.assertEqual(ls.cli_check(st, out), 1)
        self.assertIn("live:stale:live\t", out.getvalue())

    def test_refresh_publishes_and_never_fails(self):
        st = FakeResp()
        self.assertEqual(ls.cli_refresh(["a", "b"], st), 0)
        self.assertEqual(st.published, [("hs:v1:refresh", "a"), ("hs:v1:refresh", "b")])
        st = FakeResp()
        ls.cli_refresh(["--all"], st)
        self.assertEqual(sorted(p[1] for p in st.published), sorted([t[0] for t in ls.topics()]))
        self.assertEqual(len(st.published), 39)
        os.environ["HS_LIVE_SOCKET"] = "/nonexistent/none.sock"
        try:
            self.assertEqual(ls.cli_refresh(["--all"]), 0)
        finally:
            del os.environ["HS_LIVE_SOCKET"]

    def test_self_read_sees_previous_generation(self):
        """The collector runs the command before its own Redis lock, so cli_status sees the previous live document."""
        import time
        st = FakeResp()
        st.data["hs:v1:status"] = json.dumps({"ts": time.time() - 5, "gen": 1, "rc": 0, "out": "x", "err": None, "ts_err": None})
        st.data["hs:v1:live"] = json.dumps({"ts": time.time() - 2, "gen": 3, "rc": 0, "out": "x", "err": None, "ts_err": None})
        out = io.StringIO()
        ls.cli_status(st, out)
        live = [l for l in out.getvalue().rstrip("\n").split("\n") if l.startswith("live\t")][0].split("\t")
        self.assertEqual(live[3], "3")      # the generation that existed before this collection
        self.assertEqual(st.published, [])  # status does not publish refreshes


@unittest.skipUnless(hasattr(socket, "AF_UNIX"), "no AF_UNIX")
class Wire(unittest.TestCase):
    def test_encode_decode(self):
        self.assertEqual(ls.encode("SET", "k", "v"), b"*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$1\r\nv\r\n")
        d = tempfile.mkdtemp()
        path = os.path.join(d, "s.sock")
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(path)
        srv.listen(1)
        got = []

        def serve():
            c, _ = srv.accept()
            got.append(c.recv(4096))
            c.sendall(b"+OK\r\n:42\r\n$6\r\nh\xc3\xa4llo\r\n$-1\r\n*2\r\n$1\r\na\r\n:7\r\n-ERR no\r\n")
            c.close()
        t = threading.Thread(target=serve, daemon=True)
        t.start()
        r = ls.Resp(path, 2)
        self.assertEqual(r.cmd("PING"), "OK")
        self.assertEqual(got[0], b"*1\r\n$4\r\nPING\r\n")
        self.assertEqual(r.read(), 42)
        self.assertEqual(r.read(), "hällo"[:5] if False else "hällo")
        self.assertIsNone(r.read())
        self.assertEqual(r.read(), ["a", 7])
        with self.assertRaises(OSError):
            r.read()
        with self.assertRaises(OSError):
            r.read()   # closed
        r.close()
        srv.close()

    def test_connect_error_is_oserror(self):
        with self.assertRaises(OSError):
            ls.Resp("/nonexistent/none.sock", 1)


if __name__ == "__main__":
    unittest.main()
