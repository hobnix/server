#!/usr/bin/env python3
"""Collector of the live state (service hs-live): one thread per topic in lib/live-topics.tsv runs `hs sys <words>` every <interval> seconds
(or when hs:v1:refresh names it) and writes the raw text to Redis (hs:v1:<topic>), then publishes hs:v1:changed. The one writer.
A failure without output keeps the old data (ts stays the time of the last good read) and sets err/ts_err and state "stale" (there
was a good read) or "error" (never); a good read sets state "ok". A change into error and the recovery each write one event (live.collector-failed,
live.collector-recovered), not one per failed run. Redis down: retry every 5 s, never exit. Log goes to the journal.
A topic can name topics it needs (lib/live-topics.tsv column 7): when one of them gets a new gen, one wave thread reads the dependents once, in
dependency order (a burst of changes is one wave); a wave never reads a topic sooner than HS_LIVE_MIN_GAP seconds (default 5) after its last read.
DockerWatch follows the Docker event stream of the container docker and asks for @docker (#155); IncusWatch follows `incus monitor --type=lifecycle`,
asks for @instances and writes ct.created/started/stopped/deleted events (#392).
HS_LIVE_STORE=db (liveState = "db", ADR 0026 step 1, service hs-live-db) writes to the state database instead of Redis: a document only when its output
changed (table live, counter live:<topic>) and one heartbeat row every HS_LIVE_BEAT seconds (default 5); no refresh channel."""
import importlib.util
import json
import math
import os
import queue
import re
import shlex
import sqlite3
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import live_state as ls  # noqa: E402


def log(*a):
    print(*a, flush=True)


def load_state_db():
    """scripts/state-db.py as a module (its file name has a dash): the SQL of the live tables stays there, this process only calls it."""
    spec = importlib.util.spec_from_file_location("state_db", os.path.join(ls.HERE, "state-db.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


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


def emit_event(kind, subject, text, payload=None):
    """Best effort: one line in the event log (state-db.py emit, the one writer; needs root, which hs-live is). Never raises."""
    cmd = [sys.executable, os.path.join(ls.HERE, "state-db.py"), "emit", kind, subject, text]
    if payload:
        cmd += ["--payload", json.dumps(payload, separators=(",", ":"))]
    try:
        subprocess.run(cmd, capture_output=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        pass


# real lifecycle actions only: no exec_* and health_status (one set per healthcheck run and container)
DOCKER_ACTIONS = ("create", "start", "stop", "die", "destroy", "kill", "pause", "unpause", "rename", "update", "remove", "oom",
                  "connect", "disconnect", "mount", "unmount")


def docker_events_cmd():
    """The command that streams Docker events of the container `docker`; HS_LIVE_DOCKER_EVENTS (a command line) replaces it in tests."""
    o = os.environ.get("HS_LIVE_DOCKER_EVENTS")
    if o:
        return shlex.split(o)
    return [os.environ.get("HS_INCUS") or "incus", "exec", "docker", "--", "docker", "events", "--format", "{{json .}}",
            "--filter", "type=container", "--filter", "type=network", "--filter", "type=volume"] + [
        x for e in DOCKER_ACTIONS for x in ("--filter", "event=" + e)]


class DockerWatch:
    """One thread: follows `docker events` and asks for one refresh of the group docker per burst (coalesced). The 300 s poll of the
    docker topics stays the safety net. Reconnects with back-off; an outage is logged once (start and end), not per retry; capability
    docker off = no process. Not tested on hardware yet."""
    NAME = "docker"
    CAP = "docker"
    GROUP = "@docker"
    COALESCE = 1.0
    MAX_WAIT = 5.0
    STABLE = 3.0
    BACKOFF = (1, 2, 5, 10, 30, 60)
    CAP_CHECK = 60.0

    def __init__(self, refresh, stop, cap=None, cmd=None, logf=None):
        self.refresh = refresh                     # (topic) -> None, Collector.refresh
        self.stop = stop                           # threading.Event of the collector
        self.cap = cap or (lambda: ls.cap_on(self.CAP))
        self.cmd = cmd or docker_events_cmd
        self.log = logf or log
        self.down = False                          # in an outage (its start was logged)
        self.fails = 0                             # failed connections in a row (back-off index)

    def _reader(self, proc, q):
        try:
            for line in proc.stdout:
                q.put(line)
        except (OSError, ValueError):
            pass
        q.put(None)

    def accept(self, line):
        """True when the event line is a change that asks for a refresh. IncusWatch narrows it."""
        return True

    def _mark_up(self):
        if self.down:
            self.log("%s events back" % self.NAME)
        self.down, self.fails = False, 0

    def follow(self, reconnected):
        """One connection. -> (up, reason): up = it printed an event, or it is still alive after STABLE seconds without any error text; reason = why it ended."""
        try:
            proc = subprocess.Popen(self.cmd(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                    text=True, bufsize=1)
        except OSError as e:
            return False, str(e)
        q = queue.Queue()
        threading.Thread(target=self._reader, args=(proc, q), daemon=True).start()
        start = time.monotonic()
        up, first, last, msg = False, None, None, ""
        try:
            while not self.stop.is_set():
                now = time.monotonic()
                due = []
                if first is not None:
                    due.append(min(last + self.COALESCE, first + self.MAX_WAIT))
                if not up:
                    due.append(start + self.STABLE)
                timeout = min(max(0.0, min(due) - now), 1.0) if due else 1.0   # at most 1 s, so a stop is seen
                try:
                    line = q.get(timeout=timeout)
                except queue.Empty:
                    now = time.monotonic()
                    if not up and now >= start + self.STABLE and not msg and proc.poll() is None:
                        up = True            # alive, no error text: an idle healthy stream (a hang that stays silent counts too)
                        self._mark_up()
                        if reconnected:              # one full refresh after a reconnect, through the coalescer
                            first = first or now
                            last = now
                    if first is not None and now >= min(last + self.COALESCE, first + self.MAX_WAIT):
                        self.refresh(self.GROUP)
                        first = last = None
                    continue
                if line is None:
                    break                            # the stream ended (daemon or container gone, incus error)
                if not line.lstrip().startswith("{"):
                    msg = ls.clean(line.strip()) or msg      # an error text of incus or docker, not an event
                    continue
                if not self.accept(line):
                    continue                         # a JSON line that is not a lifecycle change (IncusWatch)
                now = time.monotonic()
                if not up:
                    up = True
                    self._mark_up()
                first = first or now
                last = now
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
        if first is not None:
            self.refresh(self.GROUP)                 # flush what came before the end
        return up, msg or "exit %s" % proc.returncode

    def run(self):
        ever_up = False
        while not self.stop.is_set():
            if not self.cap():
                self.stop.wait(self.CAP_CHECK)       # capability docker off: no process
                continue
            up, reason = self.follow(reconnected=ever_up or self.fails > 0)   # earlier failed connects: events before this one were missed
            if self.stop.is_set():
                break
            ever_up = ever_up or up
            if not self.down:                        # once per outage; the failed retries after it log nothing
                self.log("%s events down (%s), retrying with back-off" % (self.NAME, reason))
                self.down = True
            self.stop.wait(self.BACKOFF[min(self.fails, len(self.BACKOFF) - 1)])
            self.fails += 1


INCUS_REFRESH = ("created", "started", "stopped", "shutdown", "deleted", "restarted", "renamed", "paused", "resumed", "ready", "updated", "rebuilt")
INCUS_KIND = {"created": "ct.created", "started": "ct.started", "stopped": "ct.stopped", "shutdown": "ct.stopped", "deleted": "ct.deleted"}
INCUS_TEXT = {"ct.created": "%s was created", "ct.started": "%s started", "ct.stopped": "%s stopped", "ct.deleted": "%s was deleted"}
NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,62}")


def incus_events_cmd():
    """The command that streams Incus lifecycle events; HS_LIVE_INCUS_EVENTS (a command line) replaces it in tests."""
    o = os.environ.get("HS_LIVE_INCUS_EVENTS")
    if o:
        return shlex.split(o)
    return [os.environ.get("HS_INCUS") or "incus", "monitor", "--type=lifecycle", "--format=json"]


def parse_incus_event(line):
    """One line of `incus monitor --type=lifecycle --format=json` -> (action, instance, project), or None when it is no change of an
    instance that matters (an image, a network, a snapshot, exec, console, a malformed line). Only the three safe fields are read: the
    context of the event (can hold device and config values) is never looked at."""
    try:
        ev = json.loads(line)
        md = ev.get("metadata") or {}
        action, src = md.get("action"), md.get("source")
        if ev.get("type") != "lifecycle" or not isinstance(action, str) or not isinstance(src, str):
            return None
    except (ValueError, AttributeError):
        return None
    if not action.startswith("instance-") or action[9:] not in INCUS_REFRESH:
        return None
    path = src.split("?", 1)[0]
    if not path.startswith("/1.0/instances/"):
        return None
    name = path[len("/1.0/instances/"):]
    project = ev.get("project")
    if not NAME_RE.fullmatch(name) or not (project is None or (isinstance(project, str) and NAME_RE.fullmatch(project))):
        return None
    return action[9:], name, project or "default"


class IncusWatch(DockerWatch):
    """One thread: follows `incus monitor --type=lifecycle` and asks for one refresh of the group instances per burst (the 10 s poll of
    ct-list stays the safety net; reconnect, back-off, one journal line per outage and capability off = no process come from DockerWatch).
    The four facts created, started, stopped, deleted also become events (ct.*, subject = the instance, payload instance/project/action only):
    the same kind and instance again within DEDUP seconds is one event, and at most LIMIT events per minute are written (a host shutdown
    or a mass delete stays a refresh; one journal line says how many were left out). Writing happens in a second thread: a slow
    state-db never blocks the stream. Not tested on hardware yet."""
    NAME = "incus"
    CAP = "incus"
    GROUP = "@instances"
    DEDUP = 10.0
    LIMIT = 30
    WINDOW = 60.0

    def __init__(self, refresh, stop, cap=None, cmd=None, logf=None, emit=emit_event, clock=time.monotonic):
        super().__init__(refresh, stop, cap=cap, cmd=cmd or incus_events_cmd, logf=logf)
        self.emit = emit
        self.clock = clock
        self.seen = {}                  # (kind, instance) -> time of the last event
        self.win_start, self.win_n, self.win_skipped = None, 0, 0
        self.outq = queue.Queue()
        self.writer = None

    def accept(self, line):
        p = parse_incus_event(line)
        if p is None:
            return False
        action, name, project = p
        kind = INCUS_KIND.get(action)
        if kind and self._admit(kind, name):
            self.outq.put((kind, name, INCUS_TEXT[kind] % name, {"instance": name, "project": project, "action": "instance-" + action}))
        return True

    def _admit(self, kind, name):
        now = self.clock()
        if (kind, name) in self.seen and now - self.seen[(kind, name)] < self.DEDUP:
            return False
        self.seen[(kind, name)] = now
        if len(self.seen) > 512:
            self.seen = {k: t for k, t in self.seen.items() if now - t < self.DEDUP}
        if self.win_start is None or now - self.win_start >= self.WINDOW:
            if self.win_skipped:
                self.log("incus events: %d event(s) not recorded (more than %d in a minute); the lists were refreshed anyway" % (self.win_skipped, self.LIMIT))
            self.win_start, self.win_n, self.win_skipped = now, 0, 0
        if self.win_n >= self.LIMIT:
            self.win_skipped += 1
            return False
        self.win_n += 1
        return True

    def _write(self):
        while True:
            item = self.outq.get()
            if item is None:
                return
            self.emit(*item[:3], payload=item[3])

    def run(self):
        self.writer = threading.Thread(target=self._write, daemon=True)
        self.writer.start()
        try:
            super().run()
        finally:
            self.outq.put(None)
            self.writer.join(20)


class DbStore:
    """The state database as the store of the live documents (ADR 0026 step 1). One connection shared by all topic threads under one lock;
    the documents are also kept in memory, so a read that changed nothing needs no SQL. Counts what it wrote, for the heartbeat row."""
    SLOW_MS = 100

    def __init__(self, sdb=None, every=None, clock=time.time):
        self.sdb = sdb or load_state_db()
        self.clock = clock
        self.lock = threading.Lock()
        try:
            self.c = self.sdb.live_open()
            self.docs = self.sdb.live_load(self.c)
        except sqlite3.Error as e:
            raise OSError("state.db: %s" % e)
        self.started = int(clock())
        self.counts = {"beats": 0, "docs": 0, "fails": 0, "bytes": 0, "slow": 0, "wait_ms": 0}

    def _tx(self, fn, *a):
        with self.lock:
            t0 = time.monotonic()
            try:
                return fn(self.c, *a)
            except sqlite3.Error as e:
                raise OSError("state.db: %s" % e)
            finally:
                ms = int((time.monotonic() - t0) * 1000)
                self.counts["wait_ms"] += ms
                if ms > self.SLOW_MS:
                    self.counts["slow"] += 1

    def get(self, topic):
        return self.docs.get(topic)

    def put(self, topic, out, rc, ms, src, ttl, now):
        gen = self._tx(self.sdb.live_put, topic, out, rc, ms, src, ttl, int(now))
        self.docs[topic] = {"payload": out, "rc": rc, "err": None, "gen": gen, "updated": int(now), "ts_err": None}
        self.counts["docs"] += 1
        self.counts["bytes"] += len(out.encode())
        return gen

    def fail(self, topic, rc, ms, err, src, ttl, now):
        self._tx(self.sdb.live_fail, topic, rc, ms, err, src, ttl, int(now))
        old = self.docs.get(topic) or {"payload": "", "gen": 0, "updated": 0}
        self.docs[topic] = dict(old, rc=rc, err=err, ts_err=int(now))
        self.counts["fails"] += 1

    def delete(self, topic):
        self._tx(self.sdb.live_delete, topic)
        self.docs.pop(topic, None)

    def beat(self, every, read):
        self.counts["beats"] += 1
        self._tx(self.sdb.live_beat, "hs-live", every, self.started, int(self.clock()), dict(self.counts), read)

    def close(self):
        pass


def beat_every():
    try:
        n = int(os.environ.get("HS_LIVE_BEAT", "5"))
    except ValueError:
        n = 5
    return max(1, n)


class Collector:
    RESCAN = 60.0         # seconds between looks at the extension packages that are on (their live reads)
    RESCAN_MIN = 3.0      # a refresh of an unknown ext- topic looks sooner, but not more often than this

    def __init__(self, store, run=hs_run, topic_rows=None, connect=None, topic_info=None, ext_rows=None, emit=emit_event, topic_needs=None, watchers=None, db=None):
        self.db = db                             # a DbStore (liveState = "db"); then store is None
        self.took = {}                           # topic -> milliseconds of its last read
        self.backend = "state.db" if db else "redis"
        self.beat_every = beat_every()
        self.watchers = watchers                 # objects with .run(); None = the defaults DockerWatch and IncusWatch
        self.emit = emit                         # (kind, subject, text) -> None; a test passes its own
        self.store = store                       # Resp (or a fake) for writing
        self.run = run
        self.rows = topic_rows if topic_rows is not None else ls.topics()
        self.connect = connect                   # () -> store; reconnect after an error
        self.events = {t[0]: threading.Event() for t in self.rows}
        self.stops = {t[0]: threading.Event() for t in self.rows}      # one per topic: set when the topic goes away (a package switched off)
        self.tlock = threading.Lock()                                  # events / stops / info / rows change on a rescan
        self.ext_rows = ext_rows or ls.ext_live                        # () -> (rows, info) of the extension reads
        self.last_scan = 0.0
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.info = topic_info if topic_info is not None else ls.topic_info()
        try:
            n = int(os.environ.get("HS_LIVE_PARALLEL", "4"))
        except ValueError:
            n = 4
        self.sem = threading.BoundedSemaphore(n if n >= 1 else 4)   # at most N reads at once
        self.needs_src = dict(topic_needs if topic_needs is not None else ls.topic_needs())
        try:
            gap = float(os.environ.get("HS_LIVE_MIN_GAP", "5"))
        except ValueError:
            gap = 5.0
        self.min_gap = gap if math.isfinite(gap) and gap >= 0 else 5.0      # inf and NaN fall back
        self.pending = set()                     # changed topics that wait for the next wave
        self.wcond = threading.Condition()
        self.last_read = {}                      # topic -> time of its last read (by its thread or a wave)
        self.busy = {}                           # topic -> lock: one read of a topic at a time
        self._said = set()
        for p in self._regraph():
            self.say(p)

    def _regraph(self):
        """Order and clean needs of the topics now in rows (init, or with tlock held). -> problem texts."""
        known = {r[0] for r in self.rows}
        self.order, self.needs, problems = ls.graph(self.needs_src, known)
        self.needed = {n for ts in self.needs.values() for n in ts}
        return problems

    def say(self, msg):
        """a journal line, once per distinct text (a rescan finds the same problem every minute)"""
        if len(self._said) > 1000:
            self._said.clear()
        if msg not in self._said:
            self._said.add(msg)
            log(msg)

    def locked(self):
        return os.path.exists(os.environ.get("HS_LOCKED_MARKER", "/run/hs/storage-locked"))

    def refresh(self, topic):
        """"*" = every topic; "@g" = the topics that list the group g or `any`; else the topic of that name."""
        if topic.startswith("ext-") and topic not in self.events:
            self.rescan(self.RESCAN_MIN)      # a package was switched on a moment ago: the web interface asks for its topic
        with self.tlock:
            items = list(self.events.items())
            info = dict(self.info)
        woken = []
        for t, ev in items:
            if topic == "*" or topic == t:
                ev.set()
                woken.append(t)
            elif topic.startswith("@"):
                groups = (info.get(t) or {}).get("groups", set())
                if topic[1:] in groups or "any" in groups:
                    ev.set()
                    woken.append(t)
        # one journal line per request (journalctl -u hs-live): which topics it woke, so a stale page can be traced to a missing or late refresh
        log("refresh %s -> %s" % (topic, "all %d topics" % len(woken) if topic == "*" else (", ".join(woken) or "no topic")))

    def collect(self, topic, words, mode="run"):
        """One read of one topic. Returns True when the output differs from the last read (new gen, published); an identical read only moves ts."""
        if mode == "skip" and self.locked():
            return False
        if not ls.cap_on((self.info.get(topic) or {}).get("cap")):
            return False      # the capability is off: no read, no document
        with self.tlock:
            busy = self.busy.setdefault(topic, threading.Lock())
        with busy:      # a wave and the topic's own thread never read the same topic at once
            with self.sem:
                t0 = time.monotonic()
                rc, out, err = self.run(words)
                self.took[topic] = int((time.monotonic() - t0) * 1000)
            now = time.time()
            self.last_read[topic] = now
            ev = []
            try:
                return self._store(topic, rc, out, err, now, ev)
            finally:
                for kind, text in ev:      # outside the lock: writing an event must not hold the other topics back
                    self.emit(kind, topic, text)

    def _meta(self, topic):
        """(src, ttl) of a topic for its document: the words of the read and the seconds it counts as fresh (live-topics.tsv column 8, else 3 x interval)"""
        for r in self.rows:
            if r[0] == topic:
                return " ".join(r[1]), (self.info.get(topic) or {}).get("ttl") or 3 * r[2]
        return None, None

    def _store_db(self, topic, rc, out, err, now, ev):
        """Like the Redis branch, but nothing is written when nothing changed (the document keeps its time of the last change)."""
        src, ttl = self._meta(topic)
        ms = self.took.get(topic)
        with self.lock:
            old = self.db.get(topic) or {}
            if rc == 0 or out:
                if old.get("err"):
                    ev.append(("live.collector-recovered", "live state '%s' reads again" % topic))
                if old and old.get("rc") == rc and old.get("payload") == out and not old.get("err"):
                    return False
                self.db.put(topic, out, rc, ms, src, ttl, now)
                return True
            text = ls.clean(err or "no output")
            if old.get("err") == text and old.get("rc") == rc:
                log("topic %s failed (rc %s): %s" % (topic, rc, text))
                return False
            if not old.get("err"):
                ev.append(("live.collector-failed", "live state '%s' failed (rc %s): %s" % (topic, rc, text)))
            self.db.fail(topic, rc, ms, text, src, ttl, now)
            log("topic %s failed (rc %s): %s" % (topic, rc, text))
            return False

    def _store(self, topic, rc, out, err, now, ev):
        if self.db is not None:
            return self._store_db(topic, rc, out, err, now, ev)
        src, ttl = self._meta(topic)
        with self.lock:
            try:
                raw = self.store.cmd("GET", ls.KEY % topic)
                old = json.loads(raw) if raw else {}
            except ValueError:
                old = {}
            if rc == 0 or out:
                if old.get("err"):
                    ev.append(("live.collector-recovered", "live state '%s' reads again" % topic))
                if old and old.get("rc") == rc and old.get("out") == out and old.get("err") is None:
                    # the same output as the last read: only the time moves (the data is still fresh); no new gen, no publish
                    old["ts"] = now
                    old["src"], old["ttl"] = src, ttl      # a document from before #322 gets them here, nothing else moves
                    self.store.cmd("SET", ls.KEY % topic, json.dumps(old))
                    return False
                gen = int(old.get("gen", 0)) + 1
                doc = {"ts": now, "gen": gen, "rc": rc, "out": out, "err": None, "ts_err": None, "state": "ok",
                       "src": src, "ttl": ttl}
                self.store.cmd("SET", ls.KEY % topic, json.dumps(doc))
                self.store.cmd("PUBLISH", ls.CHANGED, "%s %d" % (topic, gen))
                return True
            doc = {"ts": old.get("ts"), "gen": old.get("gen", 0), "rc": old.get("rc", rc), "out": old.get("out", ""),
                   "err": ls.clean(err or "no output"), "ts_err": now, "state": "stale" if old.get("ts") else "error",
                   "src": src, "ttl": ttl}
            if not old.get("err"):      # the change into error, once; the runs that fail after it are only in the journal
                ev.append(("live.collector-failed", "live state '%s' failed (rc %s): %s" % (topic, rc, doc["err"])))
            self.store.cmd("SET", ls.KEY % topic, json.dumps(doc))
            log("topic %s failed (rc %s): %s" % (topic, rc, doc["err"]))
            return False

    def changed(self, topic):
        """A topic got a new gen: queue it when another topic needs it (the wave thread takes the whole set at once)."""
        with self.tlock:
            if topic not in self.needed:
                return
        with self.wcond:
            self.pending.add(topic)
            self.wcond.notify()

    def wave(self, roots):
        """Read the topics that need a changed one, once each, in dependency order (a topic after all it needs). Only a new gen spreads further:
        a failed or identical read does not. -> the topics read."""
        with self.tlock:
            order, needs, rows = list(self.order), dict(self.needs), {r[0]: r for r in self.rows}
        changed, ran = set(roots), []
        for t in order:
            if self.stop.is_set():
                break
            if t not in rows or not changed.intersection(needs.get(t, ())):
                continue
            with self.tlock:
                if t not in self.events:          # an extension topic went away
                    continue
            wait = self.last_read.get(t, 0) + self.min_gap - time.time()
            if wait > 0:
                self.stop.wait(wait)
            ran.append(t)
            if self.collect(t, rows[t][1], rows[t][3]):
                changed.add(t)
        log("wave %s -> %s" % (", ".join(sorted(roots)), ", ".join(ran) or "no topic"))
        return ran

    def waves(self):
        """The one wave thread."""
        while not self.stop.is_set():
            with self.wcond:
                if not self.pending:
                    self.wcond.wait(1.0)
                roots, self.pending = self.pending, set()
            if roots:
                try:
                    self.wave(roots)
                except OSError as e:
                    log("wave stopped, %s down (%s)" % (self.backend, e))

    def loop(self, topic, words, interval, mode):
        ev, mine = self.events[topic], self.stops[topic]
        while not self.stop.is_set() and not mine.is_set():
            try:
                if self.collect(topic, words, mode):
                    self.changed(topic)
            except OSError as e:
                log("%s down (%s), retry in 5 s" % (self.backend, e))
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

    def _spawn(self, topic, words, interval, mode):
        threading.Thread(target=self.loop, args=(topic, words, interval, mode), daemon=True).start()

    def rescan(self, min_gap=0.0):
        """Look at the extension packages that are on: start a thread for a new live topic, stop one that is gone (or whose words or interval
        changed, then it starts again). -> True when something was looked at."""
        now = time.time()
        with self.tlock:
            if now - self.last_scan < min_gap:
                return False
            self.last_scan = now
        try:
            rows, info = self.ext_rows(log=self.say)
        except Exception as e:      # a broken package must not stop the collector
            log("extension scan failed (%s)" % e)
            return False
        want = {r[0]: r for r in rows if r[0].startswith("ext-")}
        start, gone = [], []
        with self.tlock:
            have = {r[0]: r for r in self.rows if r[0].startswith("ext-")}
            for t in list(have):
                if t not in want or want[t] != have[t]:
                    self.stops[t].set()
                    self.events[t].set()
                    del self.events[t], self.stops[t]
                    self.info.pop(t, None)
                    self.needs_src.pop(t, None)
                    self.busy.pop(t, None)
                    self.rows = [r for r in self.rows if r[0] != t]
                    gone.append(t)
            for t, r in want.items():
                if t not in self.events:
                    self.events[t], self.stops[t] = threading.Event(), threading.Event()
                    self.info[t] = info.get(t) or {"cap": None, "groups": set()}
                    self.needs_src[t] = tuple((info.get(t) or {}).get("needs", ()))
                    self.rows.append(r)
                    start.append(r)
            for t in want:      # a changed `needs` alone does not restart the topic
                if t in self.events:
                    self.needs_src[t] = tuple((info.get(t) or {}).get("needs", ()))
            problems = self._regraph()
        for p in problems:
            self.say(p)
        for t in gone:
            log("topic %s stopped" % t)
            try:
                with self.lock:
                    if self.db is not None:
                        self.db.delete(t)
                    else:
                        self.store.cmd("DEL", ls.KEY % t)      # the document of a topic that is gone is not served any more
            except OSError:
                pass
        for r in start:
            log("topic %s started" % r[0])
            self._spawn(*r)
        return True

    def watch(self):
        while not self.stop.wait(self.RESCAN):
            self.rescan()

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

    def beat(self):
        """The heartbeat thread (db mode): one row every beat_every seconds; the web says `down` when it gets old."""
        said = False
        while not self.stop.is_set():
            try:
                self.db.beat(self.beat_every, int(max(self.last_read.values())) if self.last_read else None)
                said = False
            except OSError as e:
                if not said:
                    log("heartbeat not written (%s)" % e)
                    said = True
            self.stop.wait(self.beat_every)

    def start(self):
        for topic, words, interval, mode in list(self.rows):
            self._spawn(topic, words, interval, mode)
        if self.db is not None:
            threading.Thread(target=self.beat, daemon=True).start()      # no Redis channel: topics are read at their intervals
        else:
            threading.Thread(target=self.listen, daemon=True).start()
        threading.Thread(target=self.watch, daemon=True).start()
        threading.Thread(target=self.waves, daemon=True).start()
        self.rescan()      # once now: a missing needs target is in the journal from the start
        for w in (self.watchers if self.watchers is not None else [DockerWatch(self.refresh, self.stop), IncusWatch(self.refresh, self.stop)]):
            threading.Thread(target=w.run, daemon=True).start()


def main():
    if os.environ.get("HS_LIVE_STORE") == "db":
        db = None
        while db is None:
            try:
                db = DbStore()
            except (OSError, sqlite3.Error) as e:
                log("state.db not usable (%s), retry in 5 s" % e)
                time.sleep(5)
        c = Collector(None, db=db)
        log("hs-live (state.db): %d topic(s)" % len(c.rows))
        c.start()
        while True:
            time.sleep(3600)

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
