#!/usr/bin/env python3
"""One event for the helpers that run next to the film apps. It tells the server what happened; it sends nothing.

  hs-media-notify.py send --service maintainerr|sabnzbd --event <name> --title T [--sub S] [--field K=V]... [--footer F]
  hs-media-notify.py <type> <title> <message>        SABnzbd's notification script (it calls a script like this)

The event is a file in the spool folder (config key "spool", default /media/.hs-events: the share the container has mounted anyway).
The server reads the folder (scripts/event-notify.sh), writes the event pkg.<service>.<event> to its event log, and its
notification rules (the package's `[[events]]`; scripts/lib/pkg-events/ until the recipes ship it) decide who is told, in which channel and how. No address, topic or secret is kept here.

Config (JSON, written by the recipes): {"spool": "/media/.hs-events", "radarr": {"url": "http://radarr:7878", "key": "..."}, "sonarr": {...}}.
Each may be missing; radarr/sonarr only serve the lookup that turns a release name into a title, year and poster for the Downloadarr
cards. It is looked for in $HS_MEDIA_NOTIFY_CONF, next to this file, one folder up, /etc/hs-media-notify.json.
Never fails its caller: an event that cannot be written is a line on stderr, exit 0.
Test knob: HS_MEDIA_NOTIFY_LOG=<file> appends the event as a JSON line and writes no spool file.

The labels and icons of one service live here (and the card in matrix-card/); the card only draws what the payload says, so a
new event is a new row in EVENTS.
"""
import json
import json as _json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))

# service -> shown name. "Maintainerr (Script)" on purpose: the messages of this script and the ones of
# Maintainerr itself (if it ever posts) must be told apart in the history of ntfy and Matrix.
NAMES = {"maintainerr": "Maintainerr (Script)", "sabnzbd": "Downloadarr"}

# (service, event) -> (label, icon of the card). How loud an event is and its rule live in the package's `[[events]]` (scripts/lib/pkg-events/ until the recipes ship it).
# An event name is the last part of the kind pkg.<service>.<event>: lower case, digits and "-".
EVENTS = {
    ("maintainerr", "planned"): ("Duplicate found", "warning"),
    ("maintainerr", "deleted"): ("Lower version deleted", "trash"),
    ("maintainerr", "test"): ("Test", "check-circle"),
    ("sabnzbd", "added"): ("Download queued", "download-simple"),
    ("sabnzbd", "unpacking"): ("Unpacking", "package"),
    ("sabnzbd", "finished"): ("Download finished", "tray-arrow-down"),
    ("sabnzbd", "failed"): ("Download failed", "warning-octagon"),
    ("sabnzbd", "queue-done"): ("Queue finished", "checks"),
    ("sabnzbd", "disk-full"): ("Disk full", "warning-octagon"),
    ("sabnzbd", "error"): ("Error", "warning-octagon"),
    ("sabnzbd", "warning"): ("Warning", "warning"),
    ("sabnzbd", "test"): ("Test", "check-circle"),
}

# what SABnzbd calls an event -> ours (startup, new_login and everything unknown are not sent)
SAB_TYPES = {"download": "added", "pp": "unpacking", "complete": "finished", "failed": "failed",
             "queue_done": "queue-done", "disk_full": "disk-full", "error": "error", "warning": "warning",
             "other": "test"}   # the Test button of SABnzbd sends "other"


def load_config():
    for path in (os.environ.get("HS_MEDIA_NOTIFY_CONF"), os.path.join(HERE, "hs-media-notify.json"),
                 os.path.join(HERE, "..", "hs-media-notify.json"), "/etc/hs-media-notify.json"):
        if path and os.path.isfile(path):
            try:
                with open(path) as f:
                    return json.load(f)
            except (OSError, ValueError) as e:
                sys.stderr.write("hs-media-notify: %s: %s\n" % (path, e))
    return {}


QUALITY = re.compile(r"^(2160p|1080p|720p|576p|480p|4k|uhd|hdr|hdr10|dv|german|english|multi|dl|dubbed|bluray|blu-ray|bdrip|brrip|"
                     r"web|webrip|web-dl|webdl|hdtv|dvdrip|remux|x264|x265|h264|h265|hevc|avc|proper|repack|internal|complete)$", re.I)
EPISODE = re.compile(r"^S(\d{1,2})(?:E(\d{1,3}))?(?:-?E\d{1,3})?$", re.I)


def parse_release(name):
    """'Mad.Max.2.Der.Vollstrecker.1981.German.DL.2160p.x265-GRP.nzb' -> (title, year, 'S01E03' or '', is_series)."""
    name = re.sub(r"\.(nzb|mkv|mp4|avi|zip|rar)$", "", name.strip(), flags=re.I)
    words = re.sub(r"[._]+", " ", name).split()
    title, year, episode = [], "", ""
    for i, w in enumerate(words):
        if i > 0 and re.fullmatch(r"(19|20)\d\d", w):
            year = w
            # "From.2022.S01E01": the episode marker may follow the year, and it decides movie or series
            episode = next((x.upper() for x in words[i + 1:i + 3] if EPISODE.match(x)), "")
            break
        if i > 0 and EPISODE.match(w):
            episode = w.upper()
            break
        if i > 0 and QUALITY.match(w):
            break
        title.append(w)
    return " ".join(title), year, episode, bool(episode)


def _norm(s):
    return re.sub(r"[^a-z0-9]+", " ", str(s or "").lower()).strip()


def lookup(conf, title, year, series):
    """(title, year, poster url) from Radarr's or Sonarr's own lookup, or None. Tries the whole title, then fewer words."""
    app = conf.get("sonarr" if series else "radarr") or {}
    if not app.get("url") or not app.get("key"):
        return None
    words = title.split()
    for n in range(len(words), 0, -1):
        term = " ".join(words[:n]) + ((" " + year) if year and not series else "")
        try:
            url = "%s/api/v3/%s/lookup?term=%s" % (app["url"], "series" if series else "movie", urllib.parse.quote(term))
            req = urllib.request.Request(url, headers={"X-Api-Key": app["key"]})
            with urllib.request.urlopen(req, timeout=10) as r:
                found = _json.load(r)
        except Exception:   # noqa: BLE001 - no lookup, no poster
            return None
        wanted = _norm(" ".join(words[:n]))
        for item in found:
            if year and str(item.get("year")) != year:
                continue
            # the first hit of a search is often another title ("FROM" -> "From Dusk Till Dawn"): without a year to
            # confirm it, or on a shortened title, the name must match exactly, else no poster beats a wrong one
            if (not year or n < len(words)) and wanted not in (_norm(item.get("title")), _norm(item.get("originalTitle"))):
                continue
            poster = next((i.get("remoteUrl") for i in item.get("images") or [] if str(i.get("coverType")).lower() == "poster"), "")
            return item.get("title") or " ".join(words[:n]), str(item.get("year") or year or ""), (poster or "").replace("/t/p/original/", "/t/p/w342/")
    return None


def markdown(service, label, title, sub, fields, footer):
    lines = ["**%s**" % title + (" · %s" % sub if sub else "")]
    facts = " · ".join("%s: %s" % (k, v) for k, v in fields)
    if facts:
        lines.append(facts)
    if footer and footer != title:
        lines.append("`%s`" % footer.replace("`", "'")[:200])
    return "\n".join(lines)


def send(service, event, title, sub="", fields=(), footer="", poster_url=""):
    label, icon = EVENTS.get((service, event), (event, "check-circle"))
    name = NAMES.get(service, service)
    fields = [(k, v) for k, v in fields if v not in (None, "")]
    # a flat payload (docs/events.md): the fields of the card are one string, a "K=V" per line
    payload = {"service": service, "name": name, "label": label, "icon": icon, "title": title, "sub": sub,
               "body": markdown(service, label, title, sub, fields, footer),
               "fields": "\n".join("%s=%s" % kv for kv in fields), "footer": footer, "poster_url": poster_url}
    row = {"kind": "pkg.%s.%s" % (service, event), "subject": service, "text": "%s: %s" % (label, title),
           "payload": {k: v for k, v in payload.items() if v != ""}}
    log = os.environ.get("HS_MEDIA_NOTIFY_LOG")
    if log:
        with open(log, "a") as f:
            f.write(json.dumps({"service": service, "event": event, "title": title, "sub": sub, "fields": fields, "footer": footer, "poster_url": poster_url}) + chr(10))
        return
    spool = load_config().get("spool") or "/media/.hs-events"
    try:
        os.makedirs(spool, exist_ok=True)
        # written under a name the server skips, then renamed: it never reads half a file
        tmp = os.path.join(spool, ".tmp-%d-%d" % (os.getpid(), time.time_ns()))
        with open(tmp, "w") as f:
            json.dump(row, f)
        os.rename(tmp, os.path.join(spool, "ev-%d-%d.json" % (time.time_ns(), os.getpid())))
    except OSError as e:   # never fail the caller
        sys.stderr.write("hs-media-notify: %s: %s\n" % (spool, e))


def main(argv):
    if len(argv) >= 2 and argv[1] == "send":
        import argparse
        ap = argparse.ArgumentParser(prog="hs-media-notify.py send")
        ap.add_argument("--service", required=True, choices=sorted(NAMES))
        ap.add_argument("--event", required=True)
        ap.add_argument("--title", required=True)
        ap.add_argument("--sub", default="")
        ap.add_argument("--field", action="append", default=[], metavar="K=V")
        ap.add_argument("--footer", default="")
        a = ap.parse_args(argv[2:])
        send(a.service, a.event, a.title, a.sub, [tuple(x.split("=", 1)) if "=" in x else (x, "") for x in a.field], a.footer)
    elif len(argv) >= 3:
        # SABnzbd's script call: its own title ("Job finished") is our label already, the message is the job's name
        event = SAB_TYPES.get(argv[1])
        if event:
            name = argv[3] if len(argv) > 3 and argv[3] else argv[2]
            title, sub, poster = name, "", ""
            if event in ("added", "unpacking", "finished", "failed"):
                # a release name is no title: "Mad Max 2" 1981 with its poster, from Radarr's / Sonarr's lookup; without a hit
                # the cleaned name still beats the dotted one
                words, year, episode, series = parse_release(name)
                if words:
                    title, sub = words, " · ".join(x for x in (year, episode) if x)
                    found = lookup(load_config(), words, year, series)
                    if found:
                        title, year2, poster = found
                        sub = " · ".join(x for x in (year2, episode) if x)
            send("sabnzbd", event, title, sub, [], re.sub(r"\.nzb$", "", name, flags=re.I), poster)
    else:
        sys.stderr.write(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
