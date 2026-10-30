#!/usr/bin/env python3
"""Web interface backend (machine.toml: webUi = true, hs-web.service). Runs on the HOST as root, never in Incus.

This file is the whole HTTP side of the entry page:
  GET  /api/hello     no login: what the sign-in page shows (storage locked?, realm, three status lines, accent)
  GET  /api/session   the signed-in user and the CSRF token, 401 without a session
  POST /api/login     {realm: "domain"|"local", user, password}; a session cookie comes back
  POST /api/unlock    {passphrase}: opens the encrypted storage (`hs sys unlock stdin`, passphrase on stdin only), only while locked; {status: ok|failed|busy, reason}
  POST /api/logout
  GET  /api/changes/seen   the revision this user has seen in What's new ({rev}, "" = never); session needed
  POST /api/changes/seen   {rev: 40 hex}: remember it for the signed-in user (web-changes-seen.json in the state folder); session + CSRF
  GET  /api/sys/...   a read-only `hs sys` call from the allowlist READS below (session needed), e.g. /api/sys/ct/list
  GET  /api/sys/jobs/stream/<unit>  the same job journal as `sys jobs tail`, as server-sent events (one JSON {rows} per look, `event: end` when the unit ended), session needed
  GET  /api/events    server-sent events `changed` ({topic, gen}) while live state is on (HS_WEB_LIVE=redis, else 404), `down`/`up` when Redis goes; session, same Origin
  GET  /api/board     the dashboard tiles and their stats, only while the dashboard variant is web; a session, or (setting dashboardOpen) a private address
  GET  /api/proxy/status  the VPS status document (machine.toml proxyStatusUrl, env HS_WEB_PROXY_URL; 404 while not configured), session needed
  GET  /api/docs/index|page/<lang>/<slug>|search?q=  the guides (capability docs; `hs docs build` writes them), session needed
  GET  /api/poster/<file>  a poster the web interface drew ($HS_STATE_DIR/posters, name checked), session needed
  GET  /theme.css     the colour tokens derived from machine.toml `webAccent`
  GET  /favicon.svg   the logo with that accent (the ring follows light/dark)
  GET  anything else  the built frontend (web/dist), index.html for unknown paths
Nothing else. Changes (plan/start) will go through the same session check and their own allowlist.

Who may sign in: members of Domain Admins (checked with winbind after ntlm_auth accepted the password), and the one local
account (default adminuser, checked with unix_chkpwd) which is the only way in while the storage is locked and dc1 is down.
Passwords travel on stdin of the helper, never in an argument list.

Protection: random session token in a HttpOnly SameSite=Strict cookie; every POST needs Content-Type application/json, an Origin
that equals the Host, and (after sign-in) the X-CSRF-Token of the session; failed logins are delayed and, after five in ten
minutes, refused for a growing time per client address and per user name. The page is plain HTTP on the home network and
Tailscale: there is NO Zoraxy rule for it (docs/PLAN-web-backend.md).

Usage: web-serve.py [port]      (default 8480). Settings come from the environment (see CONFIG below); every helper command can be replaced
(tests do that).
"""
import base64
import hashlib
import html
import http.server
import ipaddress
import json
import math
import mimetypes
import os
import queue
import re
import sqlite3
import secrets
import select
import shutil
import signal
import socket
import socketserver
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import web_terminal as wt      # the in-browser terminal (WebSocket, tickets, pty shell)
import live_state as ls        # live state: the RESP client for Redis (mode redis)

# ─────────────────────────── CONFIG ───────────────────────────
DEFAULT_ACCENT = "#9184d9"


def env(name, default):
    return os.environ.get(name, default)


def runtime_setting(key):
    """A runtime setting (config/schema.toml store = "settings": one file in /var/lib/hs/settings, scripts/lib/setting.sh), or None.
    It wins over the environment hs-web was started with, which Nix fills from machine.toml (the old place), so a change needs no restart."""
    d = env("HS_SETTINGS_DIR", os.path.join(env("HS_STATE_DIR", "/var/lib/hs"), "settings"))
    try:
        with open(os.path.join(d, key), encoding="utf-8") as f:
            return f.readline().strip()
    except OSError:
        return None


PRIVATE_NETS = [ipaddress.ip_network(n) for n in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "127.0.0.0/8", "::1/128", "fc00::/7", "fe80::/10")]


def private_client(ip):
    """True for an address of the home network, Tailscale or this machine (the open dashboard answers only these); False for anything unparsable."""
    ip = (ip or "").strip()
    if ip.lower().startswith("::ffff:"):
        ip = ip[7:]
    ip = ip.split("%", 1)[0]
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return any(addr in net for net in PRIVATE_NETS if net.version == addr.version)


def board_host_ok(host_header):
    """The Host header of a request without a session must name this server: an IP literal, the host name, <host>.local, a name below the
    gateway's local domain (<site>.<realm>, scripts/lib/localdomain.sh) or <host>.<tailnet>.ts.net. A foreign name (DNS rebinding) is refused."""
    h = (host_header or "").strip().lower()
    if h.startswith("["):
        h = h[1:].split("]", 1)[0]
    elif h.count(":") == 1:
        h = h.split(":", 1)[0]
    if not h:
        return False
    try:
        ipaddress.ip_address(h)
        return True
    except ValueError:
        pass
    h = h.rstrip(".")
    names = {socket.gethostname().lower()}
    name = runtime_setting("hostName") or env("HS_WEB_HOSTNAME", "")
    if name:
        names.add(name.lower())
    if h in names or any(h == n + ".local" for n in names):
        return True
    if h.endswith(".ts.net") and h.split(".", 1)[0] in names:
        return True
    dom = local_domain()
    return bool(dom) and (h == dom or h.endswith("." + dom))


def local_domain():
    """<siteName>.<realm> of the gateway (same as scripts/lib/localdomain.sh), or ''."""
    import tomllib
    try:
        with open(env("HS_MACHINE_FILE", "/etc/nixos/machine.toml"), "rb") as f:
            realm = str((tomllib.load(f).get("adDomain") or {}).get("realm", "")).strip().lower()
        with open(env("HS_SITE_NAME_FILE", "/etc/hs/site-name"), encoding="utf-8") as f:
            site = f.read().strip().lower()
    except (OSError, ValueError):
        return ""
    return "%s.%s" % (site, realm) if realm and re.fullmatch(r"[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?", site) else ""


def capabilities():
    """The capabilities that are on, by the rules of scripts/lib/capability.sh: named in /etc/hs/capabilities (Nix), or implied by a
    runtime setting (scripts/lib/capabilities.tsv, made from capabilities/*/capability.toml). The environment Nix fills from an old
    machine.toml still counts for vpsHost and proxyStatusUrl until `hs config migrate-settings` has moved them."""
    legacy = {"vpsHost": "HS_WEB_VPS_HOST", "proxyStatusUrl": "HS_WEB_PROXY_URL"}
    on = set()
    state = env("HS_STATE_DIR", "/var/lib/hs")
    try:
        with open(env("HS_CAPABILITIES_FILE", "/etc/hs/capabilities"), encoding="utf-8") as f:
            on = {line.strip() for line in f if line.strip()}
    except OSError:
        pass
    try:           # `hs ext enable <package>` for a package without a Nix module: on at once (scripts/lib/capability.sh)
        with open(os.path.join(state, "capabilities-on"), encoding="utf-8") as f:
            on |= {line.strip() for line in f if line.strip()}
    except OSError:
        pass
    tsv = env("HS_CAPABILITIES_TSV", os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib", "capabilities.tsv"))
    try:
        with open(tsv, encoding="utf-8") as f:
            for line in f:
                if line.startswith("#") or not line.strip():
                    continue
                cols = line.rstrip("\n").split("\t")
                for key in (cols[1].split(",") if len(cols) > 1 else []):
                    v = runtime_setting(key)
                    if v is None and key in legacy:
                        v = env(legacy[key], "")
                    if (v or "") not in ("", "false", "0"):
                        on.add(cols[0])
    except OSError:
        pass
    try:           # `hs ext disable <package>` wins over everything above
        with open(os.path.join(state, "capabilities-off"), encoding="utf-8") as f:
            on -= {line.strip() for line in f if line.strip()}
    except OSError:
        pass
    return sorted(on)



# ── The guides (capability docs): Markdown pages that `hs docs build` writes to <state>/docs-site; the frontend renders them ──
DOCS_LANG = re.compile(r"^(de|en)$")
DOCS_SLUG = re.compile(r"^[a-z0-9][a-z0-9-]{0,100}$")


def docs_root():
    return env("HS_DOCS_OUT", os.path.join(env("HS_STATE_DIR", "/var/lib/hs"), "docs-site"))


def docs_read(rel):
    """the bytes of one file under the docs folder, or None (the name is checked by the callers; the real path must stay inside)"""
    root = os.path.realpath(docs_root())
    full = os.path.realpath(os.path.join(root, rel))
    if not (full.startswith(root + os.sep) and os.path.isfile(full)):
        return None
    try:
        with open(full, "rb") as f:
            return f.read()
    except OSError:
        return None


def docs_search(query, lang=""):
    """Find `query` (case-insensitive, 2 to 80 characters) in the pages: [{lang, slug, title, heading, anchor, snippet}], best first.
    A hit in a title counts most, then one in a heading, then one in the text; at most one result per page and heading."""
    q = (query or "").strip().lower()
    if not 2 <= len(q) <= 80:
        return []
    raw = docs_read("index.json")
    try:
        index = json.loads(raw) if raw else {}
    except ValueError:
        return []
    hits = []
    for lg, info in (index.get("langs") or {}).items():
        if lang and lg != lang:
            continue
        for group in info.get("groups", []):
            for page in group.get("pages", []):
                slug = page.get("slug", "")
                if not DOCS_SLUG.match(slug):
                    continue
                data = docs_read(f"{lg}/{slug}.md")
                if not data:
                    continue
                title = page.get("title", slug)
                score = 10 if q in title.lower() else 0
                heading, anchor, seen, best = "", "", set(), None
                in_code = False
                for line in data.decode("utf-8", "replace").splitlines():
                    if line.lstrip().startswith(("```", "~~~")):
                        in_code = not in_code
                    m = None if in_code else re.match(r"^(#{1,6})\s+(.*?)\s*#*$", line)
                    if m:
                        heading = re.sub(r"[`*_]", "", m.group(2))
                        anchor = re.sub(r"\s", "-", re.sub(r"[^\w\s-]", "", heading.lower(), flags=re.UNICODE).strip())
                        if q in heading.lower():
                            score += 5
                            if best is None or best[0] < 5:
                                best = (5, heading, anchor, heading)
                        continue
                    i = line.lower().find(q)
                    if i >= 0:
                        score += 1
                        if best is None or best[0] < 1:
                            a = max(0, i - 50)
                            cut = re.sub(r"^\s*(?:[-*+]\s+(?:\[[ xX]\]\s+)?|>\s*)", "", line[a:i + len(q) + 80]).strip()
                            best = (1, heading, anchor, ("…" if a else "") + re.sub(r"[*`]", "", cut.replace("\\|", "|")) + ("…" if len(line) > i + len(q) + 80 else ""))
                if score:
                    hits.append((score, lg, slug, title, best))
    hits.sort(key=lambda h: (-h[0], h[1] != "de", h[3].lower()))
    out = []
    for score, lg, slug, title, best in hits[:25]:
        _, heading, anchor, snippet = best if best else (0, "", "", "")
        out.append({"lang": lg, "slug": slug, "title": title, "heading": heading, "anchor": anchor, "snippet": snippet})
    return out


def features(cfg):
    """what the server switched on, for the session answer"""
    return {"terminal": cfg.terminal, "vps": cfg.vps, "capabilities": capabilities(), "extensions": ext_pages(), "host": socket.gethostname(), "language": runtime_setting("language") or "", "dashboard": runtime_setting("dashboard") or "", "live": cfg.live == "redis"}   # host: the local node's name = the first part of every address (/node/<host>/...)


def _runtime(fn):
    """A Config attribute that is looked up in the runtime settings each time it is read; assigning to it (tests) fixes a value."""
    name = fn.__name__

    def get(self):
        ov = self.__dict__.get("_ov", {})
        return ov[name] if name in ov else fn(self)

    def put(self, value):
        self.__dict__.setdefault("_ov", {})[name] = value
    return property(get, put)


class Config:
    @_runtime
    def accent(self):                       # main colour (webAccent)
        return runtime_setting("webAccent") or env("HS_WEB_ACCENT", DEFAULT_ACCENT)

    @_runtime
    def proxy_url(self):                    # the VPS status document (proxyStatusUrl); set by the operator only, never from a request
        v = runtime_setting("proxyStatusUrl")
        return v if v is not None else env("HS_WEB_PROXY_URL", "")

    @_runtime
    def terminal(self):                     # the browser terminal (webTerminal): the shell runs as local_user, never as root
        v = runtime_setting("webTerminal")
        return (v == "true") if v is not None else env("HS_WEB_TERMINAL", "") == "1"

    @_runtime
    def vps(self):                          # the buttons vps update / vps watch (vpsHost); the page only needs to know whether they are on
        v = runtime_setting("vpsHost")
        return bool(v if v is not None else env("HS_WEB_VPS_HOST", ""))

    @_runtime
    def term_idle(self):                    # webTerminalIdleMinutes
        return float(runtime_setting("webTerminalIdleMinutes") or env("HS_WEB_TERM_IDLE_MINUTES", "30")) * 60

    @_runtime
    def term_max(self):                     # webTerminalMaxHours
        return float(runtime_setting("webTerminalMaxHours") or env("HS_WEB_TERM_MAX_HOURS", "8")) * 3600

    def __init__(self):
        self.port = int(env("HS_WEB_PORT", "8480"))
        self.bind = env("HS_WEB_BIND", "")
        self.root = env("HS_WEB_ROOT", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "web", "dist"))
        self.workgroup = env("HS_WEB_WORKGROUP", "")                 # "HOME"; empty = no domain, local account only
        self.realm = env("HS_WEB_REALM", "")                         # "ad.home.lan", only shown
        self.admin_group = env("HS_WEB_ADMIN_GROUP", "Domain Admins")
        self.local_user = env("HS_WEB_LOCAL_USER", "adminuser")
        self.locked_marker = env("HS_LOCKED_MARKER", "/run/hs/storage-locked")
        self.ntlm_auth = env("HS_WEB_NTLM_AUTH", "ntlm_auth")
        self.wbinfo = env("HS_WEB_WBINFO", "wbinfo")
        self.chkpwd = env("HS_WEB_CHKPWD", "/run/wrappers/bin/unix_chkpwd")
        self.hs = env("HS_WEB_HS", "hs")
        self.idle = int(env("HS_WEB_IDLE_MINUTES", "480")) * 60
        self.max_age = int(env("HS_WEB_MAX_HOURS", "12")) * 3600
        self.fail_delay = float(env("HS_WEB_FAIL_DELAY", "1.0"))     # seconds every failed login waits (tests set 0)
        self.facts_ttl = int(env("HS_WEB_FACTS_TTL", "20"))
        self.changes_seen_file = env("HS_WEB_CHANGES_SEEN_FILE", os.path.join(env("HS_STATE_DIR", "/var/lib/hs"), "web-changes-seen.json"))   # {user: last revision seen in What's new}; "" = memory only
        self.session_file = env("HS_WEB_SESSION_FILE", "/run/hs-web/sessions.json")   # hashes only; "" = sessions stay in memory; the directory is made by systemd (RuntimeDirectory), never here
        self.stale_factor = float(env("HS_WEB_STALE_FACTOR", "40"))   # a cached read may be served up to ttl*factor (and stale_max s) old while it is refreshed in the background
        self.stale_max = float(env("HS_WEB_STALE_MAX", "1800"))      # up to half an hour old is shown at once (X-HS-Age says how old) while a fresh answer is read
        self.plan_ttl = float(env("HS_WEB_PLAN_TTL", "5"))   # a finished plan is answered again for this many seconds (same area and args); 0 = off
        self.cache_file = env("HS_WEB_CACHE_FILE", "/run/hs-web/cache.json")   # the answers survive a restart of this service (tmpfs: not a reboot); "" = memory only
        self.warm_all = env("HS_WEB_WARM_ALL", "1") == "1"            # keep every read without arguments warm (see Warmer), not only the common ones
        self.warm_idle_ttl = float(env("HS_WEB_WARM_IDLE_TTL", "120")) # such a read that nobody has asked for is read again at most this often
        self.collected_max_age = float(env("HS_WEB_COLLECTED_MAX_AGE", "180"))   # a read the collector keeps (state database) is served from there while its output is at most this old
        self.seen_for = float(env("HS_WEB_SEEN_FOR", "1800"))         # a read somebody asked for stays in the warm-up for this many seconds
        self.warm_active = float(env("HS_WEB_WARM_ACTIVE", "300"))    # the warm-up runs while a session was seen within this many seconds
        self.warm_pause = float(env("HS_WEB_WARM_PAUSE", "0.2"))
        # behind `tailscale serve` (machine.toml: webTailscale): HTTPS comes from Tailscale, the page listens on loopback only, the proxy names the real client
        self.secure = env("HS_WEB_SECURE", "") == "1"
        self.trust_proxy = env("HS_WEB_TRUST_PROXY", "") == "1"
        self.proxy_ttl = float(env("HS_WEB_PROXY_TTL", "8"))
        self.proxy_timeout = float(env("HS_WEB_PROXY_TIMEOUT", "5"))
        # the browser terminal (machine.toml: webTerminal, default false): the shell runs as local_user, never as root
        self.unlock_in_unit = env("HS_WEB_UNLOCK_IN_UNIT", "") == "1"    # the unlock runs in its own systemd unit (set by configuration.nix, tests leave it off)
        # the buttons vps update / vps watch (machine.toml: vpsHost); the page only needs to know whether they are on, the host itself stays here
        self.term_check = float(env("HS_WEB_TERM_CHECK", "3"))
        # the Tasks tab follows a job as a server-sent-events stream (GET /api/sys/jobs/stream/<unit>)
        self.stream_every = float(env("HS_WEB_STREAM_EVERY", "1"))        # seconds between two looks at the journal
        self.stream_max = int(env("HS_WEB_STREAM_MAX", "6"))              # streams open at once (one thread each)
        self.stream_hours = float(env("HS_WEB_STREAM_HOURS", "6"))        # a stream ends after this long; the page reconnects or falls back
        # live state (capability live-state): "redis" serves topic reads from Redis and pushes changes on /api/events; anything else = off
        self.live = env("HS_WEB_LIVE", "")
        self.live_socket = env("HS_LIVE_SOCKET", "/run/redis-hobnix/redis.sock")
        self.events_ping = 15.0                                           # seconds of silence before a `: ping` on /api/events (tests shorten it)
        self.events_max = int(env("HS_WEB_EVENTS_MAX", "32"))             # /api/events streams open at once


# ─────────────────────────── colours ───────────────────────────
# Nocturne's accent ramp, converted once to OKLCH. A different accent keeps the lightness steps and the relative chroma of
# this ramp and takes its own hue, so every accent gets the same family of tints (text on dark ground, tag grounds, bars).
REF_ACCENT = DEFAULT_ACCENT
REF_RAMP = {100: "#f5f4ff", 200: "#e7e5fe", 300: "#d2cefd", 400: "#b5abfc", 500: "#968ae0",
            600: "#796cbf", 700: "#5d5294", 800: "#423a6a", 900: "#2b2741"}
REF_SECTION = {"section": "#262a60", "section-glow": "#353b80", "section-ghost": "#4c5397"}
HEX_RE = re.compile(r"^#[0-9a-fA-F]{6}$")


def _lin(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _gam(c):
    return 12.92 * c if c <= 0.0031308 else 1.055 * (c ** (1 / 2.4)) - 0.055


def hex_to_oklch(h):
    r, g, b = (_lin(int(h[i:i + 2], 16) / 255) for i in (1, 3, 5))
    l = math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    m = math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    s = math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
    L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
    a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
    bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    return L, math.hypot(a, bb), math.degrees(math.atan2(bb, a)) % 360


def oklch_to_rgb(L, C, H):
    a, b = C * math.cos(math.radians(H)), C * math.sin(math.radians(H))
    l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3
    m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3
    s = (L - 0.0894841775 * a - 1.2914855480 * b) ** 3
    return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)


def oklch_to_hex(L, C, H):
    # Too saturated for sRGB: take chroma away until it fits (keeps lightness and hue).
    for _ in range(40):
        rgb = oklch_to_rgb(L, C, H)
        if all(-0.0005 <= v <= 1.0005 for v in rgb):
            break
        C *= 0.95
    return "#" + "".join("%02x" % round(min(1, max(0, _gam(min(1, max(0, v))))) * 255) for v in rgb)


def valid_accent(value):
    return bool(HEX_RE.fullmatch(value or ""))


def theme_tokens(accent):
    """The custom properties that depend on the accent. The default accent returns the design's own values untouched."""
    if not valid_accent(accent) or accent.lower() == REF_ACCENT:
        accent = REF_ACCENT
        tokens = {"--color-accent": accent}
        tokens.update({"--color-accent-%d" % k: v for k, v in REF_RAMP.items()})
        tokens.update({"--color-" + k: v for k, v in REF_SECTION.items()})
        return tokens
    _, c_ref, h_ref = hex_to_oklch(REF_ACCENT)
    _, c_user, h_user = hex_to_oklch(accent.lower())
    k = c_user / c_ref if c_ref else 1.0

    def derive(ref_hex):
        L, C, H = hex_to_oklch(ref_hex)
        return oklch_to_hex(L, C * k, (H - h_ref + h_user) % 360)

    tokens = {"--color-accent": accent.lower()}
    tokens.update({"--color-accent-%d" % n: derive(v) for n, v in REF_RAMP.items()})
    tokens.update({"--color-" + n: derive(v) for n, v in REF_SECTION.items()})
    return tokens


def theme_css(accent):
    body = "".join("  %s: %s;\n" % kv for kv in theme_tokens(accent).items())
    return ":root {\n%s}\n" % body


def favicon_svg(accent):
    """the mark (web/src/ui/Logo.svelte, .github/branding/logo-auto.svg) with the accent of this server; the ring follows the browser's light/dark"""
    accent = accent.lower() if re.fullmatch(r"#[0-9a-fA-F]{6}", accent or "") else "#9184d9"
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="64" height="64">'
            '<style>.r{stroke:#17161d}@media (prefers-color-scheme:dark){.r{stroke:#f1f0f6}}</style>'
            '<circle class="r" cx="50" cy="50" r="38" fill="none" stroke-width="6"/>'
            '<path d="M36.5 33.5 L63.5 66.5 M50 50 L36.5 66.5" fill="none" stroke="%s" stroke-width="7"/></svg>' % accent)


# ─────────────────────────── sign-in checks ───────────────────────────
USER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")


def _run(cmd, stdin=None, timeout=10):
    try:
        p = subprocess.run(cmd, input=stdin, capture_output=True, timeout=timeout)
        return p.returncode, p.stdout.decode("utf-8", "replace")
    except (OSError, subprocess.SubprocessError):
        return 127, ""


_run_plain = _run      # tests replace _run with a fake; while they do, plans go through that fake and the plan cache is off (see _change)


def _client_gone(sock):
    """True when the browser closed the connection (it aborted the request): readable and a peek reads nothing. poll, not select: select
    raises for a descriptor above 1024; an error we cannot read is "not gone" (the plan runs to its end)."""
    try:
        if hasattr(select, "poll"):
            po = select.poll()
            po.register(sock, select.POLLIN)
            readable = bool(po.poll(0))
        else:
            readable = bool(select.select([sock], [], [], 0)[0])
        return readable and sock.recv(1, socket.MSG_PEEK) == b""
    except BlockingIOError:
        return False
    except (OSError, ValueError):
        return False


def _kill_tree(p):
    """End a plan and everything it started (its own session = process group): TERM, up to 2 s for the leader, then KILL to the whole group
    even when the leader is gone (a child may ignore TERM). Never waits forever."""
    kill = getattr(signal, "SIGKILL", signal.SIGTERM)
    for sig in (signal.SIGTERM, kill):
        try:
            if hasattr(os, "killpg"):
                os.killpg(p.pid, sig)
            else:
                p.kill()
        except OSError:
            pass            # ProcessLookupError: the group is gone already
        if sig == kill:
            break
        try:
            p.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
    try:
        p.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass
    for f in (p.stdin, p.stdout):
        try:
            if f:
                f.close()
        except OSError:
            pass


def _run_watched(cmd, stdin=None, timeout=60, gone=None):
    """-> (rc, stdout, how), how = "run" | "timeout" | "gone". Like _run, but polls every 0.2 s and kills the process group when the client
    went away (gone() is True) or the timeout passed. Only for plans: a plan changes nothing, so stopping it is safe. Never for start."""
    try:
        p = subprocess.Popen(cmd, stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, start_new_session=hasattr(os, "killpg"))
    except (OSError, ValueError):
        return 127, "", "run"
    end, data = time.monotonic() + timeout, stdin
    while True:
        try:
            out, _ = p.communicate(input=data, timeout=0.2)
            return p.returncode, out.decode("utf-8", "replace"), "run"
        except subprocess.TimeoutExpired:
            data = None            # communicate() keeps sending the first input; passing it again raises
            how = "gone" if gone is not None and gone() else "timeout" if time.monotonic() > end else None
            if how:
                _kill_tree(p)
                return 127, "", how


class Auth:
    """The three questions a sign-in asks. Tests replace this class' methods."""

    def __init__(self, cfg):
        self.cfg = cfg

    def storage_locked(self):
        return os.path.exists(self.cfg.locked_marker)

    def domain_password_ok(self, user, password):
        """True = accepted, False = refused, None = the helper could not decide (winbind or the domain controller is in trouble).
        squid-2.5-basic helper: one line "<user> <password>", both URL-escaped, answer "OK", "ERR" (wrong) or "BH <message>" (helper error)."""
        # The helper hands the name to winbind as it is, and winbind only knows names with the domain in front (WORKGROUP, a backslash, the user):
        # a bare "anna" is refused (checked on the server). Both fields are URL-unescaped by the helper in this mode (ntlm_auth.c, SQUID_2_5_BASIC),
        # so the user and the password are escaped, the separator is not.
        line = "%s%s%s %s" % (self.cfg.workgroup, chr(92), urllib.parse.quote(user, safe=""), urllib.parse.quote(password, safe=""))
        try:
            p = subprocess.run([self.cfg.ntlm_auth, "--helper-protocol=squid-2.5-basic", "--domain=" + self.cfg.workgroup],
                               input=(line + chr(10)).encode(), capture_output=True, timeout=15)
            rc, out, err = p.returncode, p.stdout.decode("utf-8", "replace").strip(), p.stderr.decode("utf-8", "replace").strip()
        except (OSError, subprocess.SubprocessError) as e:
            print("web login: ntlm_auth could not run: %s" % e.__class__.__name__, flush=True)
            return None
        if out.startswith("OK"):
            return True
        if out.startswith("ERR"):
            return False
        # anything else is the helper failing, not the person typing a wrong password: say what it said (the line it got is not in the log)
        print("web login: ntlm_auth did not decide: rc=%s out=%r err=%r" % (rc, out[:120], err[:200]), flush=True)
        return None

    def domain_is_admin(self, user):
        wg = self.cfg.workgroup
        rc, out = _run([self.cfg.wbinfo, "--group-info", "%s\\%s" % (wg, self.cfg.admin_group)])
        parts = out.strip().split(":")
        if rc != 0 or len(parts) < 3 or not parts[2].isdigit():
            return False
        rc, out = _run([self.cfg.wbinfo, "-r", "%s\\%s" % (wg, user)])
        return rc == 0 and parts[2] in out.split()

    def local_password_ok(self, user, password):
        # unix_chkpwd reads the password (NUL terminated) from stdin; as root it may check any account. Empty passwords never pass.
        if not password:
            return False
        rc, _ = _run([self.cfg.chkpwd, user, "nonull"], stdin=password.encode() + b"\0")
        return rc == 0


# ─────────────────────────── state: sessions, throttle, facts ───────────────────────────
def _h(token):
    return hashlib.sha256(token.encode()).hexdigest()


def csrf_for(token):
    """The CSRF token is derived from the cookie token, so a session restored from its hash can hand the same one out again."""
    return base64.urlsafe_b64encode(hashlib.sha256(b"csrf:" + token.encode()).digest()[:24]).decode().rstrip("=")


class Sessions:
    """Sessions live in memory; with cfg.session_file they are also written (only sha256 of the cookie token, user, realm, times) so that a
    restart of hs-web does not sign everybody out. The CSRF token is derived from the cookie token (csrf_for), so nothing secret is stored."""

    def __init__(self, cfg):
        self.cfg, self.lock, self.items, self.restored, self.saved_at = cfg, threading.Lock(), {}, {}, 0.0
        self._load()

    def _load(self):
        path = self.cfg.session_file
        if not path:
            return
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
            for h, r in data.items():
                if re.fullmatch(r"[0-9a-f]{64}", h) and isinstance(r, dict) and all(k in r for k in ("user", "realm", "created", "seen")):
                    self.restored[h] = {k: r[k] for k in ("user", "realm", "created", "seen", "ip") if k in r}
        except (OSError, ValueError, AttributeError):
            pass

    def _save(self):
        """Caller holds the lock. Never raises; a write that fails leaves the old file."""
        path = self.cfg.session_file
        if not path or not os.path.isdir(os.path.dirname(path)):
            return
        now = self.saved_at = time.time()
        data = dict(self.restored)
        for t, s in self.items.items():
            data[_h(t)] = {k: s.get(k) for k in ("user", "realm", "created", "seen", "ip")}
        data = {h: r for h, r in data.items() if now - r["seen"] <= self.cfg.idle and now - r["created"] <= self.cfg.max_age}
        tmp = path + ".tmp"
        try:
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(data, f)
            os.replace(tmp, path)
        except OSError:
            pass

    def create(self, user, realm, ip):
        token, now = secrets.token_urlsafe(32), time.time()
        with self.lock:
            self.items[token] = {"user": user, "realm": realm, "csrf": csrf_for(token), "created": now, "seen": now, "ip": ip}
            self._save()
        return token

    def _find(self, token):
        """Caller holds the lock. The session record; a restored one becomes a live one when its cookie shows up."""
        s = self.items.get(token)
        if s is None and self.restored:
            r = self.restored.pop(_h(token), None)
            if r is not None:
                s = self.items[token] = dict(r, csrf=csrf_for(token), ip=r.get("ip", ""))
        return s

    def get(self, token, locked):
        if not token:
            return None
        with self.lock:
            s, now = self._find(token), time.time()
            if s is None:
                return None
            # dc1 is down while the storage is locked: a domain session cannot be trusted any more
            if now - s["seen"] > self.cfg.idle or now - s["created"] > self.cfg.max_age or (locked and s["realm"] == "domain"):
                del self.items[token]
                self._save()
                return None
            s["seen"] = now
            if now - self.saved_at > 60:
                self._save()
            return s

    def drop(self, token):
        with self.lock:
            self.items.pop(token, None)
            self.restored.pop(_h(token), None)
            self._save()

    def last_seen(self):
        with self.lock:
            seen = [s["seen"] for s in self.items.values()] + [r["seen"] for r in self.restored.values()]
        return max(seen) if seen else 0.0


class Throttle:
    """Five failures in ten minutes lock a key (client address, or user name) for 30 s, doubling each further failure, up to 15 minutes."""

    def __init__(self):
        self.lock, self.fails = threading.Lock(), {}

    def wait(self, *keys):
        now, longest = time.time(), 0
        with self.lock:
            for k in keys:
                e = self.fails.get(k)
                if e and e["until"] > now:
                    longest = max(longest, e["until"] - now)
        return math.ceil(longest)

    def failed(self, *keys):
        now = time.time()
        with self.lock:
            for k in keys:
                e = self.fails.setdefault(k, {"times": [], "until": 0})
                e["times"] = [t for t in e["times"] if now - t < 600] + [now]
                over = len(e["times"]) - 4
                if over > 0:
                    e["until"] = now + min(900, 30 * 2 ** (over - 1))

    def ok(self, *keys):
        with self.lock:
            for k in keys:
                self.fails.pop(k, None)


class Facts:
    """The three lines next to the sign-in form, from `hs sys status` (cached: anyone on the network can ask for them)."""

    def __init__(self, cfg):
        self.cfg, self.lock, self.at, self.value = cfg, threading.Lock(), 0, []

    def get(self, locked):
        with self.lock:
            if time.time() - self.at < self.cfg.facts_ttl and self.value:
                return self.value
            self.value = self._read(locked)
            self.at = time.time()
            return self.value

    def _stored(self):
        """-> (rc, out) of the `status` topic in mode redis; None when the key or Redis is not there (then the command runs)."""
        try:
            r = ls.Resp(self.cfg.live_socket, timeout=1.0)
            try:
                raw = r.cmd("GET", ls.KEY % "status")
            finally:
                r.close()
            doc = json.loads(raw) if raw else None
            if isinstance(doc, dict) and doc.get("out"):
                return int(doc.get("rc") or 0), str(doc["out"])
        except (OSError, ValueError, TypeError):
            pass
        return None

    def _read(self, locked):
        got = self._stored() if self.cfg.live == "redis" else None
        rc, out = got if got else _run([self.cfg.hs, "sys", "status"], timeout=15)
        rows = {}
        for line in out.splitlines():
            f = line.split("\t")
            if f and f[0] not in rows:
                rows[f[0]] = f[1:]
        ok, warn = "ok", "warn"
        facts = []
        if locked:
            facts.append({"dot": warn, "text": "Storage is locked, nothing runs until it is unlocked"})
        else:
            run = rows.get("instances", [])
            if len(run) >= 2:
                lead = "Encryption open · " if rows.get("encryption", [""])[0] == "open" else ""
                facts.append({"dot": ok, "text": "%s%s of %s instances running" % (lead, run[0], run[1])})
        b = rows.get("backup", [])
        if b and b[0] == "ok" and len(b) > 1 and b[1].isdigit():
            h = int(b[1]) // 3600
            facts.append({"dot": ok, "text": "Last backup %s" % ("less than an hour ago" if h < 1 else "%d hours ago" % h if h < 48 else "%d days ago" % (h // 24))})
        elif b and b[0] in ("failed",):
            facts.append({"dot": warn, "text": "The last backup failed"})
        sm = rows.get("smart", [])
        if len(sm) > 1 and sm[1].strip():
            facts.append({"dot": warn, "text": "Disks to look at: %s" % sm[1]})
        if rc != 0 and not facts:
            facts.append({"dot": "off", "text": "Status is not available right now"})
        return facts[:3]


# ─────────────────────────── reads: the allowlist ───────────────────────────
# Every read the pages may ask for is listed here, by the words after `hs sys`. Nothing else is ever run: not a path from the request
# beyond these words, no shell, arguments go in as a list and must match their pattern. tests/web-login-test.py checks that each entry is
# a row of scripts/lib/registry.tsv, so a renamed command cannot silently break a page.
#   kind   tsv  = rows of tab separated fields -> {"rows": [[...]]};  json = the command prints one JSON document;  text = {"text": ...}
#   ttl    seconds the answer is reused (slow reads, many viewers)
#   args   one pattern per required path segment after the words (a container name, a share, ...)
#   query  optional parameters: query name -> (pattern, how it is passed: "--flag" or "" for a positional)
NAME = r"^[A-Za-z0-9][A-Za-z0-9._:@-]{0,63}$"
UNIT = r"^hs-[A-Za-z0-9@._-]{1,80}$"
GROUP = r"^[A-Za-z0-9][A-Za-z0-9._ -]{0,63}$"     # group names may hold spaces (Domain Admins); the path segment is unquoted first
FM_LOC = r"^(disk:data-[0-9]{1,3}|pool:(bulk|fast)|cache:bulk|share:[a-z0-9][a-z0-9-]{0,40}|temp:[a-z0-9][a-z0-9-]{0,31})$"     # a place of the file manager
READS = {
    ("status",):{"kind": "tsv", "ttl": 10, "topic": "status"},      # topic: the live-state key (read only in mode redis)
    ("deck",): {"kind": "json", "ttl": 8},
    ("ups", "status"): {"kind": "tsv", "ttl": 15},
    ("monitor", "disks"): {"kind": "tsv", "ttl": 15},
    ("pool", "info"): {"kind": "tsv", "ttl": 15, "query": {"pool": (NAME, "")}},
    ("pool", "members"): {"kind": "tsv", "ttl": 15, "query": {"pool": (NAME, "")}},
    ("pool", "state"): {"kind": "tsv", "ttl": 10, "query": {"pool": (NAME, "")}},     # bulk lock, health-check pause, last scrub / parity sync (lock, paused, scrub <pool>, sync bulk)
    ("pool", "disks"): {"kind": "tsv", "ttl": 15, "query": {"role": (r"^adopt$", "--role")}},
    ("disk-health", "list"): {"kind": "tsv", "ttl": 30},
    ("state", "disks"): {"kind": "tsv", "ttl": 15},
    ("reads", "status"): {"kind": "tsv", "ttl": 5},      # the Data page: what the collector keeps, how old, how long each read takes
    ("state", "events"): {"kind": "tsv", "ttl": 10, "query": {"n": (r"^[0-9]{1,4}$", "")}},
    ("ct", "list"): {"kind": "tsv", "ttl": 5},
    ("ct", "profiles"): {"kind": "tsv", "ttl": 30},
    ("ct", "bindings"): {"kind": "tsv", "ttl": 10, "args": [NAME]},
    ("ct", "snapshots"): {"kind": "tsv", "ttl": 10, "args": [NAME]},
    ("jobs", "list"): {"kind": "tsv", "ttl": 10},
    ("jobs", "running"): {"kind": "tsv", "ttl": 3},
    ("jobs", "tail"): {"kind": "tsv", "ttl": 0, "args": [UNIT], "query": {"from": (r"^[0-9]{1,7}$", "")}},
    ("system", "updates"): {"kind": "tsv", "ttl": 30},
    ("ssh-key", "list"): {"kind": "tsv", "ttl": 30},
    ("node", "list"): {"kind": "tsv", "ttl": 15},
    ("node", "show"): {"kind": "tsv", "ttl": 15, "args": [NAME]},
    ("changes", "list"): {"kind": "tsv", "ttl": 60, "query": {"from": (r"^[0-9a-f]{7,40}$", "--from"), "since": (r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$", "--since")}},   # What's new
    ("parts", "list"): {"kind": "tsv", "ttl": 15},                          # the optional parts and whether each is on (Settings)
    ("node", "keyline"): {"kind": "tsv", "ttl": 5, "args": [NAME]},       # the public key line a node's owner has to allow (never the private key)
    ("node", "status"): {"kind": "json", "ttl": 10, "args": [NAME]},    # a remote node over ssh, the word status only
    ("logs", "units"): {"kind": "tsv", "ttl": 300},
    ("logs", "show"): {"kind": "text", "ttl": 5, "query": {
        "unit": (r"^[a-z0-9-]{1,32}$", "--unit"), "level": (r"^(err|warning|info)$", "--level"),
        "since": (r"^(1h|today|boot)$", "--since"), "lines": (r"^[0-9]{1,4}$", "--lines")}},
    ("health", "next"): {"kind": "tsv", "ttl": 15},
    ("health", "list"): {"kind": "tsv", "ttl": 15},
    ("backup", "state"): {"kind": "tsv", "ttl": 15},
    ("backup", "overview"): {"kind": "tsv", "ttl": 30},
    ("backup", "shares"): {"kind": "tsv", "ttl": 30},
    ("shares", "overview"): {"kind": "tsv", "ttl": 30},
    ("shares", "list"): {"kind": "tsv", "ttl": 30},
    ("shares", "acl"): {"kind": "tsv", "ttl": 30, "args": [NAME]},
    ("shares", "visible"): {"kind": "tsv", "ttl": 30, "args": [NAME]},
    ("shares", "mounts"): {"kind": "tsv", "ttl": 30, "args": [NAME]},
    ("shares", "history"): {"kind": "tsv", "ttl": 30, "args": [NAME]},
    ("users", "list"): {"kind": "tsv", "ttl": 30},
    ("users", "groups"): {"kind": "tsv", "ttl": 30},
    ("vault", "list"): {"kind": "tsv", "ttl": 60},
    ("remote", "list"): {"kind": "tsv", "ttl": 30},
    ("unifi", "networks"): {"kind": "tsv", "ttl": 60},
    ("unifi", "clients"): {"kind": "tsv", "ttl": 30},
    ("ports", "list"): {"kind": "tsv", "ttl": 60},
    ("dns", "list"): {"kind": "tsv", "ttl": 60},
    ("cache", "state"): {"kind": "tsv", "ttl": 15},
    ("system", "config"): {"kind": "text", "ttl": 60},
    ("disk", "results"): {"kind": "tsv", "ttl": 30, "args": [NAME]},
    ("disk", "marks"): {"kind": "tsv", "ttl": 10},
    # the file manager (fm.sh, docs/PLAN-file-manager.md): the places, the same-files rule, one page of a folder (a cursor, never the whole tree), a job's state
    ("fm", "locations"): {"kind": "tsv", "ttl": 5},
    ("fm", "pair"): {"kind": "tsv", "ttl": 5, "args": [FM_LOC, FM_LOC]},
    ("fm", "ls"): {"kind": "tsv", "ttl": 0, "args": [FM_LOC], "query": {"path": (r"^[^\x00-\x1f]{0,1024}$", "--path"), "cursor": (r"^[0-9]{1,9}$", "--cursor"),
                                                                        "limit": (r"^[0-9]{1,4}$", "--limit")}},
    ("fm", "progress"): {"kind": "tsv", "ttl": 0, "args": [UNIT]},
    ("disk", "ls"): {"kind": "tsv", "ttl": 5,"args": [r"^data-[0-9]{1,3}$"], "query": {"path": (r"^(?!.*(^|/)\.\.(/|$))(shares|sensitive)(/[^/\x00-\x1f]{1,255}){0,20}$", "--path")}},
    ("state", "smart"): {"kind": "tsv", "ttl": 30, "args": [NAME]},
    ("state", "history"): {"kind": "json", "ttl": 30},
    ("temp-disk", "raw"): {"kind": "tsv", "ttl": 30},
    ("ct", "storage"): {"kind": "tsv", "ttl": 15, "args": [NAME]},
    ("ct", "users"): {"kind": "tsv", "ttl": 30, "args": [NAME]},
    ("ct", "logs"): {"kind": "text", "ttl": 3, "args": [NAME], "query": {"lines": (r"^[0-9]{1,4}$", "")}},
    ("users", "access"): {"kind": "tsv", "ttl": 30, "args": [NAME]},
    ("users", "group-access"): {"kind": "tsv", "ttl": 30, "args": [GROUP]},
    ("users", "details"): {"kind": "tsv", "ttl": 30, "args": [NAME]},
    ("users", "group-details"): {"kind": "tsv", "ttl": 30, "args": [GROUP]},
    ("shares", "deleted"): {"kind": "tsv", "ttl": 60},
    ("shares", "principals"): {"kind": "tsv", "ttl": 60},
    ("backup", "find"): {"kind": "tsv", "ttl": 30, "args": [r"^[^\x00-\x1f/\\*?\[\]]{2,80}$"]},
    ("backup", "snapshots"): {"kind": "tsv", "ttl": 30, "query": {"tag": (r"^(shares|host|ct:[a-z][a-z0-9-]{0,40})$", "")}},
    ("system", "doctor"): {"kind": "text", "ttl": 60},
    ("system", "cleanup"): {"kind": "text", "ttl": 60},
    ("system", "report"): {"kind": "text", "ttl": 60},
    # new pages (scripts and registry rows are added with the pages; the contract of each is in its script header)
    ("expiry", "list"): {"kind": "tsv", "ttl": 60},
    # Games and Posters are extension packages: their reads are declared in capabilities/<name>/capability.toml ([[web.reads]]), see ext_load_web
    ("hardware",): {"kind": "tsv", "ttl": 10},
    ("encryption", "list"): {"kind": "tsv", "ttl": 15},
    ("vault", "usage"): {"kind": "tsv", "ttl": 30},
    ("vault", "uses"): {"kind": "tsv", "ttl": 60},
    ("recipes", "list"): {"kind": "tsv", "ttl": 60},
    # the Marketplace: everything installable and the repositories it comes from (pkg-change.sh does the changes)
    ("pkg", "market"): {"kind": "tsv", "ttl": 30},
    ("pkg", "repos"): {"kind": "tsv", "ttl": 30},
    ("dc", "state"): {"kind": "tsv", "ttl": 60},
    ("recipes", "asks"): {"kind": "tsv", "ttl": 60, "args": [r"^[a-z0-9][a-z0-9-]{0,40}$"]},
    ("services", "list"): {"kind": "tsv", "ttl": 15},
    ("services", "show"): {"kind": "tsv", "ttl": 10, "args": [r"^[a-z0-9][a-z0-9-]{0,40}$"]},
    ("services", "app"): {"kind": "tsv", "ttl": 15},
    ("services", "routes"): {"kind": "tsv", "ttl": 15},
    ("services", "local-routes"): {"kind": "tsv", "ttl": 15},
    ("services", "tiles"): {"kind": "tsv", "ttl": 30},
    ("services", "stats"): {"kind": "tsv", "ttl": 30},
    ("gateway", "status"): {"kind": "tsv", "ttl": 30},
    ("gateway", "routes"): {"kind": "tsv", "ttl": 30},
    ("gateway", "health"): {"kind": "tsv", "ttl": 300},
    ("setup", "list"): {"kind": "tsv", "ttl": 5},
    ("config", "list"): {"kind": "tsv", "ttl": 5},
    ("config", "check"): {"kind": "text", "ttl": 0},
    # notification channels (capability notifications): name, provider, enabled, minprio, quiet, outside, source, ready, categories, caps
    ("notify", "channels"): {"kind": "tsv", "ttl": 10},
    ("notify", "providers"): {"kind": "tsv", "ttl": 60},
}


# ─────────────────────────── changes: plan, then start ───────────────────────────
# A change is `hs sys <area> plan <args>` (what would happen, never changes anything) and then `hs sys <area> start <args> [--confirm <word>]`.
# Like READS this is a closed list: per area the argument patterns that are allowed (alternatives; each argument must match completely).
# The script behind it repeats every check at start, and a plan that has a danger line only starts with its confirm_name typed.
CT = r"^[a-z][a-z0-9-]{0,40}$"
SHARE = r"^[a-z0-9][a-z0-9-]{0,40}$"
ONOFF = r"^(on|off)$"
LABEL = r"^[A-Za-z0-9._-]{1,40}$"
# notification channels: the name, and the options of add / set (--set may repeat; the one secret is the first line of stdin)
NOTIFY_CHANNEL = r"^[a-z][a-z0-9-]{0,30}$"
NOTIFY_OPTS = {"--min-priority": (r"^(min|low|default|high|urgent)$", False), "--quiet": (r"^(respect|ignore)$", False),
               "--enabled": (r"^(yes|no)$", False),
               "--categories": (r"^(alarm|status|heartbeat|digest)(,(alarm|status|heartbeat|digest)){0,3}$", False),
               "--set": (r"^[a-z][a-zA-Z0-9_]{0,30}=[^\x00-\x1f]{0,200}$", True), "--secret": (r"^[a-z][a-zA-Z0-9_]{0,30}$", False)}
SNAP = r"^[A-Za-z0-9][A-Za-z0-9._:@-]{0,80}$"
# instance forms: numbers with sane bounds (RAM in MiB, disk in GiB; "none" removes a limit), IPv4, a storage name, a path inside the instance without ".."
CT_RAM = r"^(none|[1-9][0-9]{2,6})$"
CT_CPU = r"^(none|[1-9][0-9]?|1[0-9]{2}|2[0-4][0-9]|25[0-6])$"
CT_DISK = r"^[1-9][0-9]{0,4}$"
IPV4 = r"^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){3}$"
CT_STORE = r"^[A-Za-z0-9][A-Za-z0-9._-]{0,60}$"
CT_PATH = r"^/(?!.*\.\.)[A-Za-z0-9._/-]{1,120}$"
CT_PROFILE = r"^[A-Za-z0-9][A-Za-z0-9._-]{0,40}$"                                   # a network (VLAN) profile of Incus
CT_BIND = r"^(fast|shares|sensitive):[A-Za-z0-9][A-Za-z0-9._-]{0,60}:(?!.*\.\.)/[A-Za-z0-9._/-]{0,200}(:ro)?$"     # <kind>:<name>:<path inside>[:ro]
POOL = r"^[a-z][a-z0-9-]{0,20}$"
USER_NEW = r"^[A-Za-z][A-Za-z0-9._-]{0,31}$"                       # a new login starts with a letter
FULL_NAME = r"^\w[\w .'-]{0,63}$"                                     # a full name: letters, digits, spaces; never starts with a dash
CHANGE = r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}:[A-Za-z0-9][A-Za-z0-9._ -]{0,63}=(add|remove)$"     # <user>:<group>=add|remove
# settings the web UI may change (machine.toml keys); everything else (keys, host name, addresses, secrets) stays a terminal job
# schema:begin CONFIG_KEYS (generated by scripts/schema-gen.py; edit config/schema.toml)
CONFIG_KEYS = ("timeZone|language|keyMap|icons|loginMessage|webAccent|incusUi|syncEveryHours|shareSnapshots|"
               "diskSpindownMinutes|fileManagerWrite|setupDone|backupNewShares|notifySecondMinPriority|notifications|"
               "quietHours|autoMitigate|metrics|metricsDays|metricsMaxGB|deckApi|gatewayPublicHttps|"
               "gatewayPublicHttp|gatewayUnknownHostLocal|gatewayUnknownHostPublic|gatewayTunnelPort|"
               "gatewayAcmeEmail|gatewayAcmeStaging")
# schema:end CONFIG_KEYS
# share forms: a folder name inside the instance (absolute) and inside a share (relative or absolute, both without ..), a SID with its level, a kept folder
CT_PATH = r"^(?!.*\.\.)/[A-Za-z0-9._/-]{0,200}$"
SHARE_PATH = r"^(?!.*\.\.)/?[A-Za-z0-9_][A-Za-z0-9._/ -]{0,200}$"
UIDGID = r"^[0-9]{1,7}:[0-9]{1,7}$"
SHARE_ACCESS = r"^[a-z0-9][a-z0-9-]{0,40}=(read|write|full)$"
SID_LEVEL = r"^S-1-[0-9]{1,12}(-[0-9]{1,12}){1,15}=(none|read|write|full)$"
KEPT = r"^[a-z0-9][a-z0-9-]{0,40}\.deleted-[0-9]{8}$"
DISKID = r"^(?!.*\.\.)[A-Za-z0-9][A-Za-z0-9._:+-]{0,100}$"                 # sda, nvme0n1, ata-WDC_WD40EFRX_WD-1234 (no '/', no '..')
DISKIDS = r"^(?!.*\.\.)[A-Za-z0-9][A-Za-z0-9._:+-]{0,100}(,[A-Za-z0-9][A-Za-z0-9._:+-]{0,100}){0,15}$"
FSTYPE = r"^(ext4|xfs|btrfs)$"
DISKPATH = r"^(?!.*(^|/)\.\.(/|$))(shares|sensitive)(/[^/\x00-\x1f]{1,255}){1,20}$"                 # a folder or file below shares/ or sensitive/ of a data disk
DISKDIR = r"^(?!.*(^|/)\.\.(/|$))(shares|sensitive)(/[^/\x00-\x1f]{1,255}){0,20}$"                 # the same, or a top folder, for listing
FM_PATH = r"^[^\x00-\x1f]{0,1024}$"                                           # a path below a place of the file manager (the script refuses .. and links that leave)
MEMBER = r"^data-[0-9]{1,3}$"                                               # a data disk of the array (hs pool bulk): data-04
PCNAME = r"^[A-Za-z0-9][A-Za-z0-9._-]{0,40}$"
MAC = r"^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$"

TEMP_PART = r"^[a-z][a-z0-9]{1,20}$"                                          # a partition the temp-disk list offers: sdg1, nvme1n1p1
TEMP_NAME = r"^[a-z0-9][a-z0-9-]{0,31}$"                                      # the name of a mounted temp disk (/mnt/temp/<name>)
CHANGES = {
    "jobs": [[r"^(run|stop)$", UNIT]],
    # the file manager (fm.sh): copy, move, delete, rename, mkdir. The selection (names below --path) is NOT an argument: the body field `selection` (a list of names,
    # at most FM_SELECTION_MAX) goes to the script on stdin, NUL separated, never argv. The script enforces every rule itself; --by (who) is added here, not by the client.
    "fm": [{"fixed": [r"^(copy|move|delete|rename|mkdir)$"],
            "opts": {"--from": (FM_LOC, False), "--to": (FM_LOC, False), "--path": (FM_PATH, False), "--to-path": (FM_PATH, False),
                     "--conflict": (r"^(skip|rename|newer|overwrite)$", False), "--verify": (r"^(size|checksum)$", False), "--parity-after": (None, False),
                     "--newname": (r"^[^\x00-\x1f/]{1,255}$", False), "--conflicts": (None, False)},
            "selection": True}],
    # one public key line (type, base64 body, optional comment; no newline: fullmatch + the character classes) / the id column of `ssh-key list`
    "ssh-key": [[r"^add$", r"(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) "
                           r"[A-Za-z0-9+/]{16,700}={0,3}( [A-Za-z0-9@._:+=, -]{1,100})?"],
                [r"^remove$", r"[A-Za-z0-9][A-Za-z0-9@._:+/= -]{0,100}"]],
    # pool-change.sh: only the options each action defines; a passphrase (--encrypt) travels on stdin, never in the arguments
    "pool": [{"fixed": [r"^(bulk|fast)$", r"^add$"],
              "opts": {"--disks": (DISKIDS, False), "--role": (r"^(data|parity)$", False), "--fs": (FSTYPE, False), "--encrypt": (None, False)}, "stdin": True},
             {"fixed": [r"^(bulk|fast)$", r"^adopt$"],
              "opts": {"--disks": (DISKIDS, False), "--merge": (None, False), "--chown": (None, False)}},
             # replace and remove always name the member (a bare `remove` is refused here, not answered with `needs`)
             {"fixed": [r"^(bulk|fast)$", r"^replace$", r"^--member$", DISKID],
              "opts": {"--disks": (DISKIDS, False), "--fs": (FSTYPE, False), "--encrypt": (None, False)}, "stdin": True},
             {"fixed": [r"^(bulk|fast)$", r"^remove$", r"^--member$", DISKID],
              "opts": {"--mode": (r"^(detach|vdev|move|nomove)$", False)}},
             # close/open: a SnapRAID data disk takes no new files any more (--drain also moves its files away) / takes them again
             {"fixed": [r"^bulk$", r"^close$", r"^--member$", DISKID], "opts": {"--drain": (None, False)}},
             {"fixed": [r"^bulk$", r"^open$", r"^--member$", DISKID]},
             # convert: a SnapRAID data disk is emptied and formatted again (--fs, --encrypt); ZFS has nothing to convert, so only bulk
             {"fixed": [r"^bulk$", r"^convert$", r"^--member$", DISKID],
              "opts": {"--fs": (FSTYPE, False), "--encrypt": (None, False), "--discard": (None, False)}, "stdin": True}],
    "disk": [[DISKID, r"^test$", r"^(short|long)$"],
             # wipe: erase a disk that belongs to nothing (disk-change.sh refuses a mounted, pool, array or backup disk); red, the disk name is typed
             [DISKID, r"^wipe$"],
             # forget: a MISSING disk leaves the inventory for good (the state database; the serial is typed)
             [DISKID, r"^forget$"],
             # recover: deleted files of a data disk of the array are searched (photorec, read only, a job); the disk leaves /bulk until recover-finish
             {"fixed": [MEMBER, r"^recover$"], "opts": {"--to": (MEMBER, False), "--types": (r"^(media|all)$", False)}},
             [MEMBER, r"^recover-finish$"],
             # detach / attach: a data disk out of /bulk for work by hand (disk-detach.sh); detach is typed (the files are missing in /bulk meanwhile)
             [MEMBER, r"^(detach|attach)$"],
             # move: a folder from one data disk of the array to another (disk-move.sh: disk to disk, the pool is never the source)
             {"fixed": [MEMBER, r"^move$"], "opts": {"--path": (DISKPATH, False), "--to": (MEMBER, False)}},
             # another disk (USB, hot-plug): mounted read-only and shared by temp-disk.sh, copied into a share, ejected
             {"fixed": [TEMP_PART, r"^temp-mount$"], "opts": {"--name": (TEMP_NAME, False)}},
             {"fixed": [TEMP_NAME, r"^temp-copy$"], "opts": {"--to": (SHARE, False)}},
             [TEMP_NAME, r"^temp-eject$"]],
    # run a recipe as a job with the stored answers or the defaults; a recipe that needs something typed is refused by the plan (recipe-change.sh)
    # the services and their routes on the reverse proxy (services-change.sh): apply (red when a route goes public, changes or goes away), adopt, import, forget one
    # shares between two homeservers (peer-change.sh): the password of an added share is one line on stdin; `offer` answers with the new password in the
    # start answer (key `secret`), once: it is never a job, so no job log keeps it, and the "web change" log line names the arguments only
    "peers": [{"fixed": [r"^offer$", r"^[a-z0-9][a-z0-9-]{0,19}$", r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"], "opts": {"--new-password": (None, False)}},
{"fixed": [r"^add$", r"^[a-z0-9][a-z0-9-]{0,19}$", r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,252}$", r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"],
               "opts": {"--user": (r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", False), "--domain": (r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", False)}, "stdin": True},
              [r"^(remove|revoke)$", r"^[a-z0-9][a-z0-9-]{0,19}$"],
              [r"^(remove|revoke)$", r"^[a-z0-9][a-z0-9-]{0,19}$", r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"],
              {"fixed": [r"^(attach|detach)$", r"^[a-z0-9][a-z0-9-]{0,19}$", r"^[A-Za-z0-9][A-Za-z0-9-]{0,62}$"], "opts": {"--path": (r"^/[A-Za-z0-9._/-]{1,200}$", False)}}],
    # the vault and the secrets (vault-change.sh): a header backup, move secrets in (optionally by name), close (red), root-only permissions; init, bind and open are not here
    "secrets": [[r"^(header-backup|close|secrets-fix)$"], [r"^move$"], [r"^move$", r"^[A-Za-z0-9][A-Za-z0-9._-]{0,60}$"]],
    # small chores (admin-change.sh): a test push message, pin the MACs, move the upload cache now, clean the fans
    "admin": [[r"^(test-push|pin-macs|cache-mover)$"], {"fixed": [r"^fans-clean$"], "opts": {"--seconds": (r"^[0-9]{1,2}$", False)}}],
    # the certificates of the domain controller (dc-change.sh): make the CA once, renew the certificate of a controller on this server (red: Samba restarts)
    "dc": [[r"^ca$"], {"fixed": [r"^renew$"], "opts": {"--dc": (r"^[A-Za-z0-9][A-Za-z0-9-]{0,62}$", False)}}],
    # posters (poster-change.sh) are the extension "posters": area "ext/posters", declared in its manifest; the picture is served by GET /api/poster/<file>
    # the router connection (net-change.sh): the address as an option, the API key as the one line on stdin
    "net": [{"fixed": [r"^setup$"], "opts": {"--address": (r"^https?://[A-Za-z0-9._:-]{1,100}/?$", False)}, "stdin": True}],
    # add / edit: describe a service or change its description (services.py checks the rest); public-ok is red (the typed word is the service name)
    "routes": [[r"^(apply|adopt|import)$"], [r"^apply$", r"^--proxy$", r"^local$"], [r"^import$", r"^--proxy$", r"^local$"], [r"^remove$", r"^[A-Za-z0-9][A-Za-z0-9._-]{0,60}$"],
               {"fixed": [r"^set$", r"^[a-z0-9][a-z0-9-]{0,40}$"],
                "opts": {"--local": (r"^(yes|no)$", False), "--public": (r"^(yes|no)$", False),
                         "--public-name": (r"^[A-Za-z0-9][A-Za-z0-9.-]{0,250}$", False)}},
               {"fixed": [r"^(add|edit)$", r"^[a-z0-9][a-z0-9-]{0,40}$"],
                "opts": {"--port": (r"^[0-9]{1,5}$", False), "--container": (r"^[A-Za-z0-9][A-Za-z0-9-]{0,62}$", False),
                         "--host": (r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,100}$", False), "--title": (r"^[^\x00-\x1f]{1,160}$", False),
                         "--names": (r"^[a-z0-9][a-z0-9,-]{0,100}$", False), "--exposure": (r"^(never-public|private-ok|public-ok)$", False),
                         "--public-path": (r"^/[A-Za-z0-9._/-]{0,100}$", True), "--blocked-path": (r"^/[A-Za-z0-9._/-]{0,100}$", True),
                         "--auth-skip": (r"^/[A-Za-z0-9._/-]{0,100}$", True), "--auth": (r"^(authentik|none)$", False),
                         "--request-header": (r"^[A-Za-z0-9-]{1,64}: [ -~]{1,200}$", True), "--response-header": (r"^[A-Za-z0-9-]{1,64}: [ -~]{1,200}$", True),
                         "--want": (r"^[a-z,-]{1,80}$", False),
                         "--clear": (r"^(title|icon|group|description|names|public-path|blocked-path|auth|auth-skip|request-header|response-header)$", True),
                         "--group": (r"^[^\x00-\x1f]{1,160}$", False), "--icon": (r"^[^\x00-\x1f]{1,160}$", False),
                         "--description": (r"^[^\x00-\x1f]{1,160}$", False)}}],
    # the Marketplace (pkg-change.sh): install / update / remove a package, fetch the repositories, add a repository (its public key is ONE line on stdin) or
    # remove one; a package or repository that came from an added source is red (the typed word is its name)
    "pkg": [{"fixed": [r"^install$", r"^[a-z0-9][a-z0-9-]{0,40}$"], "opts": {"--repo": (r"^[a-z0-9][a-z0-9-]{0,40}$", False)}},
            [r"^(update|remove)$", r"^[a-z0-9][a-z0-9-]{0,40}$"],
            [r"^fetch$"], [r"^fetch$", r"^[a-z0-9][a-z0-9-]{0,40}$"],
            {"fixed": [r"^repo-add$", r"^[a-z0-9][a-z0-9-]{0,40}$", r"^(https://|ssh://git@|git@)[A-Za-z0-9._:/@~+-]{3,200}$"], "stdin": True},
            [r"^repo-remove$", r"^[a-z0-9][a-z0-9-]{0,40}$"]],
    # an answer is `--set KEY=value` (no control characters); the one secret answer of a recipe is a single line on stdin
    "recipes": [{"fixed": [r"^[a-z0-9][a-z0-9-]{0,40}$", r"^run$"],
                 "opts": {"--name": (r"^[a-z0-9][a-z0-9-]{0,40}$", False), "--set": (r"^[A-Z][A-Z0-9_]{0,30}=[^\x00-\x1f]{0,300}$", True)}, "stdin": True}],
    # the proxyserver (VPS): exactly these two words; scripts/vps-change.sh adds nothing else to the ssh command line, and the key on the VPS can only run them
    "vps": [[r"^(update|watch)$"]],
    # switch an optional part (part-change.sh): enable/disable <name>; off with a NixOS module is red
    "parts": [[r"^(enable|disable)$", r"^[a-z][a-z0-9-]{0,30}$"]],
    # the list of nodes (node-change.sh): add (name, host, kind, port), remove and key (--new replaces it; both red). Nothing here reaches a remote node:
    # a node is a row on THIS server and a key file; what the other server allows is its owner's business (the key line comes from the read node/keyline)
    "node": [{"fixed": [r"^add$", r"^[a-z][a-z0-9-]{0,30}$", r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,100}$"],
              "opts": {"--kind": (r"^(peer|vps|edge)$", False), "--port": (r"^[0-9]{1,5}$", False)}},
             [r"^remove$", r"^[a-z][a-z0-9-]{0,30}$"],
             [r"^key$", r"^[a-z][a-z0-9-]{0,30}$"],
             [r"^key$", r"^[a-z][a-z0-9-]{0,30}$", r"^--new$"]],
    "ct": [[CT, r"^(start|stop|restart|snapshot|update|delete)$"],
           [r"^all$", r"^update-all$"],            # snapshot and update every running container (ct-change.sh update-all)
           [CT, r"^snapshot$", r"^--label$", LABEL],
           [CT, r"^(restore|delete-snapshot)$", r"^--snapshot$", SNAP],
           # forms of the Instances page (docs/PLAN-web-backend.md, Create dialog and forms)
           {"fixed": [CT, r"^create$"], "opts": {"--type": (r"^(container|docker|vm)$", False), "--ram": (CT_RAM, False), "--cpu": (CT_CPU, False),
                                                 "--disk": (CT_DISK, False), "--address": (IPV4, False),
                                                 "--profile": (CT_PROFILE, False), "--bind": (CT_BIND, True)}},
           {"fixed": [CT, r"^set$"], "opts": {"--ram": (CT_RAM, False), "--cpu": (CT_CPU, False), "--disk": (CT_DISK, False),
                                             "--autostart": (r"^(yes|no)$", False), "--docker": (r"^(yes|no)$", False)}},
           {"fixed": [CT, r"^ip$"], "opts": {"--address": (IPV4, False)}},
           {"fixed": [CT, r"^add-storage$"], "opts": {"--kind": (r"^(fast|shares|sensitive)$", False), "--name": (CT_STORE, False),
                                                      "--path": (CT_PATH, False), "--readonly": (None, False), "--as": (r"^[0-9]{1,6}:[0-9]{1,6}$", False)}},
           {"fixed": [CT, r"^remove-storage$"], "opts": {"--device": (CT_STORE, False)}}],
    "backup": [[r"^(now|verify|prune|drill)$"],
               {"fixed": [r"^init$"], "opts": {"--disk": (DISKID, False)}},     # make a free disk the backup disk (red: the kernel name of the disk is typed)
               [r"^drill$", r"^--count$", r"^[0-9]{1,2}$"],
               [r"^browse$", r"^--to$", ONOFF],
               [r"^toggle$", r"^--name$", NAME, r"^--kind$", r"^(shares|sensitive|ct)$", r"^--to$", ONOFF],
               [r"^offsite-now$"], [r"^offsite-off$"]],     # offsite-set stays a terminal job: an address can carry a password (rest:https://user:pw@host)
    "shares": [[SHARE, r"^(snapshot|repair)$"],
               [SHARE, r"^snapshot$", r"^--label$", LABEL],
               [SHARE, r"^(backup|cache|auto)$", r"^--to$", ONOFF],
               [SHARE, r"^rollback$", r"^--snapshot$", SNAP],
               # forms (web/src/forms/shares): create, permissions, rename, delete, purge a kept folder, restore from the backup
               {"fixed": [SHARE, r"^add$"],
                "opts": {"--kind": (r"^(shares|sensitive)$", False), "--ct": (CT, False), "--path": (CT_PATH, False), "--as": (UIDGID, False)}},
               {"fixed": [SHARE, r"^perm$"], "opts": {"--set": (SID_LEVEL, True)}},
               [SHARE, r"^visibility$", r"^--to$", r"^(visible|hidden)$"],
               [SHARE, r"^rename$", r"^--to$", SHARE],
               [SHARE, r"^delete$"],
               [KEPT, r"^purge$"],
               [KEPT, r"^undelete$"],      # bring a kept folder back as the share of its old name (a rename; nothing is overwritten)
               {"fixed": [SHARE, r"^restore$"], "opts": {"--snapshot": (r"^(latest|[A-Za-z0-9]{1,64})$", False), "--path": (SHARE_PATH, False)}}],
    "users": [[NAME, r"^(lock|unlock)$"],
              {"fixed": [USER_NEW, r"^user-add$"], "opts": {"--full": (FULL_NAME, False), "--group": (GROUP, True)}, "stdin": True},     # the password: one line on stdin; --group: existing groups to join
              {"fixed": [NAME, r"^password$"], "stdin": True},
              {"fixed": [GROUP, r"^group-add$"], "opts": {"--access": (SHARE_ACCESS, True)}},     # <share>=read|write|full, given to the new group
              # details of an account or group: only the named fields change, "-" clears one (manage-users.sh --edit)
              {"fixed": [NAME, r"^user-edit$"], "opts": {"--full": (r"^(-|\w[\w .'-]{0,63})$", False), "--mail": (r"^(-|[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,190})$", False),
                                                       "--description": (r"^[^\x00-\x1f\x7f]{1,255}$", False)}},
              {"fixed": [GROUP, r"^group-edit$"], "opts": {"--description": (r"^[^\x00-\x1f\x7f]{1,255}$", False)}},
              [NAME, r"^user-delete$"],
              [GROUP, r"^group-delete$"],
              [r"^all$", r"^flush$"],
              {"fixed": [GROUP, r"^membership$"], "opts": {"--change": (CHANGE, True)}}],
    # a saved game PC (wake, forget, save) is the extension "games": area "ext/games", declared in its manifest (the plan checks the MAC)
    "expiry": [{"fixed": [r"^add$", r"^[A-Za-z0-9][A-Za-z0-9 ._()-]{0,60}$"],
                "opts": {"--date": (r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$", False), "--renew": (r"^[^\t\r\n\x00]{0,120}$", False)}},
               [r"^remove$", r"^[A-Za-z0-9][A-Za-z0-9 ._()-]{0,60}$"]],
    # acknowledge a health problem, take it back, lift the pause of the bulk jobs (health-change.sh checks the id against the listed problems)
    "health": [[r"^(ack|unack)$", r"^[A-Za-z0-9][A-Za-z0-9:._ ()-]{0,100}$"], [r"^resume$"]],
    "system": [[r"^(sync|scrub|update|gc|rollback|reboot|shutdown)$"],
               [r"^(sync|scrub)$", r"^--pool$", POOL]],
    "config": [[r"^set$", r"^(" + CONFIG_KEYS + r")$", r"^[A-Za-z0-9._#:/ -]{0,80}$"], [r"^(sync|migrate)$"]],
    # notification channels: a secret (the topic address, the SMTP password) goes in on stdin, never as an argument; a text setting as --set key=value
    "notify": [{"fixed": [r"^add$", NOTIFY_CHANNEL],
                "opts": dict(NOTIFY_OPTS, **{"--provider": (r"^[a-z][a-z0-9-]{0,30}$", False)}), "stdin": True},
               {"fixed": [r"^set$", NOTIFY_CHANNEL], "opts": NOTIFY_OPTS, "stdin": True},
               [r"^(remove|test)$", NOTIFY_CHANNEL],
               [r"^migrate$"]],
}
CONFIRM_RE = re.compile(r"^[A-Za-z0-9._ -]{1,64}$")


# ─────────────────────── extension packages: reads and changes from their manifests ───────────────────────
# An extension package (capabilities/<name>/, docs/PLAN-extensions.md) may declare in its capability.toml which `hs sys ext <name> ...` reads the
# web interface may ask for ([[web.reads]]) and which changes it may start ([[web.changes]]); only while the package is on. Nothing else a
# package says reaches the browser: no code, no page, only these two lists, and each entry must be a sys row of the package's own commands.tsv.
#   [[web.reads]]    words = "list"  kind = "tsv"|"json"|"text"  ttl = 30  [args = ['^pattern$', ...]]   -> GET /api/sys/ext/<name>/<words>
#   [[web.changes]]  patterns = ['^a$', '^b$']                                    (an exact shape)   or
#                    fixed = ['^a$'] opts = [{ flag = "--x", pattern = '^..$', repeats = false }]  stdin = false
#                    -> POST /api/plan|start with area "ext/<name>"; the plan and start rows `sys ext <name> plan|start ...` must exist
EXT_NAME = re.compile(r"^[a-z][a-z0-9-]{0,30}$")
EXT_KINDS = ("tsv", "json", "text")
_ext = {"at": 0.0, "lock": threading.Lock(), "pages": []}
EXT_BLOCKS = ("table", "kv", "cards", "text", "empty", "gallery")


def applied_recipes():
    """the packages hs recipe has applied on this server (installed.toml, written by scripts/pkg.py record): a recipe package is on from then on"""
    import tomllib
    try:
        with open(os.path.join(env("HS_STATE_DIR", "/var/lib/hs"), "packages", "installed.toml"), "rb") as f:
            return set(tomllib.load(f).get("package", {}))
    except (OSError, tomllib.TOMLDecodeError):
        return set()


def ext_roots():
    """The folders that hold packages (the same order as scripts/lib/registry-load.sh): HS_PACKAGES_DIR alone, or the checkout beside scripts/ and
    /etc/nixos (the scripts run from a copy in the Nix store that has no capabilities/). A pinned-commit location is added here later."""
    if env("HS_PACKAGES_DIR", ""):
        return [env("HS_PACKAGES_DIR", "")]
    here = os.path.dirname(os.path.abspath(__file__))
    base = os.path.dirname(here)
    cur = os.path.join(env("HS_STATE_DIR", "/var/lib/hs"), "packages", "current")      # installed from a repository (scripts/pkg_repo.py)
    return [r for r in (os.path.join(base, "capabilities"), "/etc/nixos/capabilities", os.path.join(base, "packages"), "/etc/nixos/packages", cur) if os.path.isdir(r)]


def _ext_pattern(p):
    if not isinstance(p, str) or not 1 <= len(p) <= 400:
        raise ValueError("bad pattern")
    re.compile(p)
    return p


def ext_sys_rows(path):
    """the sys rows of a package's commands.tsv as word tuples with <x> for every value: ('ext', 'games', 'plan', '<x>', '<x>')"""
    rows = set()
    with open(path, encoding="utf-8") as f:
        for line in f:
            c = line.rstrip("\r\n").split("\t")
            if line.startswith("#") or len(c) < 2 or c[0] != "sys":
                continue
            rows.add(tuple("<x>" if w.startswith("<") else w for w in c[1].split()[1:]))
    return rows


def _ext_page(name, page, words):
    """The [web.page] declaration of a package for the generic page of the frontend (web/src/shell/GenericPage.svelte): plain data, checked here so
    that it names only reads the package declared and changes of its own area. Raises ValueError. -> the declaration as it goes out."""
    if not isinstance(page, dict) or len(json.dumps(page)) > 30000:
        raise ValueError("bad page")
    known = {" ".join(w[2:]) for w in words}

    def walk(node):
        if isinstance(node, dict):
            r = node.get("read")
            if r is not None and r not in known:
                raise ValueError("the page reads %r, which is not a declared read" % r)
            for j in node.get("joins", []):
                if j.get("read") not in known:
                    raise ValueError("a join reads something that is not a declared read")
            if node.get("type") is not None and node["type"] not in EXT_BLOCKS:
                raise ValueError("unknown block type")
            for key in ("actions", "rowActions"):
                for a in node.get(key, []):
                    if "plan" in a and (not isinstance(a["plan"], list) or not a["plan"] or a["plan"][0] != "ext/" + name):
                        raise ValueError("a page action may only plan changes of its own area")
            for c in node.get("columns", []):
                pl = c.get("plan")
                if pl is not None and (not isinstance(pl, list) or not pl or pl[0] != "ext/" + name):
                    raise ValueError("a switch may only plan changes of its own area")
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)
    walk(page)
    return {"name": name, **page}


def ext_load_web():
    """-> (reads, changes, pages) declared by the manifests of the packages that are on. A package whose declaration is wrong adds nothing."""
    import tomllib
    reads, changes, pages, on, done = {}, {}, [], set(capabilities()) | applied_recipes(), set()
    for root in ext_roots():
        try:
            names = sorted(os.listdir(root))
        except OSError:
            continue
        for name in names:
            d = os.path.join(root, name)
            if name not in on or not EXT_NAME.match(name) or name in done:
                continue
            done.add(name)          # the first folder that has the package wins
            try:
                manifest = os.path.join(d, "capability.toml")
                if not os.path.isfile(manifest):
                    manifest = os.path.join(d, "package.toml")      # a recipe package; its page and reads are declared the same way
                with open(manifest, "rb") as f:
                    web = tomllib.load(f).get("web", {})
                if not web:
                    continue        # a capability without a [web] declaration (most of them) has nothing to register and no commands.tsv
                rows = ext_sys_rows(os.path.join(d, "commands.tsv"))
                r_new, c_new, p_new = {}, [], None
                for rd in web.get("reads", []):
                    words = tuple(["ext", name] + str(rd["words"]).split())
                    args = [_ext_pattern(a) for a in rd.get("args", [])]
                    if rd["kind"] not in EXT_KINDS or not isinstance(rd["ttl"], int) or not 0 <= rd["ttl"] <= 3600 or len(words) < 3:
                        raise ValueError("bad read")
                    if words + tuple("<x>" for _ in args) not in rows or set(words) & {"plan", "start", "stop", "delete", "purge"}:
                        raise ValueError("a read is not a sys row of the package, or changes something")
                    spec = {"kind": rd["kind"], "ttl": rd["ttl"]}
                    if args:
                        spec["args"] = args
                    r_new[words] = spec
                for ch in web.get("changes", []):
                    if "patterns" in ch:
                        c_new.append([_ext_pattern(p) for p in ch["patterns"]])
                    else:
                        ent = {"fixed": [_ext_pattern(p) for p in ch["fixed"]],
                               "opts": {o["flag"]: (_ext_pattern(o["pattern"]) if o.get("pattern") is not None else None, bool(o.get("repeats", False)))
                                        for o in ch.get("opts", [])}}
                        if ch.get("stdin"):
                            ent["stdin"] = True
                        for flag in ent["opts"]:
                            if not re.fullmatch(r"--[a-z][a-z0-9-]{0,30}", flag):
                                raise ValueError("bad flag")
                        c_new.append(ent)
                if "page" in web:
                    p_new = _ext_page(name, web["page"], list(r_new))
                heads = {w[:3] for w in rows}
                if c_new and not (("ext", name, "plan") in heads and ("ext", name, "start") in heads):
                    raise ValueError("changes need the plan and start rows of the package")
            except (OSError, KeyError, TypeError, ValueError, re.error, tomllib.TOMLDecodeError) as e:
                print("extension %s: web declaration ignored (%s)" % (name, e), flush=True)
                continue
            reads.update(r_new)
            if p_new:
                pages.append(p_new)
            if c_new:
                changes["ext/" + name] = c_new
    return reads, changes, pages


def ext_pages():
    """the page declarations of the packages that are on (the session answer carries them as features.extensions)"""
    ext_refresh()
    return list(_ext["pages"])


def ext_refresh(force=False):
    """Bring READS and CHANGES in step with the packages that are on (at most every 3 s, a package switched on by `hs ext enable` needs no restart)."""
    if not force and time.time() - _ext["at"] < 3:
        return
    with _ext["lock"]:
        if not force and time.time() - _ext["at"] < 3:
            return
        _ext["at"] = time.time()
        reads, changes, pages = ext_load_web()
        _ext["pages"] = pages
        for k in [k for k in READS if k[0] == "ext"]:
            del READS[k]
        for k in [k for k in CHANGES if k.startswith("ext/")]:
            del CHANGES[k]
        READS.update(reads)
        CHANGES.update(changes)


def _entry_match(entry, args):
    """-> (ok, takes_stdin). An entry is a list of patterns (an exact shape) or a dict {fixed: [patterns], opts: {--flag: (pattern|None, repeats)}, stdin: bool}
    whose options may follow the fixed arguments in any order (a flag without a pattern is a switch, a flag with `repeats` may appear more than once)."""
    if isinstance(entry, list):
        return len(args) == len(entry) and all(re.fullmatch(p, a) for p, a in zip(entry, args)), False
    fixed, opts = entry["fixed"], entry.get("opts", {})
    if len(args) < len(fixed) or not all(re.fullmatch(p, a) for p, a in zip(fixed, args)):
        return False, False
    rest, seen, i = args[len(fixed):], set(), 0
    while i < len(rest):
        flag = rest[i]
        if flag not in opts or (flag in seen and not opts[flag][1]):
            return False, False
        seen.add(flag)
        pat = opts[flag][0]
        if pat is None:
            i += 1
        elif i + 1 < len(rest) and re.fullmatch(pat, rest[i + 1]):
            i += 2
        else:
            return False, False
    return True, bool(entry.get("stdin"))


STDIN_RE = re.compile("[^" + chr(13) + chr(10) + chr(0) + "]{1,256}")      # one line, no control characters
FM_SELECTION_MAX = 20000          # names in one file manager selection
FM_SELECTION_BYTES = 4 * 1024 * 1024


def _selection_ok(sel):
    """the `selection` of a file manager change: a list of names (no NUL, no slash, 1..255 characters; the script checks the rest)"""
    if not isinstance(sel, list) or len(sel) > FM_SELECTION_MAX:
        return False
    total = 0
    for n in sel:
        if not isinstance(n, str) or not 1 <= len(n) <= 255 or "\0" in n or "/" in n:
            return False
        total += len(n.encode("utf-8", "surrogateescape")) + 1
    return total <= FM_SELECTION_BYTES


def validate_change(body):
    """-> (area, args, confirm, stdin) or None. A password or passphrase travels in `stdin` (one line), only for entries that take it, never in args."""
    area, args, confirm, stdin = body.get("area"), body.get("args"), body.get("confirm"), body.get("stdin")
    ext_refresh()
    if not isinstance(area, str) or area not in CHANGES or not isinstance(args, list)             or not all(isinstance(a, str) for a in args):
        return None
    hits = [_entry_match(e, args) for e in CHANGES[area]]
    if not any(ok for ok, _ in hits):
        return None
    takes_stdin = any(ok and st for ok, st in hits)
    if confirm is not None and (not isinstance(confirm, str) or not CONFIRM_RE.fullmatch(confirm)):
        return None
    if stdin is not None and (not takes_stdin or not isinstance(stdin, str) or not STDIN_RE.fullmatch(stdin)):
        return None
    sel = body.get("selection")
    if sel is not None:
        # the file manager's selection: names, NUL separated, as BYTES on stdin (no newline is added); only entries that declare "selection", never together with a stdin line
        if stdin is not None or not _selection_ok(sel) or not any(ok and isinstance(e, dict) and e.get("selection") for e, (ok, _) in zip(CHANGES[area], hits)):
            return None
        stdin = b"".join(n.encode("utf-8", "surrogateescape") + b"\0" for n in sel)
    return area, args, confirm, stdin


def parse_change(out, rc):
    """The key<TAB>value lines of a plan or start (scripts/*-change.sh) as one object. step, note, warn, danger, section and text (the update preview lists commits) keep their order."""
    d = {"exit": rc, "status": "", "reason": "", "heading": "", "command": "", "confirm_name": "", "long": False, "unit": "",
         "needs": [], "options": [], "steps": []}
    for line in out.splitlines():
        k, _, v = line.partition("\t")
        if k in ("step", "note", "warn", "danger", "section", "text"):
            d["steps"].append([k, v])
        elif k == "needs":
            d["needs"].append(v)
        elif k == "option":
            d["options"].append(v)
        elif k == "long":
            d["long"] = v == "yes"
        elif k in ("files", "folders", "bytes", "free_after", "conflicts") and v.isdigit():
            d[k] = int(v)          # a file manager plan: the counts
        elif k == "parity":
            d["parity"] = v == "yes"
        elif k == "conflict":
            d.setdefault("conflict_rows", []).append(v.split("\t"))     # --conflicts: path, src bytes, dst bytes, src mtime, dst mtime
        elif k == "id":
            d["id"] = v
        elif k in ("status", "reason", "heading", "command", "confirm_name", "unit"):
            d[k] = v
        elif k == "secret":
            name, _, val = v.partition("\t")      # what the other side types (peer-change.sh offer): login, domain, host, password
            if name in ("login", "domain", "host", "password"):
                d.setdefault("secret", {})[name] = val
        elif k in ("file", "color", "seed", "size"):
            d[k] = v           # what a poster drawing reports
    if not d["status"]:
        d["status"] = "ok" if rc == 0 else "refused"
    if d["status"] == "refused" and not d["reason"]:
        d["reason"] = "The server could not do this (exit %d)." % rc
    return d


class Plans:
    """Finished plans for cfg.plan_ttl seconds, key (area, args). Cleared by every start and by every Reads.clear(); a plan that started
    before a clear is not stored (gen). At most 64 entries, the oldest goes first."""
    MAX = 64

    def __init__(self, ttl):
        self.ttl, self.lock, self.items, self.gen = ttl, threading.Lock(), {}, 0

    def get(self, key):
        if self.ttl <= 0:
            return None
        with self.lock:
            hit = self.items.get(key)
            if hit and time.monotonic() - hit[0] < self.ttl:
                return hit[1]
            self.items.pop(key, None)
            return None

    def put(self, key, gen, d):
        if self.ttl <= 0:
            return
        with self.lock:
            if gen != self.gen:
                return
            self.items.pop(key, None)
            while len(self.items) >= self.MAX:
                self.items.pop(next(iter(self.items)))
            self.items[key] = (time.monotonic(), d)

    def clear(self):
        with self.lock:
            self.items.clear()
            self.gen += 1


def plan_cacheable(area, args, stdin):
    """Never a plan that carried stdin (password, passphrase, file manager selection), nor one whose matching entry takes stdin or a selection."""
    if stdin is not None:
        return False
    for e in CHANGES.get(area, []):
        ok, st = _entry_match(e, args)
        if ok and (st or (isinstance(e, dict) and e.get("selection"))):
            return False
    return True


def plan_stable(out, rc, d):
    """Worth keeping: the script printed its own status line, it is ok/needs/refused, ok only with exit 0, no secret in it, not a failed run."""
    explicit = any(line.startswith("status\t") for line in out.splitlines())
    return (explicit and rc != 127 and d["status"] in ("ok", "needs", "refused") and (d["status"] != "ok" or rc == 0)
            and "secret" not in d)


_LITERAL = re.compile(r"\^?\(?-{0,2}[a-z][a-z0-9-]*(\|-{0,2}[a-z][a-z0-9-]*)*\)?\$?")


def change_shape(area, args):
    """The change for the log without values: an argument stays only when its pattern is a fixed word (or a choice of fixed words) or it is an
    option flag of the entry; everything else is "*". "pool bulk convert --member * --fs *". Never the stdin."""
    for e in CHANGES.get(area, []):
        ok, _ = _entry_match(e, args)
        if not ok:
            continue
        pats = e if isinstance(e, list) else e["fixed"]
        opts = {} if isinstance(e, list) else e.get("opts", {})
        words = [a if (i < len(pats) and _LITERAL.fullmatch(pats[i])) or (i >= len(pats) and a in opts) else "*" for i, a in enumerate(args)]
        return " ".join([area] + words)
    return area


def _timing(verb, shape, t0, how, rc, status):
    """One line per plan and start in the web log (journal of hs-web): `web timing: plan pool bulk add --disks * 1834 ms run rc=0 status=ok`."""
    print("web timing: %s %s %d ms %s rc=%s status=%s" % (verb, shape, round((time.monotonic() - t0) * 1000), how,
                                                          "-" if rc is None else rc, status or "-"), flush=True)


class Reads:
    """Runs an allowlisted `hs sys` read and keeps the answer for its ttl. One run at a time per question, so ten viewers cost one call."""

    def __init__(self, cfg):
        self.cfg, self.lock, self.cache, self.locks, self.refreshing, self.gen = cfg, threading.Lock(), {}, {}, set(), 0
        self.seen = {}        # key -> (spec, argv, when it was last asked for): what the warm-up keeps fresh, also reads with arguments (an instance, a pool)
        self.dirty = False    # something new in the cache since it was last saved
        self.on_clear = None   # App sets it: the plan cache is cleared together with the reads
        self.cleared_at = 0.0  # when clear() last ran: what the collector read before that is from before the change and is not used

    def clear(self):
        with self.lock:
            self.cleared_at = time.time()
            self.cache.clear()
            self.gen += 1          # a refresh that started before this must not put its (older) answer back
        if self.on_clear:
            self.on_clear()

    def resolve(self, segments, query):
        """-> (spec, argv words, cache key) or None when this is not an allowlisted read."""
        ext_refresh()
        for n in range(len(segments), 0, -1):
            words = tuple(segments[:n])
            spec = READS.get(words)
            if spec is None:
                continue
            extra = segments[n:]
            pats = spec.get("args", [])
            if len(extra) != len(pats) or not all(re.fullmatch(p, a) for p, a in zip(pats, extra)):
                return None
            argv = list(words) + list(extra)
            for name, (pat, flag) in sorted(spec.get("query", {}).items()):
                vals = query.get(name)
                if not vals:
                    continue
                if not re.fullmatch(pat, vals[0]):
                    return None
                argv += [flag, vals[0]] if flag else [vals[0]]
            return spec, argv, tuple(argv)
        return None

    def get(self, spec, argv, key):
        code, obj, _ = self.get_aged(spec, argv, key)
        return code, obj

    def get_aged(self, spec, argv, key, fresh=False):
        """-> (code, object, age in seconds or None when it was just read). Stale-while-revalidate: an answer past its ttl but not older than
        min(ttl * stale_factor, stale_max) is returned at once and read again in the background; older ones (and ttl 0 reads) wait for a fresh run.
        fresh: the refresh button of the page; the script is run now, neither the cache nor what the collector kept is used."""
        ttl = spec["ttl"]
        if fresh:
            code, obj = self.fetch(spec, argv, key, force=True)
            return code, obj, 0
        if ttl > 0:
            with self.lock:
                self.seen[key] = (spec, argv, time.time())
                hit = self.cache.get(key)
            if hit:
                age = time.time() - hit[0]
                if age < ttl:
                    return hit[1][0], hit[1][1], age
                if age < min(ttl * self.cfg.stale_factor, self.cfg.stale_max):
                    self.refresh_async(spec, argv, key)
                    return hit[1][0], hit[1][1], age
        code, obj = self.fetch(spec, argv, key)
        with self.lock:
            hit = self.cache.get(key)
        # an answer the collector kept is as old as its reading, not new: the page shows that age
        return code, obj, (max(0.0, time.time() - hit[0]) if hit and hit[1][1] is obj else None)

    def fetch(self, spec, argv, key, force=False):
        """One run per question at a time; an answer younger than the ttl (read by someone else meanwhile) is reused. Errors never replace a good answer.
        force: run the script now (the refresh button), whatever the cache or the collector holds."""
        with self.lock:
            klock = self.locks.setdefault(key, threading.Lock())
        with klock:
            hit = self.cache.get(key)
            if hit and not force and time.time() - hit[0] < spec["ttl"]:
                return hit[1]
            gen = self.gen
            stamp = time.time()
            kept = None if force else self.collected(argv)
            # a kept output older than the one in the cache (a refresh button read a newer one) is not put back
            if kept is not None and kept[0] <= self.cleared_at:
                kept = None   # read before the last change: run the script, the collector has not seen the change yet
            if kept is not None and (not hit or kept[0] > hit[0]) and stamp - kept[0] < self.cfg.collected_max_age and (kept[1] == 0 or kept[2].strip()):
                # the collector has it: no script is started; the answer is as old as the collector's reading
                stamp, rc, out = kept[0], kept[1], kept[2]
            else:
                rc, out = _run([self.cfg.hs, "sys"] + argv, timeout=30)
            result = self._shape(spec, rc, out)
            if result[0] == 200:
                with self.lock:
                    if gen == self.gen:
                        self.cache[key] = (stamp, result)
                        self.dirty = True
            return result

    def refresh_async(self, spec, argv, key):
        with self.lock:
            if key in self.refreshing:
                return
            self.refreshing.add(key)

        def run():
            try:
                self.fetch(spec, argv, key)
            except Exception:
                pass
            finally:
                with self.lock:
                    self.refreshing.discard(key)
        threading.Thread(target=run, daemon=True).start()

    def age(self, key):
        with self.lock:
            hit = self.cache.get(key)
        return None if hit is None else time.time() - hit[0]

    def collected(self, argv):
        """(updated, rc, output) kept by the collector (scripts/reads-collect.sh, table `reads` of the state database) for this read, or None.
        Read-only; any trouble (no database, no table, no row) is just None, and the read is run as it always was."""
        key = " ".join(argv)
        if key not in collected_keys():
            return None
        db = env("HS_STATE_DB", os.path.join(env("HS_STATE_DIR", "/var/lib/hs"), "state.db"))
        if not os.path.exists(db):
            return None
        try:
            c = sqlite3.connect("file:%s?mode=ro" % db.replace("\\", "/"), uri=True, timeout=2)
            try:
                c.execute("PRAGMA query_only=1")
                row = c.execute("SELECT updated, rc, payload FROM reads WHERE key = ?", (key,)).fetchone()
            finally:
                c.close()
        except sqlite3.Error:
            return None
        return None if row is None else (float(row[0]), int(row[1]), row[2])

    def spec_for(self, argv):
        """the allowlist entry of a read that was kept (words first, then what the query added)"""
        ext_refresh()
        for n in range(len(argv), 0, -1):
            spec = READS.get(tuple(argv[:n]))
            if spec is not None:
                return spec if self._shape_ok(spec, argv[n:]) else None
        return None

    @staticmethod
    def _shape_ok(spec, rest):
        """the words after the read's name are exactly its arguments, then its query values (a flag and its value, or the value), each matching its pattern"""
        pats = spec.get("args", [])
        if len(rest) < len(pats) or not all(re.fullmatch(p, a) for p, a in zip(pats, rest)):
            return False
        rest, i = rest[len(pats):], 0
        for _, (pat, flag) in sorted(spec.get("query", {}).items()):
            if flag:
                if rest[i:i + 1] == [flag] and i + 1 < len(rest) and re.fullmatch(pat, rest[i + 1]):
                    i += 2
            elif i < len(rest) and re.fullmatch(pat, rest[i]):
                i += 1
        return i == len(rest)

    def save(self, path):
        """The answers to a file (0600, one JSON document), so a restart of this service does not start cold. Only good answers are kept."""
        if not path or not self.dirty:
            return
        with self.lock:
            items = [{"argv": list(k), "t": t, "code": r[0], "obj": r[1]} for k, (t, r) in self.cache.items() if r[0] == 200]
            self.dirty = False
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            tmp = path + ".tmp"
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(items, f)
            os.replace(tmp, path)
        except OSError:
            pass

    def load(self, path):
        """what save() wrote; an entry is only taken when it still names an allowlisted read, with its own age (an old one is shown stale and read again)"""
        if not path:
            return 0
        try:
            with open(path, encoding="utf-8") as f:
                items = json.load(f)
        except (OSError, ValueError):
            return 0
        n = 0
        for it in items if isinstance(items, list) else []:
            try:
                argv = [str(a) for a in it["argv"]]
                spec = self.spec_for(argv)
                t = float(it["t"])
                if spec is None or spec["ttl"] <= 0 or it["code"] != 200 or time.time() - t > self.cfg.stale_max:
                    continue
                with self.lock:
                    self.cache[tuple(argv)] = (t, (200, it["obj"]))
                n += 1
            except (KeyError, TypeError, ValueError):
                continue
        return n

    def warm_targets(self):
        """(spec, argv, key, how often) of every read the warm-up should keep fresh: the common ones, those somebody asked for lately (with their
        arguments), and, unless switched off, every other read without arguments (at most every warm_idle_ttl seconds)"""
        out, done = [], set()

        def add(spec, argv, every):
            key = tuple(argv)
            if key not in done and spec["ttl"] > 0 and not (self.cfg.live == "redis" and spec.get("topic")):      # a topic is the collector's, not the warm-up's
                done.add(key)
                out.append((spec, argv, key, every))
        for words in WARM:
            hit = self.resolve(list(words), {})
            if hit:
                add(hit[0], hit[1], hit[0]["ttl"])
        now = time.time()
        with self.lock:
            seen = sorted(self.seen.values(), key=lambda v: -v[2])
        for spec, argv, when in seen:
            if now - when < self.cfg.seen_for:
                add(spec, list(argv), spec["ttl"])
        if self.cfg.warm_all:
            ext_refresh()
            for words, spec in list(READS.items()):
                if not spec.get("args"):
                    add(spec, list(words), max(spec["ttl"], self.cfg.warm_idle_ttl))
        return out

    @staticmethod
    def _shape(spec, rc, out):
        if rc != 0 and not out.strip():
            return 502, {"error": "The server could not answer this (exit %d)." % rc, "rc": rc}
        if spec["kind"] == "json":
            try:
                return 200, json.loads(out)
            except ValueError:
                return 502, {"error": "The answer was not JSON.", "rc": rc}
        if spec["kind"] == "text":
            return 200, {"text": out, "rc": rc}
        return 200, {"rows": [line.split("\t") for line in out.splitlines() if line != ""], "rc": rc}


_COLLECTED = None


def collected_keys():
    """the reads the collector keeps (scripts/lib/collected-reads.tsv: the words, TAB, seconds), read once"""
    global _COLLECTED
    if _COLLECTED is None:
        path = env("HS_COLLECTED_FILE", os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib", "collected-reads.tsv"))
        keys = set()
        try:
            with open(path, encoding="utf-8") as f:
                for line in f:
                    if line.strip() and not line.startswith("#"):
                        keys.add(line.split("\t")[0].strip())
        except OSError:
            pass
        _COLLECTED = keys
    return _COLLECTED


# What the pages need first after sign-in; read again about every ttl while somebody is using the interface (see Warmer).
WARM = [("status",), ("deck",), ("monitor", "disks"), ("ct", "list"), ("shares", "overview"), ("users", "list"), ("users", "groups"),
        ("backup", "overview"), ("backup", "state"), ("pool", "info"), ("health", "next"), ("unifi", "used"), ("unifi", "reserved"),
        ("vault", "list"), ("jobs", "running"), ("disk-health", "list"), ("cache", "state")]


class Warmer:
    """Keeps the common reads warm while a session was seen lately, one after the other with a small pause, so the first click is already cached.
    No session lately, or storage locked: it does nothing."""

    def __init__(self, app):
        self.app, self.wake, self.stop_flag = app, threading.Event(), False

    def active(self):
        return time.time() - self.app.sessions.last_seen() < self.app.cfg.warm_active and not self.app.auth.storage_locked()

    def once(self):
        """One round; returns how many reads were run."""
        n = 0
        for spec, argv, key, every in self.app.reads.warm_targets():
            if self.stop_flag or not self.active():
                break
            age = self.app.reads.age(key)
            if age is None or age >= every:
                self.app.reads.fetch(spec, argv, key)
                n += 1
                time.sleep(self.app.cfg.warm_pause)
        return n

    def loop(self):
        while not self.stop_flag:
            try:
                if self.active():
                    self.once()
                self.app.reads.save(self.app.cfg.cache_file)
            except Exception:
                pass
            self.wake.wait(3)
            self.wake.clear()

    def start(self):
        threading.Thread(target=self.loop, daemon=True).start()


# ─────────────────────────── HTTP ───────────────────────────
CSP = ("default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; "
       "connect-src {connect}; base-uri 'none'; form-action 'self'; frame-ancestors 'none'")
COOKIE = "hs_session"


UNLOCK_LOCK = threading.Lock()
UNLOCK_NOT_RUN = "The unlock could not be run (or took longer than three minutes). Try `hs unlock` on the server."


def parse_unlock(rc, out, passphrase):
    """(status, reason) from the exit code and plain output of `hs sys unlock stdin`. The reason never holds the passphrase."""
    if rc == 0:
        return "ok", "Unlocked. The services are starting."
    text = out.replace(passphrase, "***") if passphrase else out
    low = text.lower()
    if rc == 127:
        return "failed", UNLOCK_NOT_RUN
    if "opens nothing" in low or "not the passphrase" in low or "did not accept" in low or "vault did not open" in low:
        return "failed", "Wrong passphrase."
    if "still locked" in low:
        return "failed", "Some disks stayed locked. Check them with `hs unlock --status` on the server."
    return "failed", "Unlocking failed. Check `hs unlock --status` on the server."




class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


class Proxy:
    """The VPS status document (kind proxyserver), fetched from the one configured URL, cached for a few seconds."""
    MAX = 256 * 1024

    def __init__(self, cfg):
        self.cfg, self.lock, self.at, self.value = cfg, threading.Lock(), 0, None

    def get(self):
        url = self.cfg.proxy_url
        if not re.match(r"^https?://", url or ""):
            return 404, {"error": "not configured"}
        with self.lock:
            if self.value and time.time() - self.at < self.cfg.proxy_ttl:
                return self.value
            self.value = self._fetch(url)
            self.at = time.time()
            return self.value

    def _fetch(self, url):
        try:
            opener = urllib.request.build_opener(_NoRedirect)
            with opener.open(urllib.request.Request(url, headers={"Accept": "application/json"}), timeout=self.cfg.proxy_timeout) as r:
                raw = r.read(self.MAX + 1)
            if len(raw) > self.MAX:
                return 502, {"error": "answer too big"}
            doc = json.loads(raw.decode("utf-8"))
            if not isinstance(doc, dict):
                return 502, {"error": "not a status document"}
            return 200, doc
        except Exception as e:
            return 502, {"error": "not reachable" if isinstance(e, (urllib.error.URLError, OSError)) else "not a status document"}


class StateStore:
    """Where the web gets a read from. The interface (the web asks only these three):
    get(spec, argv, key, fresh) -> (code, object, age in seconds or None, extra headers as a tuple of (name, value))
    subscribe(callback)         -> callback(topic, gen) is called when a topic changed (modes without push do nothing)
    request(topic)              -> ask for a new reading of the topic ("*": all); fire and forget"""

    def get(self, spec, argv, key, fresh=False):
        raise NotImplementedError

    def subscribe(self, callback):
        pass

    def request(self, topic):
        pass


class OffStore(StateStore):
    """Mode off: the direct read with the short cache (Reads.get_aged), as before live-state existed."""

    def __init__(self, reads):
        self.reads = reads

    def get(self, spec, argv, key, fresh=False):
        code, obj, age = self.reads.get_aged(spec, argv, key, fresh=fresh)
        return code, obj, age, ()


class RedisStore(StateStore):
    """Mode redis: a read with a topic is the key hs:v1:<topic> (raw text, parsed here by Reads._shape); no process is started. A read without a
    topic is the old path (OffStore). Redis not answering is a 503, never a silent fallback."""
    FRESH_WAIT = 10.0      # ?fresh=1: seconds to wait for the collector's new reading

    def __init__(self, cfg, reads):
        self.cfg, self.off = cfg, OffStore(reads)

    def _doc(self, topic):
        """-> the stored document or None (key missing); OSError when Redis does not answer"""
        r = ls.Resp(self.cfg.live_socket, timeout=1.0)
        try:
            raw = r.cmd("GET", ls.KEY % topic)
        finally:
            r.close()
        try:
            doc = json.loads(raw) if raw is not None else None
        except ValueError:
            doc = None
        return doc if isinstance(doc, dict) else None

    def get(self, spec, argv, key, fresh=False):
        topic = spec.get("topic")
        if not topic:
            return self.off.get(spec, argv, key, fresh=fresh)
        try:
            doc = self._doc(topic)
            if fresh:
                old = int((doc or {}).get("gen") or 0)
                self.request(topic)
                end = time.time() + self.FRESH_WAIT
                while time.time() < end:
                    time.sleep(0.2)
                    new = self._doc(topic)
                    if new is not None and int(new.get("gen") or 0) > old:
                        doc = new
                        break
        except OSError:
            return 503, {"error": "state service down", "hint": "systemctl status redis-hobnix hs-live"}, None, ()
        if doc is None:
            self.request(topic)
            return 503, {"error": "refreshing", "retry_after": 2}, None, (("Retry-After", "2"),)
        try:
            ts = float(doc.get("ts") or 0)
            code, obj = Reads._shape(spec, int(doc.get("rc") or 0), str(doc.get("out") or ""))
        except (TypeError, ValueError):
            return 502, {"error": "The stored answer is not readable."}, None, ()
        more = ()
        try:
            if doc.get("err") and float(doc.get("ts_err") or 0) > ts:
                more = (("X-HS-Stale", str(int(float(doc["ts_err"])))),)
        except (TypeError, ValueError):
            pass
        return code, obj, max(0.0, time.time() - ts), more

    def request(self, topic):
        try:
            r = ls.Resp(self.cfg.live_socket, timeout=1.0)
            try:
                r.cmd("PUBLISH", ls.REFRESH, topic)
            finally:
                r.close()
        except OSError:
            pass


class Events:
    """The hub behind /api/events: one thread follows hs:v1:changed (mode redis) and hands every message to each open stream. A stream is a
    queue of ("changed", topic, gen) | ("down",) | ("up",). feed() is also how tests push a message."""

    def __init__(self, cfg):
        self.cfg, self.lock, self.queues = cfg, threading.Lock(), set()

    def add(self):
        q = queue.Queue(maxsize=256)
        with self.lock:
            self.queues.add(q)
        return q

    def remove(self, q):
        with self.lock:
            self.queues.discard(q)

    def feed(self, *item):
        with self.lock:
            targets = list(self.queues)
        for q in targets:
            try:
                q.put_nowait(item)
            except queue.Full:
                pass         # the hub never blocks on a slow stream

    def start(self):
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        up, wait = False, 1
        while True:
            began = time.time()
            try:
                r = ls.Resp(self.cfg.live_socket, timeout=1.0)
                try:
                    for _, msg in r.subscribe(ls.CHANGED):
                        wait = 1
                        if not up:
                            up = True
                            self.announce()
                        topic, _, gen = msg.partition(" ")
                        if topic:
                            self.feed("changed", topic, int(gen) if gen.isdigit() else 0)
                finally:
                    r.close()
            except (OSError, ValueError):
                pass
            if up:
                self.feed("down")
            up = False
            if time.time() - began > 10:      # the subscription held for a while: start the backoff again
                wait = 1
            self.sleep(wait)
            wait = min(wait * 2, 30)

    def sleep(self, seconds):
        time.sleep(seconds)

    def announce(self):
        """After a (re)connect: `up`, then a `changed` for every known topic (its stored gen, 0 when unknown) so the pages read again."""
        self.feed("up")
        try:
            rows = ls.topics()
        except OSError:
            rows = []
        for row in rows:
            self.feed("changed", row[0], self.gen_of(row[0]))

    def gen_of(self, topic):
        try:
            r = ls.Resp(self.cfg.live_socket, timeout=1.0)
            try:
                doc = json.loads(r.cmd("GET", ls.KEY % topic) or "{}")
            finally:
                r.close()
            return int(doc.get("gen") or 0)
        except (OSError, ValueError, TypeError, AttributeError):
            return 0


class ChangesSeen:
    """The last revision of the changelog each web user has seen (What's new): {user: 40 hex}. Kept in a file of the state folder, 0600."""
    def __init__(self, cfg):
        self.path, self.lock, self.data = cfg.changes_seen_file, threading.Lock(), {}
        try:
            with open(self.path, encoding="utf-8") as f:
                d = json.load(f)
            if isinstance(d, dict):
                self.data = {str(k): v for k, v in d.items() if isinstance(v, str) and re.fullmatch(r"[0-9a-f]{40}", v)}
        except (OSError, ValueError):
            pass

    def get(self, user):
        with self.lock:
            return self.data.get(str(user), "")

    def set(self, user, rev):
        with self.lock:
            self.data[str(user)] = rev
            if not self.path:
                return
            tmp = self.path + ".tmp"
            try:
                fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                with os.fdopen(fd, "w", encoding="utf-8") as f:
                    json.dump(self.data, f)
                os.replace(tmp, self.path)
            except OSError:
                pass


class App:
    def __init__(self, cfg=None, auth=None):
        self.cfg = cfg or Config()
        self.auth = auth or Auth(self.cfg)
        self.sessions, self.throttle, self.facts, self.reads = Sessions(self.cfg), Throttle(), Facts(self.cfg), Reads(self.cfg)
        self.plans = Plans(self.cfg.plan_ttl)
        self.changes_seen = ChangesSeen(self.cfg)
        self.reads.on_clear = self.plans.clear
        self.store = RedisStore(self.cfg, self.reads) if self.cfg.live == "redis" else OffStore(self.reads)
        self.events = Events(self.cfg)       # started by main() in mode redis
        self.proxy = Proxy(self.cfg)
        self.warmer = Warmer(self)       # started by main(), not here
        self.terminals = wt.Terminals()
        self.stream_lock, self.streams, self.event_streams = threading.Lock(), 0, 0
        self.term_spawn = lambda target, name=None: wt.pty_spawn(target, self.cfg.local_user, name=name)      # tests replace this with a fake


def make_handler(app):
    cfg = app.cfg

    class Handler(http.server.BaseHTTPRequestHandler):
        server_version = "hs-web"
        sys_version = ""
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):      # journal gets one line per request, without cookies or bodies
            if os.environ.get("HS_WEB_QUIET") != "1":
                super().log_message(fmt, *args)

        # --- helpers
        def _headers(self, code, ctype, length, extra=()):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            if length is not None:
                self.send_header("Content-Length", str(length))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            # connect-src also names the websocket of this very host (the browser terminal), only when the Host header is a plain host[:port]
            self.send_header("Content-Security-Policy", CSP.format(connect=wt.csp_connect(self.headers.get("Host", ""), self._https()) if cfg.terminal else "'self'"))
            if self._https():
                self.send_header("Strict-Transport-Security", "max-age=31536000")
            for k, v in extra:
                self.send_header(k, v)
            self.end_headers()

        def _json(self, code, obj, extra=()):
            data = json.dumps(obj).encode()
            self._headers(code, "application/json", len(data), extra)
            if self.command != "HEAD":
                self.wfile.write(data)

        def _token(self):
            for part in self.headers.get("Cookie", "").split(";"):
                k, _, v = part.strip().partition("=")
                if k == COOKIE:
                    return v
            return ""

        def _session(self):
            return app.sessions.get(self._token(), app.auth.storage_locked())

        def _same_origin(self):
            origin = self.headers.get("Origin", "")
            host = self.headers.get("Host", "")
            return bool(origin) and bool(host) and urllib.parse.urlsplit(origin).netloc == host

        def _read(self, limit=4096):
            # The body is always read (keep-alive: an unread body would be taken for the next request). Too big = close.
            try:
                n = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                n = -1
            if n < 0 or n > limit:
                self.close_connection = True
                return None
            return self.rfile.read(n)

        def _json_body(self, raw):
            if raw is None or self.headers.get("Content-Type", "").split(";")[0].strip() != "application/json":
                return None
            try:
                obj = json.loads(raw or b"{}")
            except ValueError:
                return None
            return obj if isinstance(obj, dict) else None

        def _cookie(self, token, max_age):
            return ("Set-Cookie", "%s=%s; Path=/; HttpOnly; SameSite=Strict; Max-Age=%d%s" % (COOKIE, token, max_age, "; Secure" if self._https() else ""))

        def _https(self):
            """True for a request that came through `tailscale serve` (HTTPS ends there): it connects from this machine itself. A request straight from the home network
            (webLan) is plain HTTP, and a Secure cookie or HSTS would make the browser drop the login there."""
            return cfg.secure and self.client_address[0] in ("127.0.0.1", "::1")

        def _client(self):
            """The address the throttle counts. Behind the local proxy (tailscale serve) every request comes from 127.0.0.1: then the proxy's X-Forwarded-For names the client."""
            ip = self.client_address[0]
            if cfg.trust_proxy and ip in ("127.0.0.1", "::1"):
                fwd = self.headers.get("X-Forwarded-For", "").split(",")[0].strip()
                if re.fullmatch(r"[0-9a-fA-F:.]{3,45}", fwd):
                    return fwd
            return ip

        # --- GET
        def do_HEAD(self):
            self.do_GET()

        def do_GET(self):
            path = urllib.parse.urlsplit(self.path).path
            if path == "/api/hello":
                return self._hello()
            if path == "/api/terminal/ws":
                return self._terminal_ws(urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query))
            if path == "/api/session":
                s = self._session()
                if not s:
                    return self._json(401, {"error": "not signed in"})
                return self._json(200, {"user": s["user"], "realm": s["realm"], "csrf": s["csrf"], "features": features(cfg)})
            if path == "/theme.css":
                data = theme_css(cfg.accent).encode()
                self._headers(200, "text/css; charset=utf-8", len(data), (("Cache-Control", "no-cache"),))
                if self.command != "HEAD":
                    self.wfile.write(data)
                return
            if path == "/favicon.svg":
                data = favicon_svg(cfg.accent).encode()
                self._headers(200, "image/svg+xml", len(data), (("Cache-Control", "no-cache"),))
                if self.command != "HEAD":
                    self.wfile.write(data)
                return
            if path == "/api/proxy/status":
                if not self._session():
                    return self._json(401, {"error": "not signed in"})
                code, obj = app.proxy.get()
                return self._json(code, obj)
            if path.startswith("/api/poster/"):
                return self._poster(urllib.parse.unquote(path[len("/api/poster/"):]))
            if path.startswith("/api/docs/"):
                return self._docs(path[len("/api/docs/"):], urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query))
            if path == "/api/changes/seen":
                s = self._session()
                if not s:
                    return self._json(401, {"error": "not signed in"})
                return self._json(200, {"rev": app.changes_seen.get(s["user"])})
            if path == "/api/board":
                return self._board()
            if path == "/api/events":
                return self._events()
            if path.startswith("/api/sys/jobs/stream/"):
                return self._jobs_stream(urllib.parse.unquote(path[len("/api/sys/jobs/stream/"):]), urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query))
            if path.startswith("/api/sys/"):
                return self._sys(path, urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query))
            if path.startswith("/api/"):
                return self._json(404, {"error": "unknown"})
            return self._static(path)

        def _poster(self, name):
            """one picture of $HS_STATE_DIR/posters; the name is checked and the real path must stay in the folder"""
            if not self._session():
                return self._json(401, {"error": "not signed in"})
            if not re.fullmatch(r"poster-[A-Za-z0-9._-]{1,120}\.png", name) or ".." in name:
                return self._json(404, {"error": "no such poster"})
            root = os.path.realpath(env("HS_POSTER_DIR", os.path.join(env("HS_STATE_DIR", "/var/lib/hs"), "posters")))
            full = os.path.realpath(os.path.join(root, name))
            if not (full.startswith(root + os.sep) and os.path.isfile(full)):
                return self._json(404, {"error": "no such poster"})
            with open(full, "rb") as f:
                data = f.read()
            self._headers(200, "image/png", len(data), (("Content-Disposition", 'inline; filename="%s"' % name), ("Cache-Control", "private, max-age=300")))
            if self.command != "HEAD":
                self.wfile.write(data)

        def _docs(self, rest, query):
            """the guides: index.json, one page as Markdown, or a search. Only while the capability docs is on."""
            if not self._session():
                return self._json(401, {"error": "not signed in"})
            if "docs" not in capabilities():
                return self._json(404, {"error": "the documentation page is switched off"})
            if rest == "index":
                data = docs_read("index.json")
                if data is None:
                    return self._json(404, {"error": "not built", "hint": "hs docs build"})
                self._headers(200, "application/json", len(data), (("Cache-Control", "no-cache"),))
                if self.command != "HEAD":
                    self.wfile.write(data)
                return
            parts = [urllib.parse.unquote(x) for x in rest.split("/")]
            if len(parts) == 3 and parts[0] == "page" and DOCS_LANG.match(parts[1]) and DOCS_SLUG.match(parts[2]):
                data = docs_read(f"{parts[1]}/{parts[2]}.md")
                if data is None:
                    return self._json(404, {"error": "no such page"})
                self._headers(200, "text/markdown; charset=utf-8", len(data), (("Cache-Control", "no-cache"),))
                if self.command != "HEAD":
                    self.wfile.write(data)
                return
            if rest == "search":
                lang = (query.get("lang") or [""])[0]
                if lang and not DOCS_LANG.match(lang):
                    lang = ""
                return self._json(200, {"hits": docs_search((query.get("q") or [""])[0], lang)})
            return self._json(404, {"error": "unknown"})

        def _sys(self, path, query):
            if not self._session():
                return self._json(401, {"error": "not signed in"})
            fresh = bool(query.pop("fresh", None))      # ?fresh=1: the refresh button of a page (not part of the allowlisted query)
            hit = app.reads.resolve([urllib.parse.unquote(x) for x in path[len("/api/sys/"):].split("/") if x], query)
            if hit is None:
                return self._json(404, {"error": "unknown"})
            code, obj, age, more = app.store.get(*hit, fresh=fresh)
            self._json(code, obj, extra=((("X-HS-Age", str(int(age))),) if age is not None else ()) + tuple(more))

        def _board(self):
            """The dashboard tiles for the page /dashboard and the Services page. Only while the dashboard variant is web. A session always works;
            without one the setting dashboardOpen, a private client address and a Host header that names this server are needed."""
            if runtime_setting("dashboard") != "web" or "dashboard" not in capabilities():
                return self._json(404, {"error": "the dashboard is not the web one"})
            if not self._session():
                if (runtime_setting("dashboardOpen") or "").lower() != "true":
                    return self._json(403, {"error": "open dashboard is off: hs config set dashboardOpen true"})
                if not private_client(self._client()):
                    return self._json(403, {"error": "only from the home network or Tailscale"})
                if not board_host_ok(self.headers.get("Host", "")):
                    return self._json(403, {"error": "unknown host name"})
            if app.auth.storage_locked():
                return self._json(200, {"schema": 1, "locked": True, "tiles": [], "incus_ui": False})
            ages, rows = [], {}
            for words in (("services", "tiles"), ("services", "stats")):
                hit = app.reads.resolve(list(words), {})
                if hit is None:
                    rows[words] = []
                    continue
                code, obj, age = app.reads.get_aged(*hit)
                rows[words] = obj.get("rows", []) if code == 200 and isinstance(obj, dict) else []
                if age is not None:
                    ages.append(int(age))
            tiles = []
            for r in rows[("services", "tiles")]:
                r = list(r) + [""] * (6 - len(r))
                group, title, link, desc, icon, name = r[:6]
                tiles.append({"service": name if name != "-" else "", "group": group if group != "-" else "Other", "title": title, "href": link,
                              "description": "" if desc == "-" else desc, "icon": "" if icon == "-" else icon, "stats": []})
            by = {t["service"]: t for t in tiles if t["service"]}
            for r in rows[("services", "stats")]:        # service, index, label, state, value, unit (hs sys services stats); only ok ones
                r = list(r) + [""] * (6 - len(r))
                if r[3] == "ok" and r[0] in by and len(by[r[0]]["stats"]) < 3:
                    by[r[0]]["stats"].append({"label": r[2], "value": r[4], "unit": "" if r[5] == "-" else r[5]})
            try:
                with open(env("HS_INCUS_UI_FILE", "/etc/hs/incus-ui"), encoding="utf-8") as f:
                    incus_ui = f.readline().strip() == "on"
            except OSError:
                incus_ui = True
            self._json(200, {"schema": 1, "locked": False, "age": max(ages) if ages else None, "incus_ui": incus_ui, "tiles": tiles})

        def _jobs_stream(self, unit, query):
            """Server-sent events for one job: the same `hs sys jobs tail` rows as the read, pushed as they appear, ended when the unit ends.
            One thread per stream (at most cfg.stream_max); the page falls back to polling the read when this answers anything but 200."""
            s = self._session()
            if not s:
                return self._json(401, {"error": "not signed in"})
            frm = (query.get("from") or ["0"])[0]
            if not re.fullmatch(UNIT, unit) or not re.fullmatch(r"[0-9]{1,7}", frm):
                return self._json(404, {"error": "unknown"})
            with app.stream_lock:
                if app.streams >= cfg.stream_max:
                    return self._json(503, {"error": "too many open streams"})
                app.streams += 1
            try:
                self.close_connection = True
                self._headers(200, "text/event-stream", None, (("Connection", "close"), ("X-Accel-Buffering", "no")))
                self.wfile.write(b"retry: 3000\n\n")
                self.wfile.flush()
                nxt, gone, quiet, first, last, t0 = int(frm), 0, 0, True, None, time.time()
                while time.time() - t0 < cfg.stream_hours * 3600:
                    if not app.sessions.get(self._token(), app.auth.storage_locked()):
                        break                                               # signed out, expired or locked: ends like the polling would (401)
                    rc, out = _run([cfg.hs, "sys", "jobs", "tail", unit, str(nxt)], timeout=30)
                    rows = [line.split("\t") for line in out.splitlines() if line != ""]
                    if rc != 0 and not rows:
                        gone += 1
                        state = "unknown"
                    else:
                        state = next((r[1] for r in rows if r[0] == "state" and len(r) > 1), "unknown")
                        nxt = next((int(r[1]) for r in rows if r[0] == "next" and len(r) > 1 and r[1].isdigit()), nxt)
                        gone = gone + 1 if state == "unknown" else 0
                    news = first or state != last or any(r[0] in ("line", "exit") for r in rows)
                    if news:
                        self.wfile.write(b"data: " + json.dumps({"rows": rows}).encode() + b"\n\n")
                        quiet = 0
                    else:
                        quiet += 1
                        if quiet % 15 == 0:
                            self.wfile.write(b": ping\n\n")                # keeps proxies from closing an idle stream
                    self.wfile.flush()
                    first, last = False, state
                    if state in ("ok", "failed") or (state == "unknown" and gone >= 4):
                        break
                    time.sleep(cfg.stream_every)
                self.wfile.write(b"event: end\ndata: {}\n\n")
                self.wfile.flush()
            except (OSError, ValueError):
                pass                                                         # the browser went away
            finally:
                with app.stream_lock:
                    app.streams -= 1

        def _events(self):
            """Server-sent events for the live state: `changed` {topic, gen} when the collector read a topic again, `down` / `up` when Redis goes
            or comes back. One thread per stream (at most cfg.events_max). The page reads the topic again when `changed` arrives."""
            if not self._session():
                return self._json(401, {"error": "not signed in"})
            if self.headers.get("Origin") and not self._same_origin():
                return self._json(403, {"error": "origin"})
            if cfg.live != "redis":
                return self._json(404, {"error": "live state is off"})
            with app.stream_lock:
                if app.event_streams >= cfg.events_max:
                    return self._json(503, {"error": "too many open streams"})
                app.event_streams += 1
            q = app.events.add()
            try:
                self.close_connection = True
                self._headers(200, "text/event-stream", None, (("Cache-Control", "no-cache"), ("Connection", "close"), ("X-Accel-Buffering", "no")))
                self.wfile.write(b"retry: 3000\n\n")
                self.wfile.flush()
                t0 = time.time()
                while time.time() - t0 < cfg.stream_hours * 3600:
                    try:
                        item = q.get(timeout=cfg.events_ping)
                    except queue.Empty:
                        item = None
                    if not app.sessions.get(self._token(), app.auth.storage_locked()):
                        break                                               # signed out, expired or locked
                    if item is None:
                        self.wfile.write(b": ping\n\n")                      # keeps proxies from closing an idle stream
                    elif item[0] == "changed":
                        self.wfile.write(b"event: changed\ndata: " + json.dumps({"topic": item[1], "gen": item[2]}).encode() + b"\n\n")
                    else:
                        self.wfile.write(b"event: " + item[0].encode() + b"\ndata: {}\n\n")
                    self.wfile.flush()
            except (OSError, ValueError):
                pass                                                         # the browser went away
            finally:
                app.events.remove(q)
                with app.stream_lock:
                    app.event_streams -= 1

        def _hello_static(self):
            """What the sign-in page needs to draw itself at once (no facts: those are read from the server)."""
            locked = app.auth.storage_locked()
            domain = bool(cfg.workgroup)
            return {
                "locked": locked,
                "domain": {"available": domain and not locked, "workgroup": cfg.workgroup, "realm": cfg.realm} if domain else None,
                "local_user": cfg.local_user,
            }

        def _hello(self):
            d = self._hello_static()
            d["facts"] = app.facts.get(d["locked"])
            self._json(200, d)

        def _static(self, path):
            root = os.path.realpath(cfg.root)
            rel = urllib.parse.unquote(path).lstrip("/")
            full = os.path.realpath(os.path.join(root, rel))
            if not (full.startswith(root + os.sep) and os.path.isfile(full)):
                if "." in os.path.basename(rel) or rel.startswith("assets/"):   # a missing file is a 404, not the app
                    return self._json(404, {"error": "not found"})
                full = os.path.join(root, "index.html")
                if not os.path.isfile(full):
                    return self._json(404, {"error": "the frontend is not built"})
            ctype = mimetypes.guess_type(full)[0] or "application/octet-stream"
            if ctype.startswith("text/") or ctype in ("application/javascript", "image/svg+xml"):
                ctype += "; charset=utf-8"
            with open(full, "rb") as f:
                data = f.read()
            if os.path.basename(full) == "index.html":
                # the sign-in page knows the realm and the lock state before its first request answers: nothing jumps into place afterwards
                tag = b'<meta name="hs-hello" content="' + html.escape(json.dumps(self._hello_static()), quote=True).encode() + b'">'
                data = re.sub(rb'<meta name="hs-hello" content=""\s*/?>', lambda m: tag, data, count=1)
            immutable = full.startswith(os.path.join(root, "assets") + os.sep)
            self._headers(200, ctype, len(data), (("Cache-Control", "public, max-age=31536000, immutable" if immutable else "no-cache"),))
            if self.command != "HEAD":
                self.wfile.write(data)

        # --- POST
        def do_POST(self):
            path = urllib.parse.urlsplit(self.path).path
            raw = self._read(FM_SELECTION_BYTES + 8192 if path in ("/api/plan", "/api/start") else 4096)      # a file manager selection can be long
            if path not in ("/api/login", "/api/logout", "/api/plan", "/api/start", "/api/unlock", "/api/terminal", "/api/changes/seen"):
                return self._json(404, {"error": "unknown"})
            if not self._same_origin():
                return self._json(403, {"error": "origin"})
            body = self._json_body(raw)
            if body is None:
                return self._json(400, {"error": "need a JSON body"})
            if path == "/api/unlock":
                return self._unlock(body)
            if path == "/api/terminal":
                return self._terminal_ticket(body)
            if path == "/api/changes/seen":
                return self._changes_seen(body)
            if path in ("/api/plan", "/api/start"):
                return self._change(path[len("/api/"):], body)
            if path == "/api/logout":
                s = self._session()
                if s and not secrets.compare_digest(self.headers.get("X-CSRF-Token", ""), s["csrf"]):
                    return self._json(403, {"error": "csrf"})
                app.sessions.drop(self._token())
                return self._json(200, {"ok": True}, (self._cookie("", 0),))
            return self._login(body)

        def _changes_seen(self, body):
            s = self._session()
            if not s:
                return self._json(401, {"error": "not signed in"})
            if not secrets.compare_digest(self.headers.get("X-CSRF-Token", ""), s["csrf"]):
                return self._json(403, {"error": "csrf"})
            rev = body.get("rev")
            if not isinstance(rev, str) or not re.fullmatch(r"[0-9a-f]{40}", rev):
                return self._json(400, {"error": "That revision is not allowed."})
            app.changes_seen.set(s["user"], rev)
            print("web changes seen: %s" % s["user"], flush=True)
            return self._json(200, {"ok": True})

        def _change(self, verb, body):
            s = self._session()
            if not s:
                return self._json(401, {"error": "not signed in"})
            if not secrets.compare_digest(self.headers.get("X-CSRF-Token", ""), s["csrf"]):
                return self._json(403, {"error": "csrf"})
            ch = validate_change(body)
            if ch is None:
                return self._json(400, {"error": "That change is not allowed."})
            area, args, confirm, stdin = ch
            cmd = [cfg.hs, "sys"] + area.split("/") + [verb] + args      # "ext/games" = the words `ext games` (an extension package)
            if verb == "start" and confirm:
                cmd += ["--confirm", confirm]
            if area == "fm" and verb == "start":
                cmd += ["--by", re.sub(r"[^A-Za-z0-9._@-]", "_", str(s["user"]))]       # who, for the audit log of the file manager
            if verb == "start":
                print("web change: %s: %s %s" % (s["user"], area, " ".join(args)), flush=True)   # never the stdin line
            data = (stdin if isinstance(stdin, bytes) else (stdin + chr(10)).encode()) if stdin is not None else None
            t0, shape = time.monotonic(), change_shape(area, args)
            if verb == "plan" and _run is _run_plain:
                key = (area, tuple(args)) if plan_cacheable(area, args, stdin) else None
                hit = app.plans.get(key) if key else None
                if hit is not None:
                    _timing("plan", shape, t0, "cached", None, hit["status"])
                    return self._json(200, hit)
                gen = app.plans.gen
                rc, out, how = _run_watched(cmd, stdin=data, timeout=60, gone=lambda: _client_gone(self.connection))
                if how == "gone":           # the browser asked something newer: no answer, the connection is closed
                    _timing("plan", shape, t0, how, None, None)
                    self.close_connection = True
                    return
                d = parse_change(out, rc)
                if key and how == "run" and plan_stable(out, rc, d):
                    app.plans.put(key, gen, d)
                _timing("plan", shape, t0, how, rc, d["status"])
                return self._json(200, d)
            rc, out = _run(cmd, stdin=data, timeout=60)
            d = parse_change(out, rc)
            if verb == "start":
                app.reads.clear()      # what the pages show next is read again, not served from before the change (clears the plan cache too)
                app.store.request("*")      # mode redis: the collector reads every topic again (a no-op in mode off)
            _timing(verb, shape, t0, "run", rc, d["status"])
            self._json(200, d)

        # --- browser terminal (outside the READS/CHANGES allowlists on purpose; scripts/web_terminal.py)
        def _terminal_ticket(self, body):
            s = self._session()
            if not s:
                return self._json(401, {"error": "not signed in"})
            if not secrets.compare_digest(self.headers.get("X-CSRF-Token", ""), s["csrf"]):
                return self._json(403, {"error": "csrf"})
            if not cfg.terminal:
                return self._json(403, {"error": "Switch on webTerminal in machine.toml."})
            target = body.get("target")
            if not wt.valid_target(target):
                return self._json(400, {"error": "That terminal is not allowed."})
            if target != "host" and app.auth.storage_locked():
                return self._json(409, {"error": "The storage is locked: instances are down. Unlock it first."})
            ticket = app.terminals.issue(self._token(), target)
            if ticket is None:
                return self._json(429, {"error": "Too many terminals are being opened. Try again in a moment."})
            self._json(200, {"ticket": ticket})

        def _term_alive(self, token, target):
            """Is the web session still good? Does not refresh it: an open terminal must not keep a session alive."""
            locked = app.auth.storage_locked()
            if target != "host" and locked:
                return False
            with app.sessions.lock:
                s, now = app.sessions._find(token), time.time()
                return bool(s) and not (now - s["seen"] > cfg.idle or now - s["created"] > cfg.max_age or (locked and s["realm"] == "domain"))

        def _terminal_ws(self, query):
            self.close_connection = True
            if not cfg.terminal:
                return self._json(403, {"error": "Switch on webTerminal in machine.toml."})
            if not self._same_origin():
                return self._json(403, {"error": "origin"})
            h = self.headers
            if h.get("Upgrade", "").lower() != "websocket" or "upgrade" not in h.get("Connection", "").lower()                     or h.get("Sec-WebSocket-Version", "") != "13" or not wt.valid_key(h.get("Sec-WebSocket-Key", "")):
                return self._json(400, {"error": "need a WebSocket upgrade"})
            token = self._token()
            s = self._session()
            target = app.terminals.redeem((query.get("ticket") or [""])[0], token) if s else None
            if not s or target is None:
                return self._json(403, {"error": "ticket"})
            if target != "host" and app.auth.storage_locked():
                return self._json(409, {"error": "The storage is locked."})
            if not app.terminals.acquire(token):
                return self._json(429, {"error": "Too many terminals are open."})
            ip = self._client()
            try:
                sess = wt.TerminalSession(self.connection, lambda: app.term_spawn(target, wt.session_name(s["user"], target)), lambda: self._term_alive(token, target),
                                          idle=cfg.term_idle, lifetime=cfg.term_max, check=cfg.term_check)
                try:
                    sess.open()
                except Exception as e:
                    print("web terminal: could not start for %s %s: %s" % (s["user"], target, e.__class__.__name__), flush=True)
                    return self._json(500, {"error": "The terminal could not be started."})
                self.wfile.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                                  "Sec-WebSocket-Accept: %s\r\n\r\n" % wt.accept_key(h["Sec-WebSocket-Key"])).encode("ascii"))
                self.wfile.flush()
                print("web terminal: open %s %s from %s" % (s["user"], target, ip), flush=True)
                why = "error"
                try:
                    why = sess.run()
                finally:
                    sess.close()
                    print("web terminal: close %s %s from %s (%s)" % (s["user"], target, ip, why), flush=True)
            finally:
                app.terminals.release(token)

        def _unlock(self, body):
            s = self._session()
            if not s:
                return self._json(401, {"error": "not signed in"})
            if not secrets.compare_digest(self.headers.get("X-CSRF-Token", ""), s["csrf"]):
                return self._json(403, {"error": "csrf"})
            pw = body.get("passphrase")
            if not isinstance(pw, str) or not pw or len(pw) > 256 or any(ord(c) < 32 or ord(c) == 127 for c in pw):
                return self._json(400, {"status": "failed", "reason": "Enter the passphrase (one line, up to 256 characters)."})
            ip = self.client_address[0]
            keys = ("unlock-ip:" + ip, "unlock")
            wait = app.throttle.wait(*keys)
            if wait:
                return self._json(429, {"status": "failed", "reason": "Too many tries. Wait %d seconds." % wait, "retry_after": wait}, (("Retry-After", str(wait)),))
            if not app.auth.storage_locked():
                return self._json(409, {"status": "failed", "reason": "The storage is not locked."})
            if not UNLOCK_LOCK.acquire(blocking=False):
                return self._json(409, {"status": "busy", "reason": "An unlock is already running."})
            try:
                # hs-web has its own mount namespace (PrivateTmp): a vault mounted from in here would exist only in here, the disks (mapper
                # devices) open for everybody but the host would still see a closed vault. So the unlock runs in a transient unit of its own.
                cmd = [cfg.hs, "sys", "unlock", "stdin"]
                if cfg.unlock_in_unit:
                    cmd = [shutil.which("systemd-run") or "/run/current-system/sw/bin/systemd-run", "--quiet", "--pipe", "--collect", "--wait",
                           "--setenv=HS_CALLER=web", "--setenv=PATH=" + os.environ.get("PATH", "/run/current-system/sw/bin"),
                           "--"] + [shutil.which(cfg.hs) or cfg.hs] + cmd[1:]
                rc, out = _run(cmd, stdin=(pw + chr(10)).encode(), timeout=180)
            finally:
                UNLOCK_LOCK.release()
            status, reason = parse_unlock(rc, out, pw)
            app.plans.clear()      # a plan answered "locked" (or the reverse) must not be served again after this, whatever the outcome
            if status == "failed" and reason != UNLOCK_NOT_RUN:
                app.throttle.failed(*keys)
                time.sleep(cfg.fail_delay)
            elif status == "ok":
                app.throttle.ok(*keys)
            print("web unlock: %s from %s: %s" % (s["user"], ip, status), flush=True)   # never the passphrase or the script output
            self._json(200 if status == "ok" else 422 if status == "failed" else 409, {"status": status, "reason": reason})

        def _login(self, body):
            realm, user, password = body.get("realm"), body.get("user"), body.get("password")
            if realm not in ("domain", "local") or not isinstance(user, str) or not isinstance(password, str) \
                    or not USER_RE.fullmatch(user) or len(password) > 256:
                return self._json(400, {"error": "Enter a user name and a password."})
            ip = self._client()
            keys = ("ip:" + ip, "user:%s:%s" % (realm, user.lower()))
            wait = app.throttle.wait(*keys)
            if wait:
                return self._json(429, {"error": "Too many tries. Wait %d seconds." % wait, "retry_after": wait}, (("Retry-After", str(wait)),))

            def deny(message, code=401):
                app.throttle.failed(*keys)
                time.sleep(cfg.fail_delay)
                print("web login refused: %s %s from %s" % (realm, user, ip), flush=True)
                return self._json(code, {"error": message})

            locked = app.auth.storage_locked()
            if realm == "domain":
                if not cfg.workgroup or locked:
                    return self._json(409, {"error": "Domain sign-in is not available (the storage is locked, so dc1 is down). Use the local admin."})
                ok = app.auth.domain_password_ok(user, password)
                if ok is None:
                    return self._json(503, {"error": "The domain could not check the password right now. Try again, or sign in as the local admin (see the server log)."})
                if not ok:
                    return deny("Wrong user name or password.")
                if not app.auth.domain_is_admin(user):
                    return deny("Only members of %s can sign in." % cfg.admin_group, 403)
                name = "%s\\%s" % (cfg.workgroup, user.lower())
            else:
                if user != cfg.local_user:
                    return deny("Wrong user name or password.")
                if not app.auth.local_password_ok(user, password):
                    return deny("Wrong user name or password.")
                name = user
            app.throttle.ok(*keys)
            token = app.sessions.create(name, realm, ip)
            app.warmer.wake.set()
            s = app.sessions.get(token, locked)
            print("web login: %s from %s" % (name, ip), flush=True)
            self._json(200, {"user": name, "realm": realm, "csrf": s["csrf"], "features": features(cfg)}, (self._cookie(token, cfg.max_age),))

    return Handler


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    cfg = Config()
    if len(sys.argv) > 1:
        cfg.port = int(sys.argv[1])
    app = App(cfg)
    app.reads.load(cfg.cache_file)
    app.warmer.start()
    if cfg.live == "redis":
        app.events.start()
    server = Server((cfg.bind, cfg.port), make_handler(app))
    server.serve_forever()


if __name__ == "__main__":
    main()
