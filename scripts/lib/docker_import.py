#!/usr/bin/env python3
"""hs docker import: the plan of an imported compose file (stdlib only).

stdin: the output of `docker compose config --format json` (run in the docker container, relative paths resolved against the app folder).
argument: --app-dir <folder of the app inside docker>.
stdout: one line per finding, tab separated: kind, level, where, text. An empty field is written `-`; no tab or newline inside a field.
  kind   service | port | volume | network | env | unsupported | danger | summary
  level  info | warn | error | risky | refuse
         error  = the route (hs docker-app app-save) cannot honour it: the import stops
         risky  = needs --allow-risky and the typed name
         refuse = never importable, even with --allow-risky
Environment VALUES are never printed, only names.
"""
import json
import posixpath
import sys

# service keys the plan understands: they are listed or checked above and pass the route as they are
KNOWN = {
    "image", "build", "command", "entrypoint", "ports", "expose", "volumes", "environment", "restart", "depends_on", "networks",
    "container_name", "healthcheck", "user", "working_dir", "labels", "hostname", "tmpfs", "extra_hosts", "dns", "stop_grace_period",
    "stop_signal", "cap_add", "cap_drop", "devices", "privileged", "volumes_from", "network_mode", "pid", "ipc", "security_opt", "userns_mode",
    "init", "read_only", "logging", "mem_limit", "cpus", "shm_size", "tty", "stdin_open", "platform", "pull_policy", "profiles",
    "ulimits", "sysctls", "mem_reservation", "cpu_shares", "group_add", "domainname", "dns_search", "runtime",
}
# keys that are not imported at all (the route has no place for them): an error
REFUSED_KEYS = {"secrets", "configs", "extends", "develop"}
NAMED = set()   # named volumes already reported by a service

REFUSE_PATHS = ("/etc", "/proc", "/sys", "/boot")
DOCKER_SOCKS = ("/var/run/docker.sock", "/run/docker.sock")
RISKY_CAPS = {"SYS_ADMIN", "NET_ADMIN", "ALL"}


def clean(s):
    return str(s).replace("\t", " ").replace("\r", " ").replace("\n", " ") or "-"


def out(kind, level, where, text):
    print("\t".join((kind, level, clean(where), clean(text))))


def is_sock(p):
    return p in DOCKER_SOCKS or posixpath.basename(p.rstrip("/")) == "docker.sock"


def is_sock_parent(p):
    p = posixpath.normpath(p) if p.startswith("/") else p
    return any(s == p or s.startswith(p.rstrip("/") + "/") for s in DOCKER_SOCKS)


def refused_host_path(p):
    p = posixpath.normpath(p) if p.startswith("/") else p
    if p == "/" or is_sock_parent(p):
        return True
    return any(p == r or p.startswith(r + "/") for r in REFUSE_PATHS)


def inside(p, app_dir):
    p = posixpath.normpath(p)
    d = posixpath.normpath(app_dir)
    return p == d or p.startswith(d.rstrip("/") + "/")


def service_ports(name, svc):
    for e in svc.get("ports") or []:
        where = "services.%s.ports" % name
        if isinstance(e, dict):
            pub, tgt = e.get("published"), e.get("target")
            proto = e.get("protocol") or "tcp"
            ip = e.get("host_ip")
        else:
            s = str(e)
            main, _, proto = s.partition("/")
            parts = main.split(":")
            tgt, pub, ip = parts[-1], (parts[-2] if len(parts) > 1 else None), (parts[0] if len(parts) > 2 else None)
            proto = proto or "tcp"
        if pub in (None, "", 0):
            out("port", "error", where, "port %s/%s has no host port: name it as <host>:%s" % (tgt, proto, tgt))
            continue
        host = "%s:%s" % (ip, pub) if ip else str(pub)
        out("port", "info", where, "%s:%s/%s" % (host, tgt, proto))


def service_volumes(name, svc, app_dir):
    for v in svc.get("volumes") or []:
        where = "services.%s.volumes" % name
        if not isinstance(v, dict):
            out("volume", "warn", where, "not imported/untested: %s" % v)
            continue
        kind, src, tgt = v.get("type"), v.get("source"), v.get("target")
        mode = "ro" if v.get("read_only") else "rw"
        if kind == "bind" and isinstance(src, str):
            place = "inside the app folder" if inside(src, app_dir) else "OUTSIDE the app folder"
            out("volume", "info", where, "%s -> %s (%s, %s)" % (src, tgt, mode, place))
            if is_sock(src):
                out("danger", "refuse", where, "%s is the Docker socket: whoever holds it owns the host (never imported)" % src)
            elif refused_host_path(src):
                out("danger", "refuse", where, "the host path %s is never imported" % src)
            elif not inside(src, app_dir):
                out("danger", "risky", where, "bind mount of %s from outside the app folder" % src)
        elif kind == "volume":
            nm = src or "-"
            NAMED.add(nm)
            out("volume", "error", where, "named volume %s not supported, use ./data/%s bind" % (nm, nm))
        elif kind == "tmpfs":
            out("volume", "info", where, "tmpfs -> %s" % tgt)
        else:
            out("volume", "warn", where, "not imported/untested: volume type %s" % kind)


def service_danger(name, svc):
    w = "services.%s" % name
    if svc.get("privileged") is True:
        out("danger", "refuse", w + ".privileged", "privileged: true gives the container the whole host (never imported)")
    if svc.get("network_mode") == "host":
        out("danger", "risky", w + ".network_mode", "network_mode: host puts the container on the host network")
    elif svc.get("network_mode"):
        out("service", "warn", w + ".network_mode", "not imported/untested: network_mode %s" % svc["network_mode"])
    for key in ("pid", "ipc"):
        if svc.get(key) == "host":
            out("danger", "risky", "%s.%s" % (w, key), "%s: host shares the host's %s namespace" % (key, key))
    if svc.get("userns_mode") == "host":
        out("danger", "risky", w + ".userns_mode", "userns_mode: host turns off the user namespace")
    for cap in svc.get("cap_add") or []:
        c = str(cap).upper().replace("CAP_", "", 1)
        if c in RISKY_CAPS:
            out("danger", "risky", w + ".cap_add", "cap_add %s is close to root on the host" % c)
        else:
            out("service", "warn", w + ".cap_add", "capability %s is added" % c)
    for d in svc.get("devices") or []:
        src = d.get("source") if isinstance(d, dict) else str(d).split(":", 1)[0]
        src = src or "-"
        if src.startswith("/"):
            src = posixpath.normpath(src)
        if not (src == "/dev/dri" or src.startswith("/dev/dri/")):
            out("danger", "risky", w + ".devices", "device %s is passed through (only /dev/dri is routine)" % src)
        else:
            out("service", "info", w + ".devices", "device %s" % src)
    if svc.get("volumes_from"):
        out("danger", "risky", w + ".volumes_from", "volumes_from shares the volumes of other containers (not checked)")
    for opt in svc.get("security_opt") or []:
        o = str(opt)
        if "unconfined" in o:
            out("danger", "risky", w + ".security_opt", "security_opt %s switches a protection off" % o)
        else:
            out("service", "warn", w + ".security_opt", "not reviewed: security_opt %s" % o)


def service_env(name, svc):
    env = svc.get("environment")
    names = []
    if isinstance(env, dict):
        names = [str(k) for k in env]
    elif isinstance(env, list):
        names = [str(e).split("=", 1)[0] for e in env]
    if names:
        out("env", "info", "services.%s.environment" % name, ", ".join(sorted(names)))


def main(argv):
    app_dir = None
    if len(argv) >= 3 and argv[1] == "--app-dir":
        app_dir = argv[2]
    if not app_dir:
        sys.stderr.write("usage: docker_import.py --app-dir <folder> < config.json\n")
        return 2
    try:
        cfg = json.loads(sys.stdin.buffer.read().decode("utf-8", "strict"))
    except (UnicodeDecodeError, ValueError):
        sys.stderr.write("malformed JSON\n")
        return 2
    if not isinstance(cfg, dict) or not isinstance(cfg.get("services") or {}, dict):
        sys.stderr.write("malformed JSON\n")
        return 2
    services = cfg.get("services") or {}
    if not services:
        out("unsupported", "error", "services", "the file has no service")
    for name, svc in services.items():
        if not isinstance(svc, dict):
            continue
        w = "services.%s" % name
        what = svc.get("image") or "-"
        if "build" in svc:
            out("service", "warn", w, "%s: built from a Dockerfile (build) - not imported/untested: the build context must be in the app folder" % name)
        out("service", "info", w, "%s (image %s)" % (name, what))
        service_ports(name, svc)
        service_volumes(name, svc, app_dir)
        for n in sorted((svc.get("networks") or {}) if isinstance(svc.get("networks"), (dict, list)) else []):
            out("network", "info", w + ".networks", n)
        service_env(name, svc)
        service_danger(name, svc)
        for key in sorted(svc):
            if key in REFUSED_KEYS:
                out("unsupported", "error", "%s.%s" % (w, key), "%s cannot be imported" % key)
            elif key not in KNOWN:
                out("unsupported", "warn", "%s.%s" % (w, key), "not imported/untested: %s" % key)
    for key in ("secrets", "configs"):
        if cfg.get(key):
            out("unsupported", "error", key, "top-level %s cannot be imported" % key)
    vols = cfg.get("volumes")
    if isinstance(vols, dict):
        for v in sorted(set(vols) - NAMED):
            out("volume", "error", "volumes", "named volume %s not supported, use ./data/%s bind" % (v, v))
    nets = cfg.get("networks")
    if isinstance(nets, dict):
        for n in sorted(nets):
            out("network", "info", "networks", "%s (defined in the file)" % n)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
