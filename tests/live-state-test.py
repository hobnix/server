#!/usr/bin/env python3
"""scripts/live_state.py and scripts/live-collect.py with a fake store and a stub run (no Redis, no processes)."""
import importlib.util
import io
import json
import os
import re
import shlex
import socket
import tempfile
import threading
import time
import unittest
import unittest.mock

here = os.path.dirname(os.path.abspath(__file__))
scripts = os.path.join(here, "..", "scripts")
import sys
sys.path.insert(0, scripts)
import live_state as ls  # noqa: E402
import hs_ext  # noqa: E402

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
        if a[0] == "DEL":
            self.data.pop(a[1], None)
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

    def test_identical_output_keeps_gen_and_does_not_publish(self):
        S = "same\n"
        c, st, _ = self.make([(0, S, ""), (0, S, ""), (0, S, ""), (1, S, "e"), (1, S, "e")])
        self.assertTrue(c.collect("status", ["status"]))
        ts1 = json.loads(st.data["hs:v1:status"])["ts"]
        self.assertFalse(c.collect("status", ["status"]))
        self.assertFalse(c.collect("status", ["status"]))
        d = json.loads(st.data["hs:v1:status"])
        self.assertEqual(d["gen"], 1)
        self.assertGreaterEqual(d["ts"], ts1)     # freshness still moves
        self.assertEqual(len(st.published), 1)
        # a changed rc with the same text counts as different
        self.assertTrue(c.collect("status", ["status"]))
        self.assertEqual(json.loads(st.data["hs:v1:status"])["gen"], 2)
        self.assertFalse(c.collect("status", ["status"]))
        self.assertEqual(len(st.published), 2)

    def test_output_back_after_an_error_counts_as_different(self):
        c, st, _ = self.make([(0, "good", ""), (2, "", "boom"), (0, "good", "")])
        c.collect("status", ["status"])
        c.collect("status", ["status"])
        self.assertTrue(c.collect("status", ["status"]))
        d = json.loads(st.data["hs:v1:status"])
        self.assertEqual((d["gen"], d["err"]), (2, None))

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

    def test_failing_collector_keeps_last_good_and_emits_once(self):
        events = []
        res = [(0, "good", ""), (1, "", "boom"), (1, "", "boom"), (124, "", "timeout after 90 s"), (0, "better", "")]
        st = FakeResp()
        c = lc.Collector(st, run=lambda w: res.pop(0), topic_rows=self.rows, emit=lambda *a: events.append(a))
        key = "hs:v1:status"
        c.collect("status", ["status"])
        good = json.loads(st.data[key])
        self.assertEqual(good["state"], "ok")
        c.collect("status", ["status"])
        d = json.loads(st.data[key])
        self.assertEqual((d["state"], d["out"], d["ts"], d["gen"]), ("stale", "good", good["ts"], 1))
        c.collect("status", ["status"])
        c.collect("status", ["status"])
        self.assertEqual([e[0] for e in events], ["live.collector-failed"])      # one event for three failed runs
        self.assertEqual(events[0][1], "status")
        self.assertTrue(c.collect("status", ["status"]))
        d = json.loads(st.data[key])
        self.assertEqual((d["state"], d["out"], d["err"], d["ts_err"]), ("ok", "better", None, None))
        self.assertEqual([e[0] for e in events], ["live.collector-failed", "live.collector-recovered"])

    def test_never_read_topic_is_error_not_stale(self):
        events = []
        c, st, _ = self.make([(3, "", "no")])
        c.emit = lambda *a: events.append(a)
        c.collect("status", ["status"])
        d = json.loads(st.data["hs:v1:status"])
        self.assertEqual((d["state"], d["ts"], d["out"]), ("error", None, ""))
        self.assertEqual(len(events), 1)

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

INSTANCE_TOPICS = {
    'ct-list': (['ct', 'list'], 10, 'skip', 'incus', {'instances', 'shares', 'network'}),
    'ct-profiles': (['ct', 'profiles'], 120, 'skip', 'incus', {'instances', 'network', 'system'}),
    'services-list': (['services', 'list'], 30, 'skip', None, {'instances', 'network'}),
    'services-app': (['services', 'app'], 30, 'skip', None, {'instances', 'network'}),
    'services-routes': (['services', 'routes'], 30, 'skip', None, {'instances', 'network'}),
    'services-local-routes': (['services', 'local-routes'], 30, 'skip', 'gateway', {'instances', 'network', 'system'}),
    'services-tiles': (['services', 'tiles'], 60, 'skip', 'dashboard', {'instances', 'network'}),
    'services-stats': (['services', 'stats'], 30, 'skip', 'dashboard', {'network'}),
}

APP_TOPICS = {
    'pkg-market': (['pkg', 'market'], 120, 'skip', None, {'system', 'instances'}),
    'pkg-repos': (['pkg', 'repos'], 300, 'run', None, {'system'}),
    'recipes-list': (['recipes', 'list'], 60, 'skip', 'incus', {'instances', 'system'}),
    'recipes-versions': (['recipes', 'versions'], 60, 'skip', None, {'instances', 'system'}),
}


NET_TOPICS = {
    'gateway-status': (['gateway', 'status'], 60, 'skip', 'gateway', {'network', 'instances', 'system'}),
    'gateway-routes': (['gateway', 'routes'], 60, 'skip', 'gateway', {'network', 'instances', 'system'}),
    'gateway-health': (['gateway', 'health'], 300, 'skip', 'gateway', {'network', 'instances', 'system'}),
    'dns-list': (['dns', 'list'], 300, 'skip', 'ad', {'network', 'instances', 'system'}),
    'unifi-networks': (['unifi', 'networks'], 300, 'skip', 'network', {'network', 'system'}),
    'unifi-clients': (['unifi', 'clients'], 60, 'skip', 'network', {'network', 'instances', 'system'}),
    'ports-list': (['ports', 'list'], 120, 'skip', None, {'network', 'instances', 'system'}),
    'remote-list': (['remote', 'list'], 60, 'skip', None, {'network', 'shares', 'system'}),
}


ID_TOPICS = {
    'users-list': (['users', 'list'], 60, 'skip', 'ad', {'users', 'shares', 'instances', 'system'}),
    'users-groups': (['users', 'groups'], 60, 'skip', 'ad', {'users', 'shares', 'instances', 'system'}),
    'dc-state': (['dc', 'state'], 600, 'skip', 'ad', {'users', 'security', 'instances', 'system'}),
    'backup-state': (['backup', 'state'], 30, 'run', 'backup', {'backup', 'any'}),
    'backup-overview': (['backup', 'overview'], 60, 'skip', 'backup', {'backup', 'shares', 'instances', 'disks', 'system'}),
    'backup-shares': (['backup', 'shares'], 60, 'skip', 'backup', {'backup', 'shares', 'instances', 'disks', 'system'}),
    'docker-list': (['docker', 'list'], 300, 'skip', 'docker', {'instances', 'system', 'docker'}),
    'docker-apps': (['docker', 'apps'], 300, 'skip', 'docker', {'instances', 'system', 'docker'}),
}


class Cli(unittest.TestCase):
    def test_parts_list_wakes_on_network_changes(self):
        # gateway / vps web starts rebuild under @network and can switch a capability on
        self.assertEqual(ls.topic_info()["parts-list"]["groups"], {"system", "network"})

    def test_network_topics(self):
        info = ls.topic_info()
        rows = {t[0]: t for t in ls.topics()}
        for name, (words, iv, lock, cap, groups) in NET_TOPICS.items():
            self.assertEqual(tuple(rows[name][1:]), (words, iv, lock), name)
            self.assertEqual(info[name], {"cap": cap, "groups": groups}, name)

    def test_every_change_row_wakes_the_network_topics_it_can_alter(self):
        # system rows (config set, rebuild, update, preset, ext ...) and network rows reach all of them; instance rows (ct start/stop/remove,
        # recipe) every one that lists containers or their addresses; remote rows the remote list.
        reg = os.path.join(os.path.dirname(ls.__file__), "lib", "registry.tsv")
        info = ls.topic_info()
        woken_by = lambda g: {n for n, i in info.items() if g in i["groups"] or "any" in i["groups"]}
        need = {"system": set(NET_TOPICS), "network": set(NET_TOPICS), "instances": set(NET_TOPICS) - {"unifi-networks", "remote-list"}}
        seen = set()
        with open(reg, encoding="utf-8") as fh:
            for line in fh:
                f = line.rstrip(chr(10)).split(chr(9))
                if len(f) < 7 or f[0] != "user" or "changes" not in (f[-1].split(",") if f[-1] else []):
                    continue
                topic = [x[6:] for x in f[-1].split(",") if x.startswith("topic:")]
                g = topic[0] if topic else "system"
                seen.add(g)
                for n in need.get(g, ()):
                    self.assertIn(n, woken_by(g), (f[1], n))
                if f[1].split()[0] == "remote":
                    self.assertIn("remote-list", woken_by(g), f[1])
        self.assertTrue({"system", "network", "instances", "shares"} <= seen)

    def test_identity_and_backup_topics(self):
        info = ls.topic_info()
        rows = {t[0]: t for t in ls.topics()}
        for name, (words, iv, lock, cap, groups) in ID_TOPICS.items():
            self.assertEqual(tuple(rows[name][1:]), (words, iv, lock), name)
            self.assertEqual(info[name], {"cap": cap, "groups": groups}, name)

    def test_every_change_row_wakes_the_identity_and_backup_topics_it_can_alter(self):
        # system rows (config set, rebuild, update ...) can switch ad/backup on or move the dc/timer; instance rows start/stop the dc and change
        # the mounted containers; user/dc rows the directory; share, pool and disk rows the share list and sizes; backup rows the backup;
        # vault rows (security) the dc CA and the backup vault flag.
        reg = os.path.join(os.path.dirname(ls.__file__), "lib", "registry.tsv")
        info = ls.topic_info()
        woken_by = lambda g: {n for n, i in info.items() if g in i["groups"] or "any" in i["groups"]}
        users = {"users-list", "users-groups", "dc-state"}
        bk = {"backup-state", "backup-overview", "backup-shares"}
        need = {"system": set(ID_TOPICS), "instances": set(ID_TOPICS), "users": users | {"backup-state"},
                "shares": {"users-list", "users-groups", "backup-overview", "backup-shares", "backup-state"},
                "disks": {"backup-overview", "backup-shares", "backup-state"}, "security": {"dc-state", "backup-state"}, "backup": bk}
        seen = set()
        with open(reg, encoding="utf-8") as fh:
            for line in fh:
                f = line.rstrip(chr(10)).split(chr(9))
                if len(f) < 7 or f[0] != "user" or "changes" not in (f[-1].split(",") if f[-1] else []):
                    continue
                topic = [x[6:] for x in f[-1].split(",") if x.startswith("topic:")]
                g = topic[0] if topic else "system"
                seen.add(g)
                for n in need.get(g, ()):
                    self.assertIn(n, woken_by(g), (f[1], n))
        self.assertTrue({"system", "instances", "users", "shares", "disks", "security", "backup"} <= seen)

    def test_app_topics(self):
        info = ls.topic_info()
        rows = {t[0]: t for t in ls.topics()}
        for name, (words, iv, lock, cap, groups) in APP_TOPICS.items():
            self.assertEqual(tuple(rows[name][1:]), (words, iv, lock), name)
            self.assertEqual(info[name], {"cap": cap, "groups": groups}, name)

    def test_changes_of_packages_and_recipes_wake_the_app_topics(self):
        # the dispatcher asks for @<topic flag> of a changes row: every pkg/ext/recipe/update row must reach the topics that show its result
        reg = os.path.join(os.path.dirname(ls.__file__), "lib", "registry.tsv")
        info = ls.topic_info()
        woken_by = lambda g: {n for n, i in info.items() if g in i["groups"] or "any" in i["groups"]}
        seen = set()
        with open(reg, encoding="utf-8") as fh:
            for line in fh:
                f = line.rstrip(chr(10)).split(chr(9))
                if len(f) < 7 or f[0] != "user":
                    continue
                words = f[1].split()
                flags = f[-1].split(",") if f[-1] else []
                if "changes" not in flags or words[0] not in ("pkg", "recipe", "update", "ext", "parts", "system"):
                    continue
                topic = [x[6:] for x in flags if x.startswith("topic:")]
                g = topic[0] if topic else "system"
                seen.add(words[0])
                if words[0] == "pkg":
                    self.assertEqual(g, "system", f[1])
                if words[0] in ("pkg", "update", "ext", "parts", "system"):
                    for n in ("pkg-market", "pkg-repos", "recipes-list", "recipes-versions"):
                        if words[0] in ("ext", "parts") and n == "pkg-repos":
                            continue
                        self.assertIn(n, woken_by(g), (f[1], n))
                if words[0] == "recipe":
                    for n in ("pkg-market", "recipes-list", "recipes-versions"):
                        self.assertIn(n, woken_by(g), (f[1], n))
        self.assertEqual(seen, {"pkg", "recipe", "update", "ext", "system"})

    def test_changes_of_instances_and_services_wake_their_topics(self):
        # the dispatcher asks for @<topic flag> of a changes row; every such row of these areas must reach every topic that shows its result
        reg = os.path.join(os.path.dirname(ls.__file__), "lib", "registry.tsv")
        info = ls.topic_info()
        areas = ("ct", "recipe", "mac", "net", "gateway", "services")
        groups = {}
        with open(reg, encoding="utf-8") as fh:
            for line in fh:
                f = line.rstrip("\n").split("\t")
                if len(f) < 7 or f[0] != "user" or f[1].split()[0] not in areas:
                    continue
                flags = f[-1].split(",") if f[-1] else []
                if "changes" in flags:
                    topic = [x[6:] for x in flags if x.startswith("topic:")]
                    groups.setdefault(f[1].split()[0], set()).add(topic[0] if topic else "system")
        self.assertEqual(groups, {"ct": {"instances"}, "recipe": {"instances"}, "mac": {"instances"}, "net": {"network"},
                                  "gateway": {"network"}, "services": {"network"}})
        # a change of instances or of the network wakes the lists of both (an address, a route, a service)
        for g in ("instances", "network"):
            woken = {n for n, i in info.items() if g in i["groups"] or "any" in i["groups"]}
            for n in ("ct-list", "services-list", "services-app", "services-routes", "services-tiles", "services-local-routes"):
                self.assertIn(n, woken, (g, n))
        self.assertIn("services-stats", {n for n, i in info.items() if "network" in i["groups"]})
        # hs rebuild / update (topic system) changes the Incus preseed and the local routes
        for n in ("ct-profiles", "services-local-routes"):
            self.assertIn("system", info[n]["groups"])

    def test_instance_topics(self):
        info = ls.topic_info()
        rows = {t[0]: t for t in ls.topics()}
        self.assertEqual(len(INSTANCE_TOPICS), 8)
        for name, (words, iv, lock, cap, groups) in INSTANCE_TOPICS.items():
            self.assertEqual(tuple(rows[name][1:]), (words, iv, lock), name)
            self.assertEqual(info[name], {"cap": cap, "groups": groups}, name)

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
        ] + [(n, v[0], v[1], v[2]) for n, v in INSTANCE_TOPICS.items()] + [(n, v[0], v[1], v[2]) for n, v in APP_TOPICS.items()] + [(n, v[0], v[1], v[2]) for n, v in NET_TOPICS.items()] + [(n, v[0], v[1], v[2]) for n, v in ID_TOPICS.items()])

    def test_status_shape(self):
        import time
        out = io.StringIO()
        self.assertEqual(ls.cli_status(self.fake(time.time() - 7), out), 0)
        lines = out.getvalue().rstrip("\n").split("\n")
        self.assertEqual(len(lines), 67)
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
        self.assertEqual(lines, sorted(old + ["%s	%s	-1	0	-	-	-" % (t, iv) for t, iv in SYSTEM_TOPICS.items()] + ["%s	%s	-1	0	-	-	-" % (t, v[1]) for t, v in INSTANCE_TOPICS.items()] + ["%s	%s	-1	0	-	-	-" % (t, v[1]) for t, v in APP_TOPICS.items()] + ["%s	%s	-1	0	-	-	-" % (t, v[1]) for t, v in NET_TOPICS.items()] + ["%s	%s	-1	0	-	-	-" % (t, v[1]) for t, v in ID_TOPICS.items()]))

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
        self.assertEqual(len(st.published), 67)
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


class ExtLive(unittest.TestCase):
    """live reads of extension packages: the topic list, the group, the rescan of the collector"""
    TAB = "\t"
    DECL = '[[web.reads]]\nwords = "list"\nkind = "tsv"\nttl = 10\n'

    def setUp(self):
        import shutil
        import tempfile
        self.tmp = tempfile.mkdtemp()
        self.pk = os.path.join(self.tmp, "packages")
        self.old = {k: os.environ.get(k) for k in ("HS_PACKAGES_DIR", "HS_CAPABILITIES_FILE", "HS_STATE_DIR")}
        os.environ.update(HS_PACKAGES_DIR=self.pk, HS_CAPABILITIES_FILE=os.path.join(self.tmp, "caps"), HS_STATE_DIR=os.path.join(self.tmp, "state"))
        self.write("caps", "demo\n")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.addCleanup(self.restore)

    def restore(self):
        for k, v in self.old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def write(self, rel, text):
        p = os.path.join(self.tmp, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8", newline="") as f:
            f.write(text)

    def package(self, reads, name="demo"):
        self.write("packages/%s/capability.toml" % name, 'name = "%s"\ntitle = "t"\nextension = true\n%s' % (name, reads))
        words = set(re.findall(r'words = "([^"]+)"', reads))
        self.write("packages/%s/commands.tsv" % name,
                   "".join(self.TAB.join(["sys", "sys ext %s %s" % (name, w), "x.sh", "-", "h", "-"]) + "\n" for w in words))

    def ext(self):
        return [r for r in ls.topics() if r[0].startswith("ext-")]

    def test_live_read_becomes_a_topic(self):
        self.package(self.DECL + 'live = 30\n[[web.reads]]\nwords = "other"\nkind = "tsv"\nttl = 10\n')
        self.assertEqual(self.ext(), [("ext-demo-list", ["ext", "demo", "list"], 30, "skip")])
        self.assertEqual(ls.topic_info()["ext-demo-list"], {"cap": "demo", "groups": {"ext-demo"}})
        own = os.path.join(scripts, "lib", "live-topics.tsv")
        self.assertEqual([r for r in ls.topics(own) if r[0].startswith("ext-")], [])

    def test_locked_run_and_bad_declarations(self):
        self.package(self.DECL + 'live = 10\nlocked = "run"\n')
        self.assertEqual([r[3] for r in self.ext()], ["run"])
        for bad in ('live = 9', 'live = 3601', 'live = "30"', 'live = true', 'locked = "x"\nlive = 30', "live = 30\nargs = ['^a$']"):
            self.package(self.DECL + bad + "\n")
            self.assertEqual(self.ext(), [], bad)

    def test_words_are_a_closed_alphabet_and_package_off_gives_nothing(self):
        self.package(self.DECL.replace("list", "Li_st") + "live = 30\n")
        self.assertEqual(self.ext(), [])
        self.package(self.DECL + "live = 30\n")
        self.assertEqual(len(self.ext()), 1)
        self.write("caps", "")
        self.assertEqual(self.ext(), [])

    def test_same_topic_from_two_packages_keeps_the_first(self):
        self.write("caps", "demo\ndemo-list\n")
        self.package(self.DECL.replace('"list"', '"list-x"') + "live = 30\n", "demo")
        self.package(self.DECL.replace('"list"', '"x"') + "live = 30\n", "demo-list")
        self.assertEqual([r[0] for r in self.ext()], ["ext-demo-list-x"])

    def test_a_bad_page_or_bad_changes_drop_the_package_here_too(self):
        self.package(self.DECL + 'live = 30\n[web.page]\ntitle = "x"\n[[web.page.blocks]]\ntype = "table"\nread = "nope"\n')
        self.assertEqual(self.ext(), [])
        self.package(self.DECL + "live = 30\n[[web.changes]]\npatterns = ['^go$']\n")      # changes need plan and start rows
        self.assertEqual(self.ext(), [])

    def test_names_that_join_to_the_same_topic_agree_with_the_web_interface(self):
        # package a reads "b c" (live) but has a bad page; package a-b reads "c": the topic ext-a-b-c belongs to a-b only
        self.write("caps", "a\na-b\n")
        bad = 'live = 30\n[web.page]\ntitle = "x"\n[[web.page.blocks]]\ntype = "table"\nread = "nope"\n'
        self.package(self.DECL.replace('"list"', '"b c"') + bad, "a")
        self.package(self.DECL.replace('"list"', '"c"') + "live = 30\n", "a-b")
        self.assertEqual([(r[0], r[1]) for r in self.ext()], [("ext-a-b-c", ["ext", "a-b", "c"])])
        # when both are good the first one wins, in the collector and in the web interface alike
        self.package(self.DECL.replace('"list"', '"b c"') + "live = 30\n", "a")
        self.assertEqual([(r[0], r[1]) for r in self.ext()], [("ext-a-b-c", ["ext", "a", "b", "c"])])
        reads = hs_ext.ext_load_web()[0]
        self.assertEqual({k: v["topic"] for k, v in reads.items() if "topic" in v}, {("ext", "a", "b", "c"): "ext-a-b-c"})

    def test_package_output_cannot_forge_a_check_line(self):
        self.assertEqual(ls.clean("a\nb\tc\x1b[0m"), "a b c [0m")
        st = FakeResp()
        st.data["hs:v1:t"] = json.dumps({"ts": None, "err": "bad\nlive:down\tx"})
        out = io.StringIO()
        with unittest.mock.patch.object(ls, "topics", lambda path=None: [("t", ["t"], 15, "run")]), \
                unittest.mock.patch.object(ls, "topic_info", lambda path=None: {}):
            ls.cli_check(conn=st, out=out)
        self.assertEqual(len(out.getvalue().splitlines()), 1)
        self.assertNotIn("\t", out.getvalue().split("\t", 1)[1])

    def test_collector_picks_up_and_drops_topics_on_rescan(self):
        started = []
        c = lc.Collector(FakeResp(), run=lambda w: (0, "x", ""), topic_rows=[("status", ["status"], 15, "run")],
                         topic_info={"status": {"cap": None, "groups": {"any"}}}, ext_rows=ls.ext_live)
        c._spawn = lambda *r: started.append(r[0])
        c.rescan()
        self.assertEqual(started, [])
        self.package(self.DECL + "live = 30\n")
        c.rescan()
        self.assertEqual(started, ["ext-demo-list"])
        c.rescan()
        self.assertEqual(started, ["ext-demo-list"])        # not twice
        c.refresh("@ext-demo")
        self.assertTrue(c.events["ext-demo-list"].is_set())
        self.assertTrue(c.events["status"].is_set())        # status lists the group "any": every group wakes it
        stop = c.stops["ext-demo-list"]
        c.store.data["hs:v1:ext-demo-list"] = "{}"
        self.write("caps", "")
        c.rescan()
        self.assertTrue(stop.is_set())
        self.assertNotIn("ext-demo-list", c.events)
        self.assertNotIn("hs:v1:ext-demo-list", c.store.data)
        self.assertIn("status", c.events)

    def test_refresh_of_an_unknown_ext_topic_rescans(self):
        started = []
        c = lc.Collector(FakeResp(), run=lambda w: (0, "x", ""), topic_rows=[], topic_info={}, ext_rows=ls.ext_live)
        c._spawn = lambda *r: started.append(r[0])
        self.package(self.DECL + "live = 30\n")
        c.refresh("ext-demo-list")
        self.assertEqual(started, ["ext-demo-list"])
        self.assertTrue(c.events["ext-demo-list"].is_set())


FAKE_EVENTS = r"""
import sys, time
mode, counter = sys.argv[1], sys.argv[2]
try:
    n = int(open(counter).read())
except OSError:
    n = 0
n += 1
open(counter, "w").write(str(n))
def out(t):
    print(t, flush=True)
if mode == "start":
    out('{"Type":"container","Action":"start"}')
    time.sleep(30)
elif mode == "burst":
    for i in range(50):
        out('{"Type":"%s","Action":"a%d"}' % (["container", "network", "volume"][i % 3], i))
    time.sleep(30)
elif mode == "restart":
    if n == 1:
        out('{"Type":"container","Action":"start"}')
        time.sleep(0.1)
        sys.exit(1)
    if n in (2, 3):
        out("Error: cannot connect to the Docker daemon")
        sys.exit(1)
    time.sleep(30)
elif mode == "late":
    if n == 1:
        out("Error: cannot connect to the Docker daemon")
        sys.exit(1)
    time.sleep(30)
"""


class DockerEvents(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.fake = os.path.join(self.tmp.name, "fake.py")
        self.counter = os.path.join(self.tmp.name, "count")
        with open(self.fake, "w") as f:
            f.write(FAKE_EVENTS)
        self.calls, self.logs, self.watchers = [], [], []

    def tearDown(self):
        for w, t in self.watchers:
            w.stop.set()
            t.join(10)

    def runs(self):
        try:
            return int(open(self.counter).read())
        except (OSError, ValueError):
            return 0

    def make(self, mode, cap=True):
        cmd = "%s %s %s %s" % (shlex.quote(sys.executable), shlex.quote(self.fake), mode, shlex.quote(self.counter))
        p = unittest.mock.patch.dict(os.environ, {"HS_LIVE_DOCKER_EVENTS": cmd})
        p.start()
        self.addCleanup(p.stop)
        w = lc.DockerWatch(refresh=self.calls.append, stop=threading.Event(), cap=lambda: cap, logf=self.logs.append)
        w.COALESCE, w.MAX_WAIT, w.STABLE, w.BACKOFF, w.CAP_CHECK = 0.2, 1.0, 3.0, (0.05, 0.1), 0.05   # STABLE far above the start time of a fake
        t = threading.Thread(target=w.run, daemon=True)
        self.watchers.append((w, t))
        t.start()
        return w

    def wait_for(self, pred, timeout=30):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if pred():
                return True
            time.sleep(0.05)
        return pred()

    def test_start_event_asks_for_one_refresh(self):
        self.make("start")
        self.assertTrue(self.wait_for(lambda: self.calls))
        time.sleep(0.5)
        self.assertEqual(self.calls, ["@docker"])
        self.assertEqual(self.logs, [])

    def test_burst_is_coalesced(self):
        self.make("burst")
        self.assertTrue(self.wait_for(lambda: self.calls))
        time.sleep(0.6)
        self.assertEqual(self.calls, ["@docker"])

    def test_daemon_restart_reconnects_once_and_refreshes(self):
        self.make("restart")
        self.assertTrue(self.wait_for(lambda: self.runs() >= 4 and len(self.calls) >= 2))
        time.sleep(0.6)
        self.assertEqual(self.calls, ["@docker", "@docker"])
        down = [l for l in self.logs if "docker events down" in l]
        self.assertEqual(len(down), 1)
        self.assertIn("down", down[0])
        self.assertEqual(len([l for l in self.logs if "docker events back" in l]), 1)

    def test_first_connect_after_failures_refreshes(self):
        self.make("late")
        self.assertTrue(self.wait_for(lambda: self.calls))
        self.assertEqual(self.calls, ["@docker"])
        self.assertEqual(len([l for l in self.logs if "docker events down" in l]), 1)
        self.assertEqual(len([l for l in self.logs if "docker events back" in l]), 1)

    def test_capability_off_runs_nothing(self):
        self.make("start", cap=False)
        time.sleep(0.4)
        self.assertFalse(os.path.exists(self.counter))
        self.assertEqual(self.calls, [])
        self.assertEqual(self.logs, [])

    def test_default_command(self):
        env = {k: v for k, v in os.environ.items() if k != "HS_LIVE_DOCKER_EVENTS"}
        env["HS_INCUS"] = "/x/incus"
        with unittest.mock.patch.dict(os.environ, env, clear=True):
            cmd = lc.docker_events_cmd()
        self.assertEqual(cmd[:5], ["/x/incus", "exec", "docker", "--", "docker"])
        self.assertIn("type=volume", cmd)
        self.assertIn("event=die", cmd)
        self.assertFalse([c for c in cmd if c.startswith("event=exec") or c == "event=health_status"])

    def test_docker_group_wakes_the_docker_topics(self):
        got = {t for t, i in ls.topic_info().items() if "docker" in i["groups"]}
        self.assertEqual(got, {"docker-list", "docker-apps"})


if __name__ == "__main__":
    unittest.main()
