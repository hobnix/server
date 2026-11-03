#!/usr/bin/env python3
"""Parse and check the raw document of `hs sys docker app <app>`.

Modes:
  parse (default): read a raw document from stdin and print JSON {"rev","managed","env":[...],"compose"}.
  check:          read `docker compose config --format json` from stdin and print policy TSV lines.
The env text is returned for the admin editor (envText, envTooBig over 64 KiB); the read is nocache.
The helper never reads an .env file itself and check mode prints no secret value.
"""
import base64
import hashlib
import json
import re
import sys

NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
REV_RE = re.compile(r"^[0-9a-f]{16}$")
MANAGED_RE = re.compile(r"^(web|recipe|other)$")
SEP = b"__HS_COMPOSE__\n"


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def do_parse(raw):
    parts = raw.split(SEP, 1)
    if len(parts) != 2:
        die("malformed document: missing separator")
    head, compose = parts
    try:
        compose = compose.decode("utf-8", "strict")
    except UnicodeDecodeError:
        die("malformed document: compose is not valid UTF-8")
    rev = None
    managed = None
    env = []
    seen_env = set()
    env_text = ""
    env_big = False
    for line in head.decode("utf-8", "strict").splitlines():
        if "\t" not in line:
            die("malformed document: header line has no tab")
        key, _, val = line.partition("\t")
        if key == "rev":
            if rev is not None or not REV_RE.fullmatch(val):
                die("malformed document: bad rev")
            rev = val
        elif key == "managed":
            if managed is not None or not MANAGED_RE.fullmatch(val):
                die("malformed document: bad managed")
            managed = val
        elif key == "env":
            if not NAME_RE.fullmatch(val):
                die("malformed document: bad env name")
            if val in seen_env:
                die("malformed document: duplicate env name")
            seen_env.add(val)
            env.append(val)
        elif key == "envb64":
            try:
                env_text = base64.b64decode(val, validate=True).decode("utf-8", "strict")
            except (ValueError, UnicodeDecodeError):
                die("malformed document: bad envb64")
        elif key == "envbig":
            env_big = True
        else:
            die("malformed document: unknown header")
    if rev is None or managed is None:
        die("malformed document: missing rev or managed")
    doc = {"rev": rev, "managed": managed, "env": env, "compose": compose, "envText": env_text}
    if env_big:
        doc["envTooBig"] = True
    print(json.dumps(doc, separators=(",", ":")))


def _published_port(entry):
    """Return (valid_host_port_or_None, unsupported)."""
    if isinstance(entry, dict):
        published = entry.get("published")
        if published is None:
            return None, True
        try:
            p = int(published)
        except (TypeError, ValueError):
            return None, True
        if 1 <= p <= 65535:
            return p, False
        return None, True
    if isinstance(entry, str):
        # "8080:80/tcp" or "8080-8081:80-81/tcp" etc.
        host = entry.split(":", 1)[0]
        host = host.split("/", 1)[0]
        if "-" in host:
            return None, True
        try:
            p = int(host)
        except ValueError:
            return None, True
        if 1 <= p <= 65535:
            return p, False
        return None, True
    return None, True


def _env_items(env):
    if isinstance(env, dict):
        return list(env.items())
    if isinstance(env, list):
        items = []
        for e in env:
            if isinstance(e, str) and "=" in e:
                name, _, val = e.partition("=")
                items.append((name, val))
            elif isinstance(e, str):
                items.append((e, ""))
        return items
    return []


def _warn_env(service, env, raw_env=None):
    """raw_env: the same environment before interpolation; a value that is a ${VAR} there comes from the env file and is fine."""
    if env is None:
        return
    raw = {n: v for n, v in _env_items(raw_env) if isinstance(n, str) and isinstance(v, str)}
    for name, val in _env_items(env):
        if not isinstance(name, str) or not isinstance(val, str):
            continue
        if not val:
            continue
        if re.search(r"\$\{|\$[A-Za-z_]", raw.get(name, "")):
            continue
        if re.search(r"PASS|TOKEN|SECRET|KEY", name, re.IGNORECASE):
            print(f"warn\tService {service} environment key {name} holds a literal value; move it to the env file.\tservices.{service}.environment")


def do_check(raw):
    """Policy lines, tab separated: refuse|<text>|<path>, port|<port>|<path>, warn|<text>|<path>, cname|<name>|<path>, bind|<src>|<ro|rw>|<path>.
    <path> is a dotted compose path (services.web.ports) or - ; no secret value is printed."""
    # stdin: the config JSON, optionally followed by a line holding RS (0x1e) and the same config without interpolation
    first, _, rest = raw.partition(b"\n\x1e\n")
    try:
        cfg = json.loads(first.decode("utf-8", "strict"))
    except (UnicodeDecodeError, ValueError):
        die("malformed JSON")
    if not isinstance(cfg, dict):
        die("malformed JSON")
    try:
        raw_services = (json.loads(rest.decode("utf-8", "strict")) or {}).get("services") or {} if rest.strip() else {}
    except (UnicodeDecodeError, ValueError, AttributeError):
        raw_services = {}
    if not isinstance(raw_services, dict):
        raw_services = {}
    ports = {}
    volumes = cfg.get("volumes")
    if volumes and isinstance(volumes, dict) and len(volumes) > 0:
        print("refuse\tTop-level named volumes are not allowed.\tvolumes")
    services = cfg.get("services") or {}
    if not isinstance(services, dict):
        die("malformed JSON")
    bad_paths = []
    for sname, svc in services.items():
        if not isinstance(svc, dict):
            continue
        for entry in svc.get("ports") or []:
            p, bad = _published_port(entry)
            if bad:
                bad_paths.append(f"services.{sname}.ports")
            elif p is not None:
                ports.setdefault(p, f"services.{sname}.ports")
        cname = svc.get("container_name")
        if isinstance(cname, str) and cname:
            print(f"cname\t{cname}\tservices.{sname}.container_name")
        for vol in svc.get("volumes") or []:
            if isinstance(vol, dict) and vol.get("type") == "bind" and isinstance(vol.get("source"), str):
                print(f"bind\t{vol['source']}\t{'ro' if vol.get('read_only') else 'rw'}\tservices.{sname}.volumes")
        raw_svc = raw_services.get(sname)
        _warn_env(sname, svc.get("environment"), raw_svc.get("environment") if isinstance(raw_svc, dict) else None)
    for path in dict.fromkeys(bad_paths):
        print(f"refuse\tEvery published port must name the host port.\t{path}")
    for p in sorted(ports):
        print(f"port\t{p}\t{ports[p]}")


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "parse"
    raw = sys.stdin.buffer.read()
    if mode == "parse":
        do_parse(raw)
    elif mode == "check":
        do_check(raw)
    else:
        die(f"unknown mode: {mode}")


if __name__ == "__main__":
    main()
