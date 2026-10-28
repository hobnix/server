"""Webhook payloads (Radarr, Sonarr, Seerr) -> the spec of a notification card, and its text version.

No Pillow here: the spec is plain data that card.py draws, and the text (markdown) is what the room
gets when a card cannot be made, and the alt text of the card. `spec_for(payload)` returns None for an
event that is not posted. Field names are from the Radarr and Sonarr source (Notifications/Webhook/*.cs)
and Seerr's default JSON payload; a field that is missing is simply left out of the card.
"""
import re
from datetime import datetime

ESC_SET = r"\\`*_\[\]"


def esc(value):
    """Make a value from a payload safe inside a markdown message."""
    return re.sub("([" + ESC_SET + "])", r"\\\1", str(value))


def human_size(n):
    try:
        n = float(n)
    except (TypeError, ValueError):
        return ""
    if n <= 0:
        return ""
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return ("%d %s" % (n, unit)) if unit == "B" else ("%.1f %s" % (n, unit))
        n /= 1024


def now_text(tz=None):
    return datetime.now(tz).strftime("%H:%M")


def dirname(path):
    path = str(path or "")
    return path.rsplit("/", 1)[0] if "/" in path else ""


def camel_words(name):
    """'IndexerStatusCheck' -> 'Indexer status'."""
    name = re.sub(r"Check$", "", str(name or ""))
    words = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", " ", name).strip()
    return (words[:1].upper() + words[1:].lower()) if words else ""


def poster_url(obj):
    """The remote address of the poster in a movie / series object, a medium size when it is TMDB."""
    for img in (obj or {}).get("images") or []:
        if str(img.get("coverType", "")).lower() == "poster":
            url = img.get("remoteUrl") or ""
            if url.startswith("http"):
                return url.replace("/t/p/original/", "/t/p/w342/")
    return None


def _spec(service, event, event_icon, title="", sub="", fields=None, footer="", **more):
    spec = {"service": service, "event": event, "event_icon": event_icon, "title": title, "sub": sub,
            "fields": [(f[0], f[1]) for f in (fields or []) if f and f[1] not in (None, "")], "footer": footer}
    spec.update(more)
    return spec


def _which(p):
    """radarr or sonarr: by the payload's own objects, else by the name of the instance."""
    if "movie" in p or "remoteMovie" in p or "renamedMovieFiles" in p:
        return "radarr"
    if "series" in p or "episodes" in p:
        return "sonarr"
    name = str(p.get("instanceName") or p.get("applicationUrl") or "").lower()
    return "sonarr" if "sonarr" in name else "radarr"


def _episodes(p):
    """(sub, 'Episode' value) from the episodes of a Sonarr payload."""
    eps = p.get("episodes") or []
    if not eps:
        return "", ""
    pack = str((p.get("release") or {}).get("releaseType", "")).lower() == "seasonpack"
    seasons = {e.get("seasonNumber") for e in eps}
    if len(eps) == 1:
        e = eps[0]
        return "S%02dE%02d" % (e.get("seasonNumber", 0), e.get("episodeNumber", 0)), e.get("title", "")
    if len(seasons) == 1:
        s = next(iter(seasons))
        nums = sorted(e.get("episodeNumber", 0) for e in eps)
        if pack:
            return "Season %d" % s, "%d episodes" % len(eps)
        return "S%02dE%02d–E%02d" % (s, nums[0], nums[-1]), "%d episodes" % len(eps)
    return "%d episodes" % len(eps), ""


REASONS = {"Manual": "Manual", "MissingFromDisk": "Missing from disk", "Upgrade": "Upgrade", "NoLinkedEpisodes": "No linked episodes"}


def _arr(p):
    ev = p.get("eventType")
    which = _which(p)
    app = "Radarr" if which == "radarr" else "Sonarr"
    movie = which == "radarr"
    obj = p.get("movie") if movie else p.get("series")
    obj = obj or {}
    title = obj.get("title", "")
    year = str(obj["year"]) if obj.get("year") else ""
    poster = poster_url(obj)
    ep_sub, ep_title = ("", "") if movie else _episodes(p)
    sub = year if movie else (ep_sub or year)
    file = (p.get("movieFile") if movie else p.get("episodeFile")) or {}
    files = p.get("episodeFiles") or []
    release = p.get("release") or {}
    client = p.get("downloadClient") or ""
    base = dict(poster_url=poster)

    if ev == "Test":
        return _spec(which, "Test", "check-circle", "Test message", "", [], "The connection works.", icon="check-circle")

    if ev == "Grab":
        return _spec(which, "Grabbed", "download-simple", title, sub,
                     [("Episode", ep_title) if not movie else None, ("Quality", release.get("quality")),
                      ("Size", human_size(release.get("size"))), ("Indexer", release.get("indexer")), ("Client", client)],
                     release.get("releaseTitle") or "", **base)

    if ev == "Download":
        if p.get("isUpgrade"):
            old = (p.get("deletedFiles") or [{}])[0]
            score = (p.get("customFormatInfo") or {}).get("customFormatScore")
            return _spec(which, "Upgraded", "arrow-fat-lines-up", title, sub,
                         [("From", old.get("quality")), ("To", file.get("quality")), ("Size", human_size(file.get("size"))),
                          ("Score", ("%+d" % score) if isinstance(score, int) and score else None)],
                         release.get("releaseTitle") or file.get("sceneName") or file.get("path") or "", **base)
        return _spec(which, "Imported", "tray-arrow-down", title, sub,
                     [("Episode", ep_title) if not movie else None, ("Quality", file.get("quality")),
                      ("Size", human_size(file.get("size"))), ("Group", file.get("releaseGroup")) if movie else None],
                     file.get("path") or "", **base)

    if ev == "ImportComplete":
        size = sum(f.get("size") or 0 for f in files)
        return _spec(which, "Import complete", "checks", title, sub,
                     [("Episodes", "%d" % len(files) if files else ""), ("Quality", (files[0] if files else {}).get("quality")),
                      ("Size", human_size(size))], obj.get("path") or dirname((files[0] if files else {}).get("path")), **base)

    if ev == "Rename":
        renamed = (p.get("renamedMovieFiles") if movie else p.get("renamedEpisodeFiles")) or []
        first = renamed[0] if renamed else {}
        word = "Renamed" if len(renamed) < 2 else "Renamed · %d files" % len(renamed)
        spec = _spec(which, word, "textbox", title, year, [], "", **base)
        old, new = first.get("previousRelativePath"), first.get("relativePath")
        if old and new:
            spec["rename"] = (old.rsplit("/", 1)[-1], new.rsplit("/", 1)[-1])
        return spec

    if ev in ("MovieAdded", "SeriesAdd"):
        ids = " · ".join(x for x in ("TMDb %s" % obj["tmdbId"] if obj.get("tmdbId") else "",
                                      "TVDB %s" % obj["tvdbId"] if obj.get("tvdbId") else "",
                                      "IMDb %s" % obj["imdbId"] if obj.get("imdbId") else "") if x)
        return _spec(which, "Movie added" if movie else "Series added", "plus-circle", title, year,
                     [("Root", dirname(obj.get("folderPath") or obj.get("path"))), ("Added", p.get("addMethod")),
                      ("Type", obj.get("type") if not movie else None)], ids, **base)

    if ev in ("MovieDelete", "SeriesDelete"):
        gone = bool(p.get("deletedFiles"))
        return _spec(which, "Movie deleted" if movie else "Series deleted", "trash", title, year,
                     [("Deleted", "Files too" if gone else "Kept the files"), ("Freed", human_size(p.get("movieFolderSize")) if gone else None)],
                     obj.get("folderPath") or obj.get("path") or "", **base)

    if ev in ("MovieFileDelete", "EpisodeFileDelete"):
        reason = str(p.get("deleteReason") or "")
        if reason == "Upgrade":
            return _spec(which, "File removed for upgrade", "arrows-clockwise", title, sub,
                         [("Old", file.get("quality")), ("Size", human_size(file.get("size")))], file.get("path") or "", **base)
        return _spec(which, "Movie file deleted" if movie else "Episode file deleted", "file-x", title, sub,
                     [("Episode", ep_title) if not movie else None, ("Reason", REASONS.get(reason, camel_words(reason))),
                      ("Quality", file.get("quality") if movie else None), ("Size", human_size(file.get("size")) if movie else None)],
                     file.get("path") or "", **base)

    if ev in ("Health", "HealthRestored", "HealthIssue"):
        level = str(p.get("level") or "")
        check = camel_words(p.get("type")) or app
        if ev == "HealthRestored":
            return _spec(which, "Health restored", "heartbeat", check + " restored", "", [("Check", p.get("type"))],
                         p.get("message") or "", icon="heartbeat")
        warn = level.lower() == "warning"
        icon = "warning" if warn else "warning-octagon"
        message = p.get("message") or ""
        short = 0 < len(message) <= 42   # a short message is a better title than the name of the check
        return _spec(which, "Health warning" if warn else "Health issue", icon, message if short else check, "",
                     [("Level", level), ("Check", p.get("type"))], "" if short else message, icon=icon)

    if ev == "ApplicationUpdate":
        return _spec(which, "Application updated", "arrow-circle-up", "%s %s" % (app, p.get("newVersion") or ""),
                     "from %s" % p["previousVersion"] if p.get("previousVersion") else "", [], p.get("message") or "", icon="package")

    if ev == "ManualInteractionRequired":
        msgs = p.get("downloadStatusMessages") or []
        first = msgs[0] if msgs else {}
        return _spec(which, "Manual import needed", "hand-pointing", title, sub,
                     [("Reason", first.get("title")), ("Client", client), ("Size", human_size((p.get("downloadInfo") or {}).get("size")))],
                     " ".join(first.get("messages") or [])[:300], **base)
    return None


SEERR = {"MEDIA_APPROVED": ("Request approved", "check-circle"), "MEDIA_AUTO_APPROVED": ("Request auto-approved", "lightning")}


def _seerr(p):
    kind = str(p.get("notification_type") or "")
    if kind.startswith("TEST"):
        return _spec("seerr", "Test", "check-circle", "Test message", "", [], "The connection works.", icon="check-circle")
    if kind not in SEERR:
        return None
    event, icon = SEERR[kind]
    media = p.get("media") or {}
    request = p.get("request") or {}
    subject = str(p.get("subject") or "")
    m = re.match(r"^(.*?)\s*\((\d{4})\)$", subject)
    title, sub = (m.group(1), m.group(2)) if m else (subject, "")
    for extra in p.get("extra") or []:
        if "season" in str(extra.get("name", "")).lower() and extra.get("value"):
            value = str(extra["value"])
            sub = ("Season %s" if "," not in value else "Seasons %s") % value
    movie = media.get("media_type") == "movie"
    return _spec("seerr", event, icon, title, sub,
                 [("Requested by", request.get("requestedBy_username")), ("Type", "Movie" if movie else "Series"),
                  ("Status", "Sent to Radarr" if movie else "Sent to Sonarr")], "",
                 poster_url=p.get("image") if str(p.get("image") or "").startswith("http") else None)


# Helpers of this repo (the dedupe script, SABnzbd's notification script: files/hs-media-notify.py) send a payload that
# already says what to show: {"hsService", "event", "event_icon", "title", "sub", "fields": [[k, v]], "footer"}.
HS_SERVICES = ("maintainerr", "sabnzbd")


def _hs(p):
    service = p.get("hsService")
    if service not in HS_SERVICES:
        return None
    fields = [(str(f[0]), str(f[1])) for f in (p.get("fields") or []) if isinstance(f, (list, tuple)) and len(f) == 2]
    icon = str(p.get("event_icon") or "check-circle")
    poster = str(p.get("poster_url") or "")
    return _spec(service, str(p.get("event") or ""), icon, str(p.get("title") or ""), str(p.get("sub") or ""), fields,
                 str(p.get("footer") or ""), icon=icon, poster_url=poster if poster.startswith("http") else None)


SERVICE_NAMES = {"radarr": "Radarr", "sonarr": "Sonarr", "seerr": "Seerr", "maintainerr": "Maintainerr (Script)", "sabnzbd": "Downloadarr"}


def spec_for(p):
    """The card spec for a webhook payload, or None when the event is not posted."""
    if not isinstance(p, dict):
        return None
    spec = (_hs(p) if "hsService" in p else _seerr(p) if "notification_type" in p else (_arr(p) if p.get("eventType") else None))
    if spec is not None:
        spec["service_name"] = SERVICE_NAMES.get(spec["service"], "")
    return spec


ICONS = {"radarr": "🎬", "sonarr": "📺", "seerr": "🙋"}


def spec_text(spec):
    """The markdown text of a card: the room gets it when no card can be made, and it is the card's alt text."""
    head = "%s **%s** · %s" % (ICONS.get(spec["service"], ""), esc(spec.get("service_name") or ""), esc(spec.get("event") or ""))
    lines = [head.replace("  ", " ")]
    title = "**%s**" % esc(spec["title"]) if spec.get("title") else ""
    if spec.get("sub"):
        title += " · " + esc(spec["sub"])
    if title:
        lines.append(title)
    facts = " · ".join("%s: %s" % (esc(a), esc(b)) for a, b in spec.get("fields", []))
    if facts:
        lines.append(facts)
    if spec.get("rename"):
        lines.append("`%s` → `%s`" % spec["rename"])
    elif spec.get("footer"):
        lines.append("`%s`" % spec["footer"].replace("`", "'")[:200])
    return "\n".join(lines)
