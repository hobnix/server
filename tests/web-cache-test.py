#!/usr/bin/env python3
"""scripts/web-serve.py: the read cache. Answers survive a restart (cache file), the warm-up keeps every read without arguments and everything
somebody asked for fresh, and an old answer is shown at once while a new one is read. `_run` (the call of `hs sys ...`) is replaced: no processes."""
import importlib.util
import json
import os
import sqlite3
import stat
import tempfile
import time
import unittest

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("web_serve", os.path.join(here, "..", "scripts", "web-serve.py"))
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)
os.environ["HS_WEB_QUIET"] = "1"
_caps = tempfile.NamedTemporaryFile("w", suffix=".caps", delete=False)      # the poster read belongs to the extension package "posters"
_caps.write("posters\n")
_caps.close()
os.environ["HS_CAPABILITIES_FILE"] = _caps.name
os.environ["HS_STATE_DIR"] = tempfile.mkdtemp()
ws.ext_refresh(force=True)


class Fake:
    """what `hs sys <words>` would print; every call is counted"""

    def __init__(self):
        self.calls = []

    def __call__(self, cmd, stdin=None, timeout=10):
        self.calls.append(tuple(cmd[2:]))
        return 0, '{"x": 1}\n'          # valid for every kind of read (JSON, text, rows)


class Cache(unittest.TestCase):
    def setUp(self):
        self.fake = Fake()
        self.real_run = ws._run
        ws._run = self.fake
        self.tmp = tempfile.mkdtemp()
        self.file = os.path.join(self.tmp, "cache.json")
        self.cfg = ws.Config()
        self.cfg.cache_file = self.file

    def tearDown(self):
        ws._run = self.real_run

    def reads(self):
        return ws.Reads(self.cfg)

    def ask(self, r, path, query=None):
        hit = r.resolve(path.split("/"), query or {})
        self.assertIsNotNone(hit, path)
        return r.get_aged(*hit)

    def test_a_second_ask_is_served_from_memory(self):
        r = self.reads()
        self.ask(r, "ct/list")
        self.ask(r, "ct/list")
        self.assertEqual(len(self.fake.calls), 1)

    def test_the_answers_survive_a_restart(self):
        r = self.reads()
        self.ask(r, "ct/list")
        self.ask(r, "shares/overview")
        r.save(self.file)
        self.assertTrue(os.path.isfile(self.file))
        if os.name == "posix":
            self.assertEqual(stat.S_IMODE(os.stat(self.file).st_mode), 0o600)
        n = len(self.fake.calls)
        r2 = self.reads()
        self.assertEqual(r2.load(self.file), 2)
        code, obj, age = self.ask(r2, "ct/list")
        self.assertEqual(code, 200)
        self.assertEqual(obj["rows"][0][0], '{"x": 1}')
        self.assertIsNotNone(age)
        self.assertEqual(len(self.fake.calls), n)       # nothing was run: the old answer came out of the file

    def test_an_answer_past_its_ttl_is_shown_at_once_and_read_again(self):
        r = self.reads()
        self.ask(r, "ct/list")                           # ttl 5
        key = ("ct", "list")
        t, val = r.cache[key]
        r.cache[key] = (t - 100, val)                    # 100 s old: far past the ttl, inside the stale window
        before = len(self.fake.calls)
        code, obj, age = self.ask(r, "ct/list")
        self.assertGreaterEqual(age, 100)
        # the refresh runs in the background
        for _ in range(100):
            if len(self.fake.calls) > before:
                break
            time.sleep(0.02)
        self.assertGreater(len(self.fake.calls), before)

    def test_old_or_foreign_entries_are_not_loaded(self):
        now = time.time()
        items = [{"argv": ["ct", "list"], "t": now - 5, "code": 200, "obj": {"rows": [["a"]], "rc": 0}},
                 {"argv": ["ct", "list", "x"], "t": now, "code": 200, "obj": {}},                       # not an allowlisted shape
                 {"argv": ["nosuch", "read"], "t": now, "code": 200, "obj": {}},
                 {"argv": ["shares", "overview"], "t": now - 99999, "code": 200, "obj": {"rows": [], "rc": 0}},   # older than the stale window
                 {"argv": ["config", "check"], "t": now, "code": 200, "obj": {"text": "", "rc": 0}},    # ttl 0: never kept
                 {"argv": ["status"], "t": now, "code": 502, "obj": {"error": "x"}},                    # an error is not an answer
                 "junk", {"argv": 5}]
        with open(self.file, "w") as f:
            json.dump(items, f)
        r = self.reads()
        self.assertEqual(r.load(self.file), 1)
        self.assertEqual(list(r.cache), [("ct", "list")])

    def test_a_damaged_file_is_ignored(self):
        with open(self.file, "w") as f:
            f.write("{not json")
        self.assertEqual(self.reads().load(self.file), 0)
        self.assertEqual(self.reads().load(os.path.join(self.tmp, "missing.json")), 0)
        self.assertEqual(self.reads().load(""), 0)

    def test_errors_are_not_saved(self):
        r = self.reads()
        ws._run = lambda cmd, stdin=None, timeout=10: (1, "")
        self.ask(r, "ct/list")                           # 502
        r.dirty = True
        r.save(self.file)
        with open(self.file) as f:
            self.assertEqual(json.load(f), [])

    def test_save_only_when_something_changed(self):
        r = self.reads()
        self.ask(r, "ct/list")
        r.save(self.file)
        os.remove(self.file)
        r.save(self.file)
        self.assertFalse(os.path.exists(self.file))     # nothing new since the last save

    def test_warm_targets_hold_every_read_without_arguments(self):
        r = self.reads()
        names = {"/".join(k[0].words) if hasattr(k[0], "words") else "/".join(k[1]) for k in r.warm_targets()}
        for must in ("ct/list", "shares/overview", "recipes/list", "services/list", "dc/state", "state/disks"):
            self.assertIn(must, names)
        self.assertNotIn("config/check", names)         # ttl 0: always read fresh, never warmed
        self.assertFalse(any(k[1][:2] == ["ct", "bindings"] for k in r.warm_targets()))   # needs an argument nobody gave yet

    def test_what_somebody_asked_for_stays_warm_with_its_arguments(self):
        r = self.reads()
        self.ask(r, "ct/bindings/jellyfin")
        targets = [(argv, every) for spec_, argv, key, every in r.warm_targets()]
        self.assertIn((["ct", "bindings", "jellyfin"], 10), targets)

    def test_a_read_nobody_asked_for_is_not_read_more_often_than_the_idle_ttl(self):
        r = self.reads()
        every = {tuple(argv): e for spec_, argv, key, e in r.warm_targets()}
        self.assertGreaterEqual(every[("recipes", "list")], self.cfg.warm_idle_ttl)

    def test_the_warm_up_reads_what_is_missing_and_stops_when_nobody_is_there(self):
        class App:
            pass
        app = App()
        app.cfg = self.cfg
        app.reads = self.reads()
        app.sessions = type("S", (), {"last_seen": staticmethod(lambda: time.time())})()
        app.auth = type("A", (), {"storage_locked": staticmethod(lambda: False)})()
        self.cfg.warm_pause = 0
        w = ws.Warmer(app)
        n = w.once()
        self.assertGreater(n, 40)                        # every read without arguments
        self.assertEqual(w.once(), 0)                    # all warm now
        app.sessions = type("S", (), {"last_seen": staticmethod(lambda: time.time() - 99999)})()
        self.assertEqual(w.once(), 0)
        app.sessions = type("S", (), {"last_seen": staticmethod(lambda: time.time())})()
        app.auth = type("A", (), {"storage_locked": staticmethod(lambda: True)})()
        app.reads.cache.clear()
        self.assertEqual(w.once(), 0)                    # storage locked: nothing is run

    def test_the_defaults_show_old_data_for_a_while(self):
        cfg = ws.Config()
        self.assertGreaterEqual(cfg.stale_max, 900)
        self.assertGreaterEqual(cfg.stale_factor, 20)


class Collected(unittest.TestCase):
    """reads the collector keeps in the state database are served from there, without starting the script"""

    def setUp(self):
        self.fake = Fake()
        self.real_run = ws._run
        ws._run = self.fake
        self.tmp = tempfile.mkdtemp()
        self.db = os.path.join(self.tmp, "state.db")
        lst = os.path.join(self.tmp, "collected.tsv")
        with open(lst, "w") as f:
            f.write("# a comment\nct list\t10\nshares overview\t30\n")
        os.environ["HS_STATE_DB"] = self.db
        os.environ["HS_COLLECTED_FILE"] = lst
        ws._COLLECTED = None
        c = sqlite3.connect(self.db)
        c.execute("CREATE TABLE reads (key TEXT PRIMARY KEY, payload TEXT NOT NULL, updated INTEGER NOT NULL, ms INTEGER, rc INTEGER NOT NULL DEFAULT 0)")
        c.commit()
        c.close()
        self.cfg = ws.Config()
        self.cfg.cache_file = ""

    def tearDown(self):
        ws._run = self.real_run
        for k in ("HS_STATE_DB", "HS_COLLECTED_FILE"):
            os.environ.pop(k, None)
        ws._COLLECTED = None

    def put(self, key, payload, age=1, rc=0):
        c = sqlite3.connect(self.db)
        c.execute("INSERT OR REPLACE INTO reads VALUES (?, ?, ?, 5, ?)", (key, payload, int(time.time()) - age, rc))
        c.commit()
        c.close()

    def ask(self, r, path):
        return r.get_aged(*r.resolve(path.split("/"), {}))

    def test_a_kept_output_is_served_and_no_script_runs(self):
        self.put("ct list", "jellyfin\tRUNNING\n")
        r = ws.Reads(self.cfg)
        code, obj, _ = self.ask(r, "ct/list")
        self.assertEqual((code, obj["rows"]), (200, [["jellyfin", "RUNNING"]]))
        self.assertEqual(self.fake.calls, [])

    def test_the_answer_is_as_old_as_the_collectors_reading(self):
        self.put("ct list", "a\n", age=40)
        r = ws.Reads(self.cfg)
        self.ask(r, "ct/list")
        t, _ = r.cache[("ct", "list")]
        self.assertAlmostEqual(time.time() - t, 40, delta=3)

    def test_too_old_means_the_script_runs(self):
        self.put("ct list", "old\n", age=100000)
        r = ws.Reads(self.cfg)
        self.ask(r, "ct/list")
        self.assertEqual(self.fake.calls, [("ct", "list")])

    def test_a_read_that_is_not_collected_runs_as_before(self):
        self.put("users list", "x\n")          # in the table, but not in the list
        r = ws.Reads(self.cfg)
        self.ask(r, "users/list")
        self.assertEqual(self.fake.calls, [("users", "list")])

    def test_a_failed_empty_reading_is_ignored(self):
        self.put("ct list", "", rc=1)
        r = ws.Reads(self.cfg)
        self.ask(r, "ct/list")
        self.assertEqual(self.fake.calls, [("ct", "list")])

    def test_a_failed_reading_with_output_is_still_shaped(self):
        self.put("ct list", "partial\n", rc=1)
        r = ws.Reads(self.cfg)
        code, obj, _ = self.ask(r, "ct/list")
        self.assertEqual((code, obj["rows"]), (200, [["partial"]]))

    def test_no_database_no_table_no_row_all_mean_run_the_script(self):
        os.remove(self.db)
        r = ws.Reads(self.cfg)
        self.ask(r, "ct/list")
        self.assertEqual(self.fake.calls, [("ct", "list")])
        c = sqlite3.connect(self.db)               # a database without the table
        c.execute("CREATE TABLE other (x)")
        c.commit()
        c.close()
        r2 = ws.Reads(self.cfg)
        self.ask(r2, "shares/overview")
        self.assertEqual(self.fake.calls[-1], ("shares", "overview"))

    def test_the_database_is_only_read(self):
        r = ws.Reads(self.cfg)
        self.put("ct list", "a\n")
        self.ask(r, "ct/list")
        c = sqlite3.connect(self.db)
        n = c.execute("SELECT COUNT(*) FROM reads").fetchone()[0]
        c.close()
        self.assertEqual(n, 1)

    def test_a_kept_answer_reports_its_real_age(self):
        self.put("ct list", "a\n", age=40)
        r = ws.Reads(self.cfg)
        _, _, age = self.ask(r, "ct/list")
        self.assertAlmostEqual(age, 40, delta=3)          # not "just read": the page shows how old the data is

    def test_fresh_runs_the_script_and_ignores_what_was_kept(self):
        self.put("ct list", "kept\n", age=5)
        r = ws.Reads(self.cfg)
        self.ask(r, "ct/list")
        self.assertEqual(self.fake.calls, [])
        code, obj, age = r.get_aged(*r.resolve(["ct", "list"], {}), fresh=True)
        self.assertEqual((code, age), (200, 0))
        self.assertEqual(self.fake.calls, [("ct", "list")])
        self.assertEqual(obj["rows"], [['{"x": 1}']])

    def test_an_older_kept_output_does_not_replace_a_newer_answer(self):
        self.put("ct list", "kept\n", age=30)
        r = ws.Reads(self.cfg)
        r.get_aged(*r.resolve(["ct", "list"], {}), fresh=True)
        t0, _ = r.cache[("ct", "list")]
        r.cache[("ct", "list")] = (t0 - 20, r.cache[("ct", "list")][1])        # the ttl has passed, the collector's reading (30 s) is still older
        r.fetch(*r.resolve(["ct", "list"], {}))
        self.assertLess(time.time() - r.cache[("ct", "list")][0], 3)           # the cache is not set back to the collector's older reading
        self.assertEqual(len(self.fake.calls), 2)                              # the script ran again instead

    def test_the_status_read_is_allowlisted(self):
        self.assertEqual(ws.READS[("reads", "status")]["kind"], "tsv")

    def test_the_list_of_the_repo_names_only_real_reads(self):
        ws._COLLECTED = None
        os.environ.pop("HS_COLLECTED_FILE", None)
        self.assertGreater(len(ws.collected_keys()), 10)
        for key in ws.collected_keys():
            words = key.split(" ")
            self.assertTrue(any(ws.READS.get(tuple(words[:n])) is not None for n in range(len(words), 0, -1)), key)


if __name__ == "__main__":
    unittest.main()
