"""Chat commands for the Matrix hook: the owner types `help`, `clear`, `status`, `test`, `mute` in the room
"Homeserver bot" (a private, unencrypted chat the bot makes and invites the owner to) or in a room the bot
manages, and the bot answers there. Standard library only.

Only messages from the owner (the configured Matrix ID), in rooms the bot made, count; everybody else
is ignored without an answer. Messages from before the bot started are ignored too, so an old `clear`
is never run again after a restart.

The parsing (times, durations, the clear arguments) is plain functions, tested on their own
(tests/matrix-chat-test.py); the Bot class does the talking to Matrix.
"""
import json
import os
import re
import sys
import threading
import time
import urllib.parse
import uuid
from datetime import datetime, timedelta

DEFAULT_MUTE = "2h"
SERVICES = ("radarr", "sonarr", "seerr", "maintainerr", "sabnzbd")
# what the chat calls a service: the key stays `sabnzbd` inside (mutes.json, payloads), the name typed and shown is Downloadarr
ALIASES = {"downloadarr": "sabnzbd"}
SHOWN = {"sabnzbd": "Downloadarr"}


def service_key(word):
    word = word.lower()
    return ALIASES.get(word, word)


def shown(key):
    return SHOWN.get(key, key.title())

HELP = """**Commands** (only for you, in this room; no slash, just type the word). Where a command needs a room, name it first (`media`); without a name it is the room you are typing in, or `media` when you type here.

- `help` or `?`: this list
- `clear [<room>] [from <time>] [to <time>]`: delete the messages of a room in a time range. It first says how many and waits for `yes` (60 seconds); `no` cancels.
  - no `from`: from the beginning of the room; no `to`: up to now
  - `<time>` is a date (`2026-10-01`), a date and time (`2026-10-01 14:30`), or how long ago (`30m`, `12h`, `7d`, `2w`), also `today` and `yesterday`
  - a date alone means its start for `from` and its end for `to`
  - `clear to 7d` deletes everything older than a week; `clear` alone deletes everything
- `status`: cards on or off, the rooms, what is muted, when each service last posted
- `test [<room>]`: one test card each for Radarr, Sonarr, Seerr, Maintainerr and Downloadarr
- `mute <radarr|sonarr|seerr|maintainerr|downloadarr|all> [<duration>]`: drop events for a while (default 2h), for example during a library import
- `unmute [<radarr|sonarr|seerr|maintainerr|downloadarr|all>]`: post events again

Deleted messages stay behind as empty "message deleted" entries until Synapse removes their content; Element can hide them (Settings, Preferences, "Show a placeholder for removed messages")."""

USAGE_CLEAR = "Usage: `clear [<room>] [from <time>] [to <time>]`, for example `clear media to 7d` or `clear media from 2026-10-01 to 2026-10-15 12:00`. Type `help` for the details."


# ── parsing ──
def parse_duration(text):
    """'90m', '2h', '7d', '2w' -> a timedelta, or None."""
    m = re.fullmatch(r"(\d+)\s*([mhdw])", str(text).strip().lower())
    if not m:
        return None
    n, unit = int(m.group(1)), m.group(2)
    return timedelta(**{{"m": "minutes", "h": "hours", "d": "days", "w": "weeks"}[unit]: n})


def parse_time(text, now, end=False):
    """A point in time (a datetime in now's timezone) from what a person types, or None.

    `now` is a timezone-aware datetime. A date without a time is the start of that day, or its last
    moment when `end` is true (the `to` side of a range)."""
    t = str(text).strip().lower()
    if t == "now":
        return now
    delta = parse_duration(t)
    if delta is not None:
        return now - delta
    day = None
    if t == "today":
        day = now.date()
    elif t == "yesterday":
        day = (now - timedelta(days=1)).date()
    if day is not None:
        start = datetime(day.year, day.month, day.day, tzinfo=now.tzinfo)
        return start + timedelta(days=1) - timedelta(milliseconds=1) if end else start
    m = re.fullmatch(r"(\d{4})-(\d{2})-(\d{2})(?:[t ]+(\d{1,2}):(\d{2})(?::(\d{2}))?)?", t)
    if not m:
        return None
    y, mo, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
    try:
        if m.group(4) is None:
            start = datetime(y, mo, d, tzinfo=now.tzinfo)
            return start + timedelta(days=1) - timedelta(milliseconds=1) if end else start
        return datetime(y, mo, d, int(m.group(4)), int(m.group(5)), int(m.group(6) or 0), tzinfo=now.tzinfo)
    except ValueError:
        return None


def parse_clear(args, now):
    """'from X to Y' -> (start_ms or None, end_ms, error text or None)."""
    words = args.split()
    parts = {}
    key = None
    for w in words:
        if w.lower() in ("from", "to") and w.lower() not in parts:
            key = w.lower()
            parts[key] = []
        elif key is None:
            return None, None, "I did not understand `%s`. %s" % (w, USAGE_CLEAR)
        else:
            parts[key].append(w)
    start = end = None
    if "from" in parts:
        start = parse_time(" ".join(parts["from"]), now)
        if start is None:
            return None, None, "I could not read the time after `from`. %s" % USAGE_CLEAR
    end = now
    if "to" in parts:
        end = parse_time(" ".join(parts["to"]), now, end=True)
        if end is None:
            return None, None, "I could not read the time after `to`. %s" % USAGE_CLEAR
    if start is not None and start >= end:
        return None, None, "`from` is not before `to`. %s" % USAGE_CLEAR
    return (int(start.timestamp() * 1000) if start else None), int(end.timestamp() * 1000), None


def parse_mute(args):
    """'radarr 2h' -> (list of services, timedelta, error)."""
    words = args.split()
    if not words or service_key(words[0]) not in SERVICES + ("all",):
        return None, None, "Usage: `mute <radarr|sonarr|seerr|maintainerr|downloadarr|all> [<duration>]`, for example `mute radarr 2h`."
    services = list(SERVICES) if words[0].lower() == "all" else [service_key(words[0])]
    delta = parse_duration(words[1] if len(words) > 1 else DEFAULT_MUTE)
    if delta is None or delta <= timedelta(0):
        return None, None, "I could not read the duration. Use `30m`, `2h`, `1d`."
    return services, delta, None


class Mutes:
    """Services whose events are dropped until a time; kept in a file so a restart does not forget them."""

    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()
        try:
            with open(path) as f:
                self.until = {k: float(v) for k, v in json.load(f).items()}
        except (OSError, ValueError):
            self.until = {}

    def _save(self):
        try:
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            with open(self.path + ".tmp", "w") as f:
                json.dump(self.until, f)
            os.replace(self.path + ".tmp", self.path)
        except OSError:
            pass

    def is_muted(self, service):
        with self.lock:
            return self.until.get(service, 0) > time.time()

    def mute(self, services, delta):
        with self.lock:
            for s in services:
                self.until[s] = time.time() + delta.total_seconds()
            self._save()

    def unmute(self, services):
        with self.lock:
            for s in services:
                self.until.pop(s, None)
            self._save()

    def active(self):
        with self.lock:
            return {k: v for k, v in self.until.items() if v > time.time()}


def when(ts, tz):
    """'14:30', or '2026-10-12 14:30' when it is not today."""
    d = datetime.fromtimestamp(ts, tz)
    return d.strftime("%H:%M") if d.date() == datetime.now(tz).date() else d.strftime("%Y-%m-%d %H:%M")


# ── the bot ──
SYNC_FILTER = {"room": {"timeline": {"limit": 50, "types": ["m.room.message"]}, "state": {"types": []},
                        "ephemeral": {"types": []}, "account_data": {"types": []}},
               "presence": {"types": []}, "account_data": {"types": []}}


class Bot:
    def __init__(self, matrix, owner, tz, mutes, seen, send_text, send_payload, cards_on, state_dir, confirm_seconds=60):
        self.m = matrix
        self.owner = owner
        self.tz = tz
        self.mutes = mutes
        self.seen = seen
        self.send_text = send_text          # (room_id, markdown) -> event id
        self.send_payload = send_payload    # (room name, webhook payload) -> None
        self.cards_on = cards_on
        self.state_dir = state_dir
        self.confirm_seconds = confirm_seconds
        self.started = time.time()
        self.pending = {}                   # room id -> what a `yes` would delete
        self.busy = set()                   # room ids being cleared right now

    def now(self):
        return datetime.now(self.tz).astimezone(self.tz) if self.tz else datetime.now().astimezone()

    # sync loop: a long poll, one thread
    def setup(self):
        """The room for commands, and the read-only rooms; the server may still be starting, so it retries."""
        while True:
            try:
                self.m.ensure_commands_room()
                if getattr(self.m, "read_only", False):
                    for name, rid in list(self.m.rooms.items()):
                        if not name.startswith("_"):
                            try:
                                self.m.ensure_read_only(rid)
                            except Exception as e:
                                sys.stderr.write("read-only for %s: %s\n" % (name, e))
                return
            except Exception as e:
                sys.stderr.write("setup: %s\n" % e)
                time.sleep(10)

    def run(self):
        self.setup()
        since = None
        while True:
            try:
                query = "filter=" + urllib.parse.quote(json.dumps(SYNC_FILTER)) + (
                    "&timeout=30000&since=" + urllib.parse.quote(since) if since else "&timeout=0")
                data = self.m.call("GET", "/_matrix/client/v3/sync?" + query, timeout=70)
                first = since is None
                since = data["next_batch"]
                if not first:               # the first answer is the backlog: skip it
                    self.handle(data)
            except Exception as e:
                sys.stderr.write("sync: %s\n" % e)
                time.sleep(5)

    def handle(self, data):
        by_id = {rid: name for name, rid in list(self.m.rooms.items())}   # including "_commands"
        for rid, room in (data.get("rooms", {}).get("join") or {}).items():
            if rid not in by_id:
                continue
            for ev in (room.get("timeline") or {}).get("events") or []:
                c = ev.get("content") or {}
                if (ev.get("type") == "m.room.message" and ev.get("sender") == self.owner and c.get("msgtype") == "m.text"
                        and ev.get("origin_server_ts", 0) / 1000 >= self.started - 1):
                    try:
                        self.command(rid, by_id[rid], ev)
                    except Exception as e:
                        sys.stderr.write("command failed: %s\n" % e)
                        self.say(rid, "Something went wrong: `%s`" % str(e)[:150])

    def say(self, rid, text):
        return self.send_text(rid, text)

    def command(self, rid, name, ev):
        body = (ev.get("content") or {}).get("body", "").strip()
        body = re.sub(r"^[!]", "", body)
        word, _, rest = body.partition(" ")
        word = word.lower()
        rest = rest.strip()
        if word in ("help", "?"):
            self.say(rid, HELP)
        elif word == "clear":
            self.clear(rid, ev, rest, name)
        elif word in ("yes", "y", "confirm"):
            self.confirm(rid, ev)
        elif word in ("no", "cancel"):
            if self.pending.pop(rid, None):
                self.say(rid, "Cancelled. Nothing was deleted.")
        elif word == "status":
            self.say(rid, self.status())
        elif word == "test":
            target, _, _, err = self.target(rid, name, rest)
            if err:
                return self.say(rid, err)
            for payload in ({"eventType": "Test", "instanceName": "Radarr"}, {"eventType": "Test", "instanceName": "Sonarr", "series": {"title": "Test"}},
                            {"notification_type": "TEST_NOTIFICATION"},
                            {"hsService": "maintainerr", "event": "Test", "event_icon": "check-circle", "title": "Test message", "footer": "The connection works."},
                            {"hsService": "sabnzbd", "event": "Test", "event_icon": "check-circle", "title": "Test message", "footer": "The connection works."}):
                self.send_payload(target, payload)
        elif word == "mute":
            services, delta, err = parse_mute(rest)
            if err:
                return self.say(rid, err)
            self.mutes.mute(services, delta)
            until = time.time() + delta.total_seconds()
            self.say(rid, "Muted %s until **%s**. `unmute` ends it earlier." % (", ".join("**%s**" % shown(s) for s in services), when(until, self.tz)))
        elif word == "unmute":
            target = service_key(rest)
            if target and target not in SERVICES + ("all",):
                return self.say(rid, "Usage: `unmute [radarr|sonarr|seerr|maintainerr|downloadarr|all]`.")
            self.mutes.unmute(SERVICES if target in ("", "all") else [target])
            self.say(rid, "Posting again: %s." % (shown(target) if target not in ("", "all") else "all services"))

    # status
    def status(self):
        lines = ["**Status**", "- Cards: **%s**" % ("on" if self.cards_on() else "off (text messages)"),
                 "- Running for: %s" % self.uptime(),
                 "- Rooms: %s%s" % (", ".join("`%s`" % n for n in sorted(self.rooms()) ) or "none yet",
                                    " (read-only for you)" if getattr(self.m, "read_only", False) else "")]
        muted = self.mutes.active()
        lines.append("- Muted: %s" % (", ".join("**%s** until %s" % (shown(s), when(t, self.tz)) for s, t in sorted(muted.items())) if muted else "nothing"))
        for s in SERVICES:
            t = self.seen.get(s)
            lines.append("- %s last posted: %s" % (shown(s), when(t, self.tz) if t else "not since the start"))
        try:
            n = len(os.listdir(os.path.join(self.state_dir, "posters")))
        except OSError:
            n = 0
        lines.append("- Posters cached: %d" % n)
        return "\n".join(lines)

    def uptime(self):
        s = int(time.time() - self.started)
        d, s = divmod(s, 86400)
        h, s = divmod(s, 3600)
        return ("%d d " % d if d else "") + "%d h %d min" % (h, s // 60)

    def rooms(self):
        """The rooms that carry messages (name -> room id); not the room for commands."""
        return {n: r for n, r in list(self.m.rooms.items()) if not n.startswith("_")}

    def target(self, rid, name, args):
        """(room id, room name, the rest of the arguments, error): the room a command is about.
        A room name as the first word wins; else the room we are typing in; else `media`."""
        words = args.split()
        rooms = self.rooms()
        if words and words[0].lower() in rooms:
            return rooms[words[0].lower()], words[0].lower(), " ".join(words[1:]), None
        if not name.startswith("_"):
            return rid, name, args, None
        if "media" in rooms:
            return rooms["media"], "media", args, None
        return None, None, args, "Which room? Name it first: %s." % (", ".join("`%s`" % n for n in sorted(rooms)) or "there is none yet")

    # clear
    def clear(self, rid, ev, args, name="_commands"):
        if rid in self.busy:
            return self.say(rid, "A `clear` is still running here.")
        target, tname, args, err = self.target(rid, name, args)
        if err:
            return self.say(rid, err)
        start, end, err = parse_clear(args, self.now())
        if err:
            return self.say(rid, err)
        ids = self.collect(target, start, end, skip=ev["event_id"] if target == rid else None)
        span = "%s to %s" % (when(start / 1000, self.tz) if start else "the beginning", when(end / 1000, self.tz))
        if not ids:
            return self.say(rid, "Nothing to delete in `%s` from %s." % (tname, span))
        prompt = self.say(rid, "This deletes **%d** messages in `%s` (%s). Reply `yes` within %d seconds, or `no`." % (len(ids), tname, span, self.confirm_seconds))
        self.pending[rid] = {"room": target, "name": tname, "ids": ids, "expires": time.time() + self.confirm_seconds,
                             "extra": [(rid, ev["event_id"]), (rid, prompt)], "span": span}

    def collect(self, rid, start, end, skip=None):
        """Event ids of the messages in the range, newest first; already deleted ones are left out."""
        ids, token = [], None
        quoted = urllib.parse.quote(rid, safe="")
        flt = urllib.parse.quote(json.dumps({"types": ["m.room.message"]}))
        while len(ids) < 50000:
            path = "/_matrix/client/v3/rooms/%s/messages?dir=b&limit=100&filter=%s" % (quoted, flt)
            if token:
                path += "&from=" + urllib.parse.quote(token)
            data = self.m.call("GET", path)
            chunk = data.get("chunk") or []
            oldest_ok = False
            for e in chunk:
                ts = e.get("origin_server_ts", 0)
                if start is not None and ts < start:
                    oldest_ok = True
                    continue
                if ts <= end and e.get("event_id") != skip and not (e.get("unsigned") or {}).get("redacted_because") and e.get("content"):
                    ids.append(e["event_id"])
            token = data.get("end")
            if not chunk or not token or oldest_ok:
                break
        return ids

    def confirm(self, rid, ev):
        p = self.pending.pop(rid, None)
        if p is None:
            return
        if time.time() > p["expires"]:
            return self.say(rid, "That took longer than %d seconds, nothing was deleted. Send `clear` again." % self.confirm_seconds)
        self.busy.add(rid)
        threading.Thread(target=self.do_clear, args=(rid, p["room"], p["name"], p["ids"], p["extra"] + [(rid, ev["event_id"])], p["span"]), daemon=True).start()

    def redact(self, rid, event_id):
        quoted = urllib.parse.quote(rid, safe="")
        for _ in range(60):
            try:
                self.m.call("PUT", "/_matrix/client/v3/rooms/%s/redact/%s/%s" % (quoted, urllib.parse.quote(event_id, safe=""), uuid.uuid4().hex),
                            {"reason": "hs-bot clear"})
                return True
            except Exception as e:
                if getattr(e, "status", 0) == 429:     # the server's rate limit: wait as long as it says
                    time.sleep(max(getattr(e, "retry_ms", 1000), 50) / 1000 + 0.05)
                    continue
                sys.stderr.write("redact failed: %s\n" % e)
                return False
        return False

    def do_clear(self, rid, target, tname, ids, extra, span):
        done = failed = 0
        started = time.time()
        try:
            for event_id in ids:
                if self.redact(target, event_id):
                    done += 1
                else:
                    failed += 1
            for room_id, event_id in extra:        # the command, the question and the answer, where they were typed
                if event_id:
                    self.redact(room_id, event_id)
            self.say(rid, "Deleted **%d** messages in `%s` (%s) in %d s.%s" % (done, tname, span, time.time() - started, " %d could not be deleted." % failed if failed else ""))
        finally:
            self.busy.discard(rid)
