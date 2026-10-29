#!/usr/bin/env python3
"""Collector of the live state (service hs-live): one thread per topic in lib/live-topics.tsv runs `hs sys <words>` every <interval> seconds
(or when hs:v1:refresh names it) and writes the raw text to Redis (hs:v1:<topic>), then publishes hs:v1:changed. The one writer.
A failure without output keeps the old data and only sets err/ts_err. Redis down: retry every 5 s, never exit. Log goes to the journal."""
import json
import os
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import live_state as ls  # noqa: E402


def log(*a):
    print(*a, flush=True)


def hs_run(words):
    """(rc, stdout, stderr) of `hs sys <words>`."""
    hs = os.environ.get("HS_BIN") or os.path.join(ls.HERE, "lib", "hs.sh")
    env = dict(os.environ, HS_CALLER="ui")
    try:
        # bash, as reads-collect.sh does: scripts/lib/hs.sh is not executable in the store
        p = subprocess.run(["bash", hs, "sys"] + list(words), capture_output=True, text=True, timeout=90, env=env)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "timeout after 90 s"
    except OSError as e:
        return 127, "", str(e)


class Collector:
    def __init__(self, store, run=hs_run, topic_rows=None, connect=None):
        self.store = store                       # Resp (or a fake) for writing
        self.run = run
        self.rows = topic_rows if topic_rows is not None else ls.topics()
        self.connect = connect                   # () -> store; reconnect after an error
        self.events = {t[0]: threading.Event() for t in self.rows}
        self.lock = threading.Lock()
        self.stop = threading.Event()

    def locked(self):
        return os.path.exists(os.environ.get("HS_LOCKED_MARKER", "/run/hs/storage-locked"))

    def refresh(self, topic):
        for t, ev in self.events.items():
            if topic == "*" or topic == t:
                ev.set()

    def collect(self, topic, words, mode="run"):
        """One read of one topic. Returns True when the key was written with new data."""
        if mode == "skip" and self.locked():
            return False
        rc, out, err = self.run(words)
        now = time.time()
        with self.lock:
            try:
                raw = self.store.cmd("GET", ls.KEY % topic)
                old = json.loads(raw) if raw else {}
            except ValueError:
                old = {}
            if rc == 0 or out:
                gen = int(old.get("gen", 0)) + 1
                doc = {"ts": now, "gen": gen, "rc": rc, "out": out, "err": None, "ts_err": None}
                self.store.cmd("SET", ls.KEY % topic, json.dumps(doc))
                self.store.cmd("PUBLISH", ls.CHANGED, "%s %d" % (topic, gen))
                return True
            doc = {"ts": old.get("ts"), "gen": old.get("gen", 0), "rc": old.get("rc", rc), "out": old.get("out", ""),
                   "err": (err or "no output")[:200], "ts_err": now}
            self.store.cmd("SET", ls.KEY % topic, json.dumps(doc))
            log("topic %s failed (rc %s): %s" % (topic, rc, doc["err"]))
            return False

    def loop(self, topic, words, interval, mode):
        ev = self.events[topic]
        while not self.stop.is_set():
            try:
                self.collect(topic, words, mode)
            except OSError as e:
                log("redis down (%s), retry in 5 s" % e)
                self.stop.wait(5)
                if self.connect:
                    try:
                        self.store.close()
                    except (OSError, AttributeError):
                        pass
                    try:
                        self.store = self.connect()
                    except OSError:
                        pass
                continue
            ev.wait(timeout=interval)
            ev.clear()

    def listen(self):
        """Subscriber thread: REFRESH messages wake the topic threads."""
        while not self.stop.is_set():
            try:
                sub = ls.Resp(timeout=2.0)
                for _, msg in sub.subscribe(ls.REFRESH):
                    self.refresh(msg.strip())
            except OSError as e:
                log("refresh channel down (%s), retry in 5 s" % e)
                self.stop.wait(5)

    def start(self):
        for topic, words, interval, mode in self.rows:
            threading.Thread(target=self.loop, args=(topic, words, interval, mode), daemon=True).start()
        threading.Thread(target=self.listen, daemon=True).start()


def main():
    def connect():
        return ls.Resp(timeout=5.0)
    store = None
    while store is None:
        try:
            store = connect()
        except OSError as e:
            log("redis not reachable (%s), retry in 5 s" % e)
            time.sleep(5)
    c = Collector(store, connect=connect)
    log("hs-live: %d topic(s)" % len(c.rows))
    c.start()
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
