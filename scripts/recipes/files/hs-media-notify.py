#!/usr/bin/env python3
"""One message to ntfy AND to the Matrix hook, for the helpers that run next to the film apps.

  hs-media-notify.py send --service maintainerr|sabnzbd --event <name> --title T [--sub S] [--field K=V]... [--footer F]
  hs-media-notify.py <type> <title> <message>        SABnzbd's notification script (it calls a script like this)

Config (JSON, written by the recipes): {"ntfy": "https://server/topic", "hook": "http://synapse:8090/hook/<secret>/<room>",
"radarr": {"url": "http://arr:7878", "key": "..."}, "sonarr": {...}}. Each may be missing; radarr/sonarr only serve the lookup
that turns a release name into a title, year and poster for the Downloadarr cards. It is looked for in $HS_MEDIA_NOTIFY_CONF, next to this file, one folder up, /etc/hs-media-notify.json.
Never fails its caller: a message that cannot be sent is a line on stderr, exit 0.
Test knob: HS_MEDIA_NOTIFY_LOG=<file> appends the message as a JSON line and sends nothing.

The labels, icons and the look of one service live here (and the card in matrix-card/); the hook only draws
what the payload says, so a new event is a new row in EVENTS.
"""
import json
import json as _json
import os
import re
import sys
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))

# service -> shown name. "Maintainerr (Script)" on purpose: the messages of this script and the ones of
# Maintainerr itself (if it ever posts) must be told apart in the history of ntfy and Matrix.
NAMES = {"maintainerr": "Maintainerr (Script)", "sabnzbd": "Downloadarr"}

# (service, event) -> (label, icon of the card, ntfy emoji tag, ntfy priority)
EVENTS = {
    ("maintainerr", "planned"): ("Duplicate found", "warning", "mag", 3),
    ("maintainerr", "deleted"): ("Lower version deleted", "trash", "wastebasket", 3),
    ("maintainerr", "test"): ("Test", "check-circle", "white_check_mark", 2),
    ("sabnzbd", "added"): ("Download queued", "download-simple", "inbox_tray", 2),
    ("sabnzbd", "unpacking"): ("Unpacking", "package", "package", 1),
    ("sabnzbd", "finished"): ("Download finished", "tray-arrow-down", "white_check_mark", 3),
    ("sabnzbd", "failed"): ("Download failed", "warning-octagon", "x", 4),
    ("sabnzbd", "queue_done"): ("Queue finished", "checks", "tada", 2),
    ("sabnzbd", "disk_full"): ("Disk full", "warning-octagon", "rotating_light", 5),
    ("sabnzbd", "error"): ("Error", "warning-octagon", "rotating_light", 4),
    ("sabnzbd", "warning"): ("Warning", "warning", "warning", 3),
    ("sabnzbd", "test"): ("Test", "check-circle", "white_check_mark", 2),
}

# what SABnzbd calls an event -> ours (startup, new_login and everything unknown are not sent)
SAB_TYPES = {"download": "added", "pp": "unpacking", "complete": "finished", "failed": "failed",
             "queue_done": "queue_done", "disk_full": "disk_full", "error": "error", "warning": "warning",
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


def post(url, data, headers):
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=60) as r:
        r.read()


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
    label, icon, tag, prio = EVENTS.get((service, event), (event, "check-circle", "bell", 3))
    name = NAMES.get(service, service)
    fields = [(k, v) for k, v in fields if v not in (None, "")]
    log = os.environ.get("HS_MEDIA_NOTIFY_LOG")
    if log:
        with open(log, "a") as f:
            f.write(json.dumps({"service": service, "event": event, "title": title, "sub": sub, "fields": fields, "footer": footer, "poster_url": poster_url}) + "\n")
        return
    conf = load_config()
    if conf.get("ntfy"):
        try:
            post(conf["ntfy"], markdown(service, label, title, sub, fields, footer).encode(),
                 {"Title": ("%s · %s" % (name, label)).encode("utf-8").decode("latin-1", "replace"),
                  "Tags": tag, "Priority": str(prio), "Markdown": "yes"})
        except Exception as e:   # noqa: BLE001 - never fail the caller
            sys.stderr.write("hs-media-notify: ntfy: %s\n" % e)
    if conf.get("hook"):
        try:
            post(conf["hook"], json.dumps({"hsService": service, "event": label, "event_icon": icon, "title": title, "sub": sub,
                                           "fields": fields, "footer": footer, "poster_url": poster_url}).encode(), {"Content-Type": "application/json"})
        except Exception as e:   # noqa: BLE001
            sys.stderr.write("hs-media-notify: matrix: %s\n" % e)


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
