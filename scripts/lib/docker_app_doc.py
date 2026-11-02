#!/usr/bin/env python3
"""Parse and check the raw document of `hs sys docker app <app>`.

Modes:
  parse (default): read a raw document from stdin and print JSON {"rev","managed","env":[...],"compose"}.
  check:          read `docker compose config --format json` from stdin and print policy TSV lines.
The helper never reads an .env file and never prints a secret value.
"""
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
        else:
            die("malformed document: unknown header")
    if rev is None or managed is None:
        die("malformed document: missing rev or managed")
    print(json.dumps({"rev": rev, "managed": managed, "env": env, "compose": compose}, separators=(",", ":")))


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


def _warn_env(service, env):
    if env is None:
        return
    if isinstance(env, dict):
        items = env.items()
    elif isinstance(env, list):
        items = []
        for e in env:
            if isinstance(e, str) and "=" in e:
                name, _, val = e.partition("=")
                items.append((name, val))
            elif isinstance(e, str):
                items.append((e, ""))
    else:
        return
    for name, val in items:
        if not isinstance(name, str) or not isinstance(val, str):
            continue
        if not val:
            continue
        if re.search(r"PASS|TOKEN|SECRET|KEY", name, re.IGNORECASE):
            print(f"warn\tService {service} environment key {name} holds a literal value; move it to the env file.")


def do_check(raw):
    try:
        cfg = json.loads(raw.decode("utf-8", "strict"))
    except (UnicodeDecodeError, ValueError):
        die("malformed JSON")
    if not isinstance(cfg, dict):
        die("malformed JSON")
    refuse_host = False
    ports = set()
    volumes = cfg.get("volumes")
    if volumes and isinstance(volumes, dict) and len(volumes) > 0:
        print("refuse\tTop-level named volumes are not allowed.")
    services = cfg.get("services") or {}
    if not isinstance(services, dict):
        die("malformed JSON")
    for sname, svc in services.items():
        if not isinstance(svc, dict):
            continue
        for entry in svc.get("ports") or []:
            p, bad = _published_port(entry)
            if bad:
                refuse_host = True
            elif p is not None:
                ports.add(p)
        _warn_env(sname, svc.get("environment"))
    if refuse_host:
        print("refuse\tEvery published port must name the host port.")
    for p in sorted(ports):
        print(f"port\t{p}")


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
