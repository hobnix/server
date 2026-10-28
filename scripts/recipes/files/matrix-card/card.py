"""Notification cards for the Matrix hook: 900x300 CSS pixels in the Nocturne look, drawn at 2x.

Pillow only. `render(spec)` returns PNG bytes. The layout is a port of the design in
"Arr Notification Cards" (Claude Design): poster (or an icon) on the left; service, event, title and a
row of facts on the right; a monospace footer. The halftone background is the design's halftone.js
(three soft blobs on a staggered dot grid), drawn fresh for every card.

spec keys (all optional but title):
  service   "radarr" | "sonarr" | "seerr"
  event     the event word, e.g. "Grabbed";  event_icon  a Phosphor icon name
  title, sub   the big title and the muted text after it (year, S01E03)
  fields    [(label, value), ...] the facts row (up to 4 fit)
  footer    one monospace line;  rename = (old, new) replaces the footer and the facts
  poster    image bytes (the poster);  icon  a Phosphor icon name shown instead of a poster
  time      "14:32"
"""
import io
import json
import math
import os
import random

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
FONTS = os.path.join(HERE, "fonts")
S = 2                      # pixels per CSS pixel: the PNG is 1800x600
SS = 2                     # extra supersampling for the dots and the rounded corners
W, H = 900, 300

BG = (0x16, 0x18, 0x26)
ACCENT = (0x91, 0x84, 0xd9)
SECTION = (0x26, 0x2a, 0x60)

TEXT = (0xe9, 0xe9, 0xed)
N200, N400, N500, N600 = (0xe4, 0xe7, 0xf5), (0xb2, 0xb6, 0xca), (0x93, 0x97, 0xab), (0x75, 0x79, 0x8c)
N700, N800, N900 = (0x59, 0x5d, 0x6c), (0x3f, 0x42, 0x4d), (0x29, 0x2b, 0x31)
A300, A400, A800, A900 = (0xd2, 0xce, 0xfd), (0xb5, 0xab, 0xfc), (0x42, 0x3a, 0x6a), (0x2b, 0x27, 0x41)
DIVIDER = (0xe9, 0xe9, 0xed, 0.16)

# The background of a service: the halftone dots and the soft glow in the top left corner. Sonarr keeps the
# design's own colours (indigo dots, the accent's glow); the others are the same thing in another hue, with
# the same relative luminance as the indigo (dots, glow, panel) and a little more saturation, and a pastel icon like Sonarr's lavender,
# so every card reads with the contrast of the Sonarr one.
PALETTES = {
    "sonarr": {"dots": SECTION, "glow": ACCENT, "panel": (A800, A900), "icon": A400},
    "radarr": {"dots": (0x3c, 0x2e, 0x0d), "glow": (0xb0, 0x89, 0x2f), "panel": ((0x4d, 0x3f, 0x1c), (0x32, 0x2a, 0x15)), "icon": (0xfc, 0xe4, 0xab)},   # yellow
    "seerr": {"dots": (0x4d, 0x14, 0x5f), "glow": (0xbf, 0x6f, 0xd9), "panel": ((0x5f, 0x29, 0x72), (0x3d, 0x1e, 0x47)), "icon": (0xe8, 0xab, 0xfc)},   # purple
    "maintainerr": {"dots": (0x0c, 0x36, 0x21), "glow": (0x2b, 0xa3, 0x67), "panel": ((0x1a, 0x49, 0x32), (0x14, 0x2f, 0x22)), "icon": (0xab, 0xfc, 0xd3)},   # green
    "sabnzbd": {"dots": (0x5e, 0x14, 0x1a), "glow": (0xd9, 0x6f, 0x78), "panel": ((0x70, 0x29, 0x2e), (0x46, 0x1e, 0x22)), "icon": (0xfc, 0xab, 0xb2)},   # red
}

TITLE_LS = -0.7           # letter spacing of the title in CSS pixels (-0.015em in the design, a little tighter for the heavier weight)
SERVICES = {"radarr": ("film-strip", "Radarr"), "sonarr": ("television-simple", "Sonarr"), "seerr": ("popcorn", "Seerr"),
            "maintainerr": ("trash", "Maintainerr (Script)"), "sabnzbd": ("download-simple", "Downloadarr")}

# geometry in CSS pixels (measured against the design's PNGs)
POSTER = (22, 22, 171, 256)        # x, y, w, h
X0 = 219                           # the text column
RIGHT = 870
BASE_HEADER, BASE_EVENT, BASE_TITLE = 39.5, 80.5, 124
BASE_LABEL, BASE_VALUE = 200, 224
FOOT_LINE, BASE_FOOT = 246, 271

_fonts = {}
_icons = None


def font(name, size):
    key = (name, size)
    if key not in _fonts:
        _fonts[key] = ImageFont.truetype(os.path.join(FONTS, name), int(round(size * S)))
    return _fonts[key]


# The design asks for Inter 400 and 500 as the browser draws them (variable font, stem darkening). The
# plain static files look thinner, so the strong text is drawn one weight up.
WEIGHTS = {"regular": "Inter-Regular.ttf", "medium": "Inter-Medium.ttf", "semibold": "Inter-SemiBold.ttf"}


def inter(size, weight="regular"):
    return font(WEIGHTS[weight], size)


def mono(size):
    for name in ("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", "C:/Windows/Fonts/consola.ttf", "DejaVuSansMono.ttf"):
        try:
            return ImageFont.truetype(name, int(round(size * S)))
        except OSError:
            continue
    return ImageFont.load_default()


def icon_code(name):
    global _icons
    if _icons is None:
        with open(os.path.join(FONTS, "icons.json")) as f:
            _icons = json.load(f)
    return _icons.get(name)


# ── text ──
def width(text, fnt, ls=0.0):
    return fnt.getlength(text) / S + ls * len(text)


def fit(text, fnt, maxw, ls=0.0):
    """The text, shortened with an ellipsis until it is at most maxw CSS pixels wide."""
    if width(text, fnt, ls) <= maxw:
        return text
    while text and width(text + "…", fnt, ls) > maxw:
        text = text[:-1]
    return text.rstrip() + "…"


def draw_text(d, x, base, text, fnt, fill, ls=0.0):
    """Text with its left edge at x and its baseline at base (CSS pixels); ls = letter spacing in CSS pixels."""
    if not ls:
        d.text((x * S, base * S), text, font=fnt, fill=fill, anchor="ls")
        return
    for i, ch in enumerate(text):
        d.text((x * S + fnt.getlength(text[:i]) + ls * S * i, base * S), ch, font=fnt, fill=fill, anchor="ls")


def draw_icon(d, cx, cy, name, size, fill):
    """A Phosphor icon centred on (cx, cy). Drawn twice, a hair apart: the browser's icons look heavier."""
    code = icon_code(name)
    if code:
        f = font("Phosphor.ttf", size)
        for dx, dy in ((0, 0), (0.5, 0.5)):
            d.text((cx * S + dx, cy * S + dy), chr(code), font=f, fill=fill, anchor="mm")


# ── backgrounds ──
def _grid(w, h, fn):
    """A small L image whose value at (x, y) is fn(x, y) (0..255), for resizing up smoothly."""
    im = Image.new("L", (w, h))
    im.putdata([max(0, min(255, int(fn(x + 0.5, y + 0.5)))) for y in range(h) for x in range(w)])
    return im


def background(glow=ACCENT):
    img = Image.new("RGB", (W * S, H * S), BG)
    gw, gh = 150, 50          # radial-gradient(70% 140% at 0 0, accent 14%, transparent 60%)

    def alpha(x, y):
        t = math.hypot(x / gw / 0.7, y / gh / 1.4)
        return 255 * 0.14 * max(0.0, 1 - t / 0.6)

    mask = _grid(gw, gh, alpha).resize(img.size, Image.BICUBIC)
    return Image.composite(Image.new("RGB", img.size, glow), img, mask)


def halftone(img, rnd, pitch=7, coverage=1.0, base=0.02, color=SECTION):
    """halftone.js: three soft blobs on a staggered grid of dots whose area follows the blobs."""
    blobs = []
    for _ in range(3):
        blobs.append((W * (0.15 + rnd.random() * 0.85), rnd.random() * H, 30 + rnd.random() * 50,
                      0.4 + rnd.random() * 0.45, 1.2 + rnd.random() * 1.2))
    k = S * SS
    mask = Image.new("L", (W * k, H * k), 0)
    d = ImageDraw.Draw(mask)
    half = pitch / 2
    row = 0
    y = 0.0
    while y < H + pitch:
        x = (row % 2) * half
        while x < W + pitch:
            f = base
            for bx, by, s, a, kk in blobs:
                dx, dy = (x - bx) / kk, y - by
                f += a * math.exp(-(dx * dx + dy * dy) / (2 * s * s))
            f = min(1.0, f * coverage)
            if f >= 0.02:
                r = pitch * 0.53 * math.sqrt(f) * k
                d.ellipse((x * k - r, y * k - r, x * k + r, y * k + r), fill=255)
            x += pitch
        y += half
        row += 1
    mask = mask.resize(img.size, Image.LANCZOS)
    img.paste(Image.new("RGB", img.size, color), (0, 0), mask)


def _rounded_mask(w, h, radius):
    k = S * SS
    m = Image.new("L", (w * k, h * k), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, w * k - 1, h * k - 1), radius=radius * k, fill=255)
    return m.resize((w * S, h * S), Image.LANCZOS)


def _poster_fill(w, h, icon, panel=(A800, A900)):
    """The panel without a poster: a 165deg gradient, or a radial one with an icon (health, updates)."""
    gw, gh = w // 4, h // 4
    if icon:
        def rad(x, y):
            t = math.hypot((x / gw - 0.5) / 0.9, (y / gh - 0.4) / 0.7)
            return 255 * min(1.0, t)
        m = _grid(gw, gh, rad).resize((w * S, h * S), Image.BICUBIC)
        return Image.composite(Image.new("RGB", m.size, panel[1]), Image.new("RGB", m.size, panel[0]), m)
    sin, cos = math.sin(math.radians(165)), -math.cos(math.radians(165))
    length = abs(w * sin) + abs(h * cos)

    def lin(x, y):
        return 255 * (((x * 4 - w / 2) * sin + (y * 4 - h / 2) * cos) / length + 0.5)
    m = _grid(gw, gh, lin).resize((w * S, h * S), Image.BICUBIC)
    return Image.composite(Image.new("RGB", m.size, N900), Image.new("RGB", m.size, N800), m)


def draw_poster(img, spec, palette):
    x, y, w, h = POSTER
    # box-shadow: 0 0 0 1px #595d6c, 0 6px 18px rgba(0,0,0,.55)
    shadow = Image.new("L", img.size, 0)
    ImageDraw.Draw(shadow).rounded_rectangle((x * S, (y + 6) * S, (x + w) * S, (y + 6 + h) * S), radius=8 * S, fill=int(255 * 0.55))
    shadow = shadow.filter(ImageFilter.GaussianBlur(9 * S))
    img.paste(Image.new("RGB", img.size, (0, 0, 0)), (0, 0), shadow)
    ring = Image.new("L", img.size, 0)
    ImageDraw.Draw(ring).rounded_rectangle(((x - 1) * S, (y - 1) * S, (x + w + 1) * S - 1, (y + h + 1) * S - 1), radius=9 * S, fill=255)
    img.paste(Image.new("RGB", img.size, N700), (0, 0), ring)
    panel = None
    if spec.get("poster"):
        try:
            p = Image.open(io.BytesIO(spec["poster"])).convert("RGB")
            scale = max(w * S / p.width, h * S / p.height)
            p = p.resize((max(1, round(p.width * scale)), max(1, round(p.height * scale))), Image.LANCZOS)
            left, top = (p.width - w * S) // 2, (p.height - h * S) // 2
            panel = p.crop((left, top, left + w * S, top + h * S))
        except Exception:
            panel = None
    if panel is None:
        panel = _poster_fill(w, h, spec.get("icon"), palette["panel"])
        if spec.get("icon"):
            d = ImageDraw.Draw(panel)
            d.text((w * S / 2, h * S * 0.5), chr(icon_code(spec["icon"]) or 0x20), font=font("Phosphor.ttf", 64), fill=palette["icon"], anchor="mm")
    img.paste(panel, (x * S, y * S), _rounded_mask(w, h, 8))


# ── the card ──
def render(spec, rnd=None):
    rnd = rnd or random.Random()
    palette = PALETTES.get(spec.get("service"), PALETTES["sonarr"])
    img = background(palette["glow"])
    halftone(img, rnd, color=palette["dots"])
    draw_poster(img, spec, palette)
    d = ImageDraw.Draw(img)

    # header: service, time
    sicon, sname = SERVICES.get(spec.get("service"), ("film-strip", ""))
    draw_icon(d, X0 + 8, 35.5, sicon, 16, N400)
    draw_text(d, X0 + 24, BASE_HEADER, sname.upper(), inter(12, "medium"), N400, ls=1.2)
    t = spec.get("time", "")
    draw_text(d, RIGHT - width(t, inter(12)) - 1.5, BASE_HEADER, t, inter(12), N500)

    # event
    if spec.get("event"):
        draw_icon(d, X0 + 9, 75, spec.get("event_icon", "download-simple"), 18, A300)
        draw_text(d, X0 + 26, BASE_EVENT, spec["event"], inter(15, "semibold"), A300)

    # title and the muted text after it
    avail = RIGHT - X0
    tf, sf = inter(32, "semibold"), inter(20)
    title, sub = spec.get("title", ""), spec.get("sub", "")
    if sub:
        sub_w = width(sub, sf)
        title = fit(title, tf, avail - 12 - sub_w, TITLE_LS)
    else:
        title = fit(title, tf, avail, TITLE_LS)
    draw_text(d, X0, BASE_TITLE, title, tf, TEXT, ls=TITLE_LS)
    if sub:
        draw_text(d, X0 + width(title, tf, TITLE_LS) + 12, BASE_TITLE, sub, sf, N500)

    if spec.get("rename"):
        old, new = spec["rename"]
        mf = mono(13)
        room = avail - 46
        for base, label, color, vcolor, text in ((248, "from", N600, N500, old), (271.5, "to", A400, N200, new)):
            draw_text(d, X0, base, label, mf, color)
            draw_text(d, X0 + 46, base, fit(text, mf, room), mf, vcolor)
        return _png(img)

    # the facts row: label above value, columns as wide as their widest cell
    fields = [(str(a), str(b)) for a, b in spec.get("fields", []) if b not in (None, "")][:4]
    lf, vm, vf = inter(11), inter(15), inter(15, "medium")   # measured light, drawn one weight up
    lh = inter(11, "medium")
    if fields:
        values = [v for _, v in fields]

        def widths():
            return [max(width(l.upper(), lf, 0.88), width(v, vm)) for (l, _), v in zip(fields, values)]
        while sum(widths()) + 32 * (len(fields) - 1) > avail:
            i = max(range(len(fields)), key=lambda j: widths()[j])
            if len(values[i]) < 4:
                break
            values[i] = fit(values[i], vm, widths()[i] - 12)
        x = X0
        for (label, _), value, w_ in zip(fields, values, widths()):
            draw_text(d, x, BASE_LABEL, label.upper(), lh, N500, ls=0.88)
            draw_text(d, x, BASE_VALUE, value, vf, N200)
            x += w_ + 32

    # footer: a faded rule and a monospace line
    if spec.get("footer"):
        mf = mono(12)
        rule = Image.new("L", (avail * S, S), 0)
        rd = rule.load()
        fade = 48 * S
        for px in range(rule.width):
            edge = min(px, rule.width - 1 - px)
            a = 1.0 if edge >= fade else edge / fade
            rd[px, 0] = int(255 * DIVIDER[3] * a)
        img.paste(Image.new("RGB", rule.size, DIVIDER[:3]), (X0 * S, FOOT_LINE * S), rule)
        d = ImageDraw.Draw(img)
        draw_text(d, X0, BASE_FOOT, fit(spec["footer"], mf, avail), mf, N500)
    return _png(img)


def _png(img):
    out = io.BytesIO()
    img.save(out, "PNG", optimize=True)
    return out.getvalue()


if __name__ == "__main__":
    import sys
    example = {"service": "radarr", "event": "Grabbed", "event_icon": "download-simple", "title": "Dune: Part Two", "sub": "2024",
               "fields": [("Quality", "2160p WEB-DL"), ("Size", "24.3 GB"), ("Indexer", "NZBgeek"), ("Client", "SABnzbd")],
               "footer": "Dune.Part.Two.2024.2160p.MAX.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-FLUX", "time": "14:32"}
    spec = json.load(open(sys.argv[1])) if len(sys.argv) > 1 else example
    sys.stdout.buffer.write(render(spec))
