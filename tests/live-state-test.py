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


class Cli(unittest.TestCase):
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
        ])

    def test_status_shape(self):
        import time
        out = io.StringIO()
        self.assertEqual(ls.cli_status(self.fake(time.time() - 7), out), 0)
        lines = out.getvalue().rstrip("\n").split("\n")
        self.assertEqual(len(lines), 22)
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
        self.assertEqual(lines, ['disk-health\t30\t-1\t0\t-\t-\t-', 'disk-inventory\t30\t-1\t0\t-\t-\t-', 'disk-marks\t15\t-1\t0\t-\t-\t-', 'encryption\t30\t-1\t0\t-\t-\t-', 'fm-locations\t15\t-1\t0\t-\t-\t-', 'live\t5\t-1\t0\t-\t-\t-', 'monitor-disks\t15\t-1\t0\t-\t-\t-', 'pool-info-bulk\t15\t-1\t0\t-\t-\t-', 'pool-info-fast\t15\t-1\t0\t-\t-\t-', 'pool-members-bulk\t15\t-1\t0\t-\t-\t-', 'pool-members-fast\t15\t-1\t0\t-\t-\t-', 'pool-state-bulk\t10\t-1\t0\t-\t-\t-', 'pool-state-fast\t10\t-1\t0\t-\t-\t-', 'shares-deleted\t60\t-1\t0\t-\t-\t-', 'shares-overview\t30\t-1\t0\t-\t-\t-', 'shares-principals\t60\t-1\t0\t-\t-\t-', 'state-history\t30\t-1\t0\t-\t-\t-', 'status\t15\t-1\t0\t-\t-\t-', 'temp-disks\t30\t-1\t0\t-\t-\t-', 'vault-list\t60\t-1\t0\t-\t-\t-', 'vault-usage\t30\t-1\t0\t-\t-\t-', 'vault-uses\t60\t-1\t0\t-\t-\t-'])

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
        self.assertEqual(sorted(st.published), [('hs:v1:refresh', 'disk-health'), ('hs:v1:refresh', 'disk-inventory'), ('hs:v1:refresh', 'disk-marks'), ('hs:v1:refresh', 'encryption'), ('hs:v1:refresh', 'fm-locations'), ('hs:v1:refresh', 'live'), ('hs:v1:refresh', 'monitor-disks'), ('hs:v1:refresh', 'pool-info-bulk'), ('hs:v1:refresh', 'pool-info-fast'), ('hs:v1:refresh', 'pool-members-bulk'), ('hs:v1:refresh', 'pool-members-fast'), ('hs:v1:refresh', 'pool-state-bulk'), ('hs:v1:refresh', 'pool-state-fast'), ('hs:v1:refresh', 'shares-deleted'), ('hs:v1:refresh', 'shares-overview'), ('hs:v1:refresh', 'shares-principals'), ('hs:v1:refresh', 'state-history'), ('hs:v1:refresh', 'status'), ('hs:v1:refresh', 'temp-disks'), ('hs:v1:refresh', 'vault-list'), ('hs:v1:refresh', 'vault-usage'), ('hs:v1:refresh', 'vault-uses')])
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
