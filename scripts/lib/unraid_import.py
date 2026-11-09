"""Unraid Community Apps template (XML) -> compose draft for `hs docker import` (scripts/import-unraid.sh). Standard library only.

  unraid_import.py <template.xml> [--name <app>]

Reads one template (<Container version="2">: Repository, Network, Privileged, WebUI, ExtraParams, PostArgs, Config Type=Port|Path|Variable|
Device|Label) and prints JSON on stdout: {"name", "compose", "env", "rows"}. compose is a docker-compose.yml draft, env the text of an env
file that holds the NAMES of the secrets (never a value), rows a list of [kind, level, where, text]: kind service|port|volume|env|webui|unmapped,
level info|warn. Whatever the draft cannot say is an "unmapped" row; nothing is guessed. Exit 0 ok, 2 not a template (message on stderr).
UNVERIFIED against real templates beyond the fixtures in tests/fixtures/unraid/: only the fields above are read.
"""
import json
import re
import sys
import xml.etree.ElementTree as ET

SECRET_RE = re.compile(r"(PASS|SECRET|TOKEN|KEY|CRED)", re.I)
NAME_RE = re.compile(r"[^a-z0-9_-]+")


def die(msg):
    sys.stderr.write(msg + "\n")
    sys.exit(2)


def q(s):   # a JSON string is a valid YAML double-quoted scalar; "$" must be doubled for compose
    return json.dumps(str(s).replace("$", "$$"), ensure_ascii=False)


def text(el, tag):
    c = el.find(tag)
    return (c.text or "").strip() if c is not None and c.text else ""


def map_host_path(host):
    """/mnt/user/appdata/<x> -> ./data/<x>; anything else on the Unraid array cannot be mapped (None)."""
    h = host.rstrip("/")
    m = re.match(r"^/mnt/(?:user|cache|disk\d+)/appdata(?:/(.*))?$", h)
    if m:
        rest = (m.group(1) or "").strip("/")
        if ".." in rest.split("/"):
            return None
        return "./data/" + rest if rest else "./data"
    return None


def convert(root, name):
    rows = []
    if root.tag != "Container":
        die("not an Unraid template: the root element is not <Container>")
    repo = text(root, "Repository")
    if not repo:
        die("not an Unraid template: no <Repository>")
    tmpl_name = text(root, "Name")
    app = NAME_RE.sub("-", (name or tmpl_name).lower()).strip("-")[:40] or "app"
    last = repo.rsplit("/", 1)[-1]
    image = repo if (":" in last or "@" in last) else repo + ":latest"
    if image.endswith(":latest"):
        rows.append(["unmapped", "warn", "image", "no version in the template: it runs :latest; pin a version"])
    rows.append(["service", "info", app, image])

    ports, vols, envs, devs, labels, secrets = [], [], [], [], [], []
    host_ports = {}
    for c in root.findall("Config"):
        typ = (c.get("Type") or "").strip()
        target = (c.get("Target") or "").strip()
        value = (c.text or "").strip() or (c.get("Default") or "").strip()
        label = c.get("Name") or target
        mode = (c.get("Mode") or "").strip()
        if typ == "Port":
            proto = mode if mode in ("tcp", "udp") else "tcp"
            if not (target.isdigit() and value.isdigit()):
                rows.append(["unmapped", "warn", "port " + label, "target or host port is not a number: " + target + " / " + value])
                continue
            ports.append("%s:%s/%s" % (value, target, proto))
            host_ports[target] = value
            rows.append(["port", "info", label, "%s:%s/%s" % (value, target, proto)])
        elif typ == "Path":
            host = map_host_path(value)
            ro = ":ro" if mode == "ro" else ""
            if not target.startswith("/"):
                rows.append(["unmapped", "warn", "path " + label, "container path is not absolute: " + target])
            elif host is None:
                rows.append(["unmapped", "warn", "path " + label,
                             "%s -> %s is outside appdata; create a share, bind it by hand and add it to the file" % (value, target)])
            else:
                vols.append("%s:%s%s" % (host, target, ro))
                rows.append(["volume", "info", label, "%s -> %s%s" % (host, target, ro)])
        elif typ == "Variable":
            if not target:
                continue
            if c.get("Mask", "").lower() == "true" or SECRET_RE.search(target):
                secrets.append(target)
                envs.append((target, None))
                rows.append(["env", "warn", target, "secret: the value is not copied; put it in the env file"])
            else:
                envs.append((target, value))
                rows.append(["env", "info", target, "set"])
        elif typ == "Device":
            if value == "/dev/dri":
                devs.append("/dev/dri:/dev/dri")
                rows.append(["volume", "info", "device", "/dev/dri (GPU render nodes)"])
            else:
                rows.append(["unmapped", "warn", "device " + label, "%s is not mapped (only /dev/dri is); add it by hand after reading the risks" % value])
        elif typ == "Label":
            if target:
                labels.append((target, value))
        else:
            rows.append(["unmapped", "warn", "config " + (label or "?"), "type %r is not read" % typ])

    net = text(root, "Network")
    if net and net not in ("bridge", ""):
        rows.append(["unmapped", "warn", "network", "%s is not mapped (host or custom networks need a decision; the draft uses the default bridge)" % net])
    if text(root, "Privileged").lower() == "true":
        rows.append(["unmapped", "warn", "privileged", "privileged mode is never imported (hs docker import refuses it)"])
    for tag in ("ExtraParams", "PostArgs"):
        v = text(root, tag)
        if v:
            rows.append(["unmapped", "warn", tag, "not imported, check each flag by hand: " + v])
    for tag in ("PreArgs", "CPUset", "TailscaleStateDir"):
        if text(root, tag):
            rows.append(["unmapped", "warn", tag, "not imported: " + text(root, tag)])

    webui = text(root, "WebUI")
    if webui:
        m = re.search(r"\[PORT:(\d+)\]", webui)
        url = webui
        if m:
            hp = host_ports.get(m.group(1), m.group(1))
            url = re.sub(r"\[PORT:\d+\]", hp, webui)
        url = url.replace("[IP]", "<server>")
        rows.append(["webui", "info", "WebUI", url])
    for t, v in envs:
        if t in ("PUID", "PGID") and v in ("99", "100"):
            rows.append(["unmapped", "warn", t, "Unraid's user nobody (%s); files in ./data belong to that id, check the owner" % v])

    y = ["# Draft from the Unraid template %s (hs docker import-unraid). UNVERIFIED: read every line before hs docker import." % (q(tmpl_name or app)),
         "services:", "  %s:" % app, "    image: " + q(image), "    restart: unless-stopped"]
    if ports:
        y.append("    ports:")
        y += ["      - " + q(p) for p in ports]
    if vols:
        y.append("    volumes:")
        y += ["      - " + q(v) for v in vols]
    if devs:
        y.append("    devices:")
        y += ["      - " + q(d) for d in devs]
    if envs:
        y.append("    environment:")
        for t, v in envs:
            y.append("      %s: %s" % (q(t), "${%s}" % t if v is None else q(v)))
    if labels:
        y.append("    labels:")
        y += ["      %s: %s" % (q(t), q(v)) for t, v in labels]
    env_text = "".join("%s=\n" % s for s in secrets)
    return {"name": app, "compose": "\n".join(y) + "\n", "env": env_text, "rows": rows}


def main(argv):
    name = ""
    args = []
    i = 0
    while i < len(argv):
        if argv[i] == "--name" and i + 1 < len(argv):
            name = argv[i + 1]
            i += 2
        else:
            args.append(argv[i])
            i += 1
    if len(args) != 1:
        die("usage: unraid_import.py <template.xml> [--name <app>]")
    try:
        data = open(args[0], "rb").read(1 << 20)
    except OSError as e:
        die("cannot read the template: %s" % e.strerror)
    if re.search(rb"<!(DOCTYPE|ENTITY)", data, re.I):   # entity expansion: never parse it
        die("not accepted: the template has a DOCTYPE or ENTITY declaration")
    try:
        root = ET.fromstring(data)
    except ET.ParseError:
        die("not an Unraid template: the XML is not valid")
    json.dump(convert(root, name), sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main(sys.argv[1:])
