#!/usr/bin/env python3
"""Render and read the route files of the gateway proxy (Traefik), standard library only (capabilities/gateway/NOTES.md).

  gateway_render.py local <host> <path>=<target>...   print the file local-<host>.yml
  gateway_render.py read <dir>                        host<TAB>path<TAB>target<TAB>file for every local-*.yml with a valid header
  gateway_render.py unmanaged <dir>                   the file names that are neither 00-hs-*, local-* nor pt-*

One YAML error in ANY file makes Traefik ignore the whole directory update, so a file is always rendered here (golden tests,
tests/gateway.sh) and moved in atomically by the caller. Only the header comments are read back, YAML is never parsed.
Exit 1 on a host, path or target that does not match.
"""
import os
import hashlib
import re
import sys

HOST = re.compile(r'^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$')
PATH = re.compile(r'^/[A-Za-z0-9._/-]{0,100}$')
TARGET = re.compile(r'^(https://)?[0-9a-fA-F.:\[\]]+:[0-9]{1,5}$')
MAGIC = '# hs-gateway local v1 host='
FOOT = '# written by hs services apply (gateway proxy); do not edit'


def die(msg):
    sys.stderr.write(msg + '\n')
    sys.exit(1)


def route_id(host, path):
    # a short hash of the path keeps /a_b and /a/b apart (Traefik drops a router name it already has)
    pid = 'root' if path == '/' else path.replace('/', '_').lstrip('_') + '-' + hashlib.sha1(path.encode()).hexdigest()[:6]
    return 'l-%s-%s' % (host.replace('.', '-'), pid)


def render(host, routes):
    if not HOST.match(host):
        die('bad host: %s' % host)
    out = [MAGIC + host]
    for path, target in routes:
        if not PATH.match(path):
            die('bad path: %s' % path)
        if not TARGET.match(target):
            die('bad target: %s' % target)
        out.append('# route path=%s target=%s' % (path, target))
    out.append(FOOT)
    routers, services = [], []
    for path, target in routes:
        rid = route_id(host, path)
        rule = 'Host(`%s`)' % host
        if path != '/':
            rule += ' && PathPrefix(`%s`)' % path
        routers += ['    %s:' % rid, '      entryPoints: [lan-http]', "      rule: '%s'" % rule,
                    '      middlewares: [hs-lan-only]', '      service: %s' % rid]
        https = target.startswith('https://')
        url = target if https else 'http://' + target
        services += ['    %s:' % rid, '      loadBalancer:', '        passHostHeader: true']
        if https:
            services.append('        serversTransport: hs-insecure')
        services += ['        servers:', "          - url: '%s'" % url]
    out += ['http:', '  routers:'] + routers + ['  services:'] + services
    return '\n'.join(out) + '\n'


def read_file(path):
    """(host, [(path, target)]) from the header, or None when the header is not valid."""
    try:
        with open(path, encoding='utf-8') as f:
            lines = f.read().split('\n')
    except OSError:
        return None
    if not lines or not lines[0].startswith(MAGIC):
        return None
    host = lines[0][len(MAGIC):].strip()
    if not HOST.match(host):
        return None
    routes = []
    for ln in lines[1:]:
        m = re.match(r'^# route path=(\S+) target=(\S+)$', ln)
        if not m:
            break
        if not PATH.match(m.group(1)) or not TARGET.match(m.group(2)):
            return None
        routes.append((m.group(1), m.group(2)))
    return host, routes


def main(argv):
    if len(argv) < 2:
        die('usage: gateway_render.py local <host> <path>=<target>... | read <dir> | unmanaged <dir>')
    cmd = argv[1]
    if cmd == 'local' and len(argv) >= 4:
        routes = []
        for a in argv[3:]:
            p, sep, t = a.partition('=')
            if not sep:
                die('bad route: %s' % a)
            routes.append((p, t))
        sys.stdout.write(render(argv[2], routes))
    elif cmd == 'read' and len(argv) == 3:
        d = argv[2]
        for name in sorted(os.listdir(d) if os.path.isdir(d) else []):
            if not (name.startswith('local-') and name.endswith('.yml')):
                continue
            got = read_file(os.path.join(d, name))
            if got:
                for p, t in got[1]:
                    sys.stdout.write('%s\t%s\t%s\t%s\n' % (got[0], p, t, name))
    elif cmd == 'unmanaged' and len(argv) == 3:
        d = argv[2]
        for name in sorted(os.listdir(d) if os.path.isdir(d) else []):
            if not (name.startswith(('00-hs-', 'local-', 'pt-')) or name.startswith('.')):
                sys.stdout.write(name + '\n')
    else:
        die('usage: gateway_render.py local <host> <path>=<target>... | read <dir> | unmanaged <dir>')


if __name__ == '__main__':
    main(sys.argv)
