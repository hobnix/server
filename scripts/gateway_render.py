#!/usr/bin/env python3
"""Render and read the route files of the gateway proxy (Traefik), standard library only (capabilities/gateway/NOTES.md).

  gateway_render.py local <host> <path>=<target>...   print the file local-<host>.yml
  gateway_render.py public <host> <specfile>          print the file pub-<host>.yml (host spec, TSV: route/auth/skip/reqh/resh lines)
  gateway_render.py read <dir> [--prefix local-|pub-] host<TAB>path<TAB>target<TAB>file for every local-*.yml (or pub-*.yml) with a valid header
  gateway_render.py specs <dir>                       host<TAB>spec line for every valid pub-*.yml
  gateway_render.py unmanaged <dir>                   the file names that are neither 00-hs-*, local-*, pt-* nor pub-*

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
PUB_MAGIC = '# hs-gateway public v1 host='
SVC = re.compile(r'^[a-z0-9][a-z0-9-]{0,40}$')
HNAME = re.compile(r'^[A-Za-z0-9-]{1,64}$')
HVALUE = re.compile(r'^[\x20-\x7e]{1,200}$')
HREFUSED = ('host', 'content-length', 'transfer-encoding', 'connection')
KINDS = ('route', 'auth', 'skip', 'reqh', 'resh')
NFIELDS = {'route': 3, 'auth': 2, 'skip': 2, 'reqh': 3, 'resh': 3}
DEAD = '127.0.0.1:1'
OUTPOST = '/outpost.goauthentik.io'
FOOT = '# written by hs services apply (gateway proxy); do not edit'
AUTH_HEADERS = ['X-authentik-username', 'X-authentik-groups', 'X-authentik-entitlements', 'X-authentik-email', 'X-authentik-name',
                'X-authentik-uid', 'X-authentik-jwt', 'X-authentik-meta-jwks', 'X-authentik-meta-outpost', 'X-authentik-meta-provider',
                'X-authentik-meta-app', 'X-authentik-meta-version']
USAGE = ('usage: gateway_render.py local <host> <path>=<target>... | public <host> <specfile> | read <dir> [--prefix local-|pub-]'
         ' | specs <dir> | unmanaged <dir>')


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


def pub_line_ok(fields):
    """True when one spec line (kind, svc, ...) is valid; fields is a list of strings."""
    if not fields or fields[0] not in KINDS:
        return False
    kind = fields[0]
    if len(fields) != NFIELDS[kind] + 1 or not SVC.match(fields[1]):
        return False
    if kind == 'route':
        return bool(PATH.match(fields[2]) and TARGET.match(fields[3]) and not fields[3].startswith('https://'))
    if kind == 'auth':
        return bool(TARGET.match(fields[2]) and not fields[2].startswith('https://'))
    if kind == 'skip':
        return bool(PATH.match(fields[2]))
    return bool(HNAME.match(fields[2]) and fields[2].lower() not in HREFUSED and HVALUE.match(fields[3]))


def pub_sort(lines):
    return sorted(lines, key=lambda f: (KINDS.index(f[0]), f[1:]))


def yq(v):
    return "'" + v.replace("'", "''") + "'"


def render_public(host, lines):
    """pub-<host>.yml from the spec lines (lists of fields); exit 1 on anything that does not match."""
    if not HOST.match(host):
        die('bad host: %s' % host)
    if not lines:
        die('empty spec')
    seen, kept = {}, []
    for f in lines:
        if not pub_line_ok(f):
            die('bad spec line: %s' % ' '.join(f))
        if f[0] in ('reqh', 'resh'):
            seen[(f[0], f[1], f[2].lower())] = f   # a duplicate YAML key would break the directory: the last one wins
        else:
            kept.append(f)
    lines = pub_sort(kept + list(seen.values()))
    routes = [f for f in lines if f[0] == 'route']
    rsvcs = {f[1] for f in routes}
    auths = {}
    for f in lines:
        if f[0] == 'auth':
            if f[1] in auths:
                die('auth twice for %s' % f[1])
            auths[f[1]] = f[2]
        if f[0] in ('auth', 'skip') and f[1] not in rsvcs:
            die('%s of a service without a route: %s' % (f[0], f[1]))
    hid = host.replace('.', '-')

    def pid(path):
        return route_id(host, path)[len('l-' + hid + '-'):]

    def nm(path):
        return 'p-%s-%s' % (hid, pid(path))

    hdr = {}
    for f in lines:
        if f[0] in ('reqh', 'resh'):
            hdr.setdefault(f[1], {'reqh': [], 'resh': []})[f[0]].append((f[2], f[3]))
    out = [PUB_MAGIC + host] + ['# spec ' + ' '.join(f) for f in lines] + [FOOT]

    def mids(svc):
        m = []
        if svc in auths:
            m.append('pa-%s-%s-auth' % (hid, svc))
        if svc in hdr:
            m.append('pa-%s-%s-hdr' % (hid, svc))
        return m

    def router(name, rule, prio, m, svc):
        r = ['    %s:' % name, '      entryPoints: [public-tunnel]', "      rule: '%s'" % rule, '      priority: %d' % prio]
        if m:
            r.append('      middlewares: [%s]' % ', '.join(m))
        return r + ['      service: %s' % svc]

    routers, services = [], []
    real = []   # (path, svc) of the real routes a skip path can fall under
    for _, svc, path, target in routes:
        if path == OUTPOST:
            routers += router(nm(path), 'Host(`%s`) && PathPrefix(`%s/`)' % (host, path), 20000, [], nm(path))
        elif target == DEAD:
            if path != '/':
                routers += router(nm(path), 'Host(`%s`) && PathPrefix(`%s`)' % (host, path), 30000 + len(path), ['hs-deny'], 'hs-null')
            continue
        else:
            rule = 'Host(`%s`)' % host
            if path != '/':
                rule += ' && PathPrefix(`%s`)' % path
            m = mids(svc)
            if any(f[0] == 'skip' and f[1] == svc and path.startswith(f[2]) for f in lines):
                m = [x for x in m if not x.endswith('-auth')]   # the route lies inside a skip path: no login
            routers += router(nm(path), rule, 100 if path == '/' else 1000 + len(path), m, nm(path))
            real.append((path, svc))
        services += ['    %s:' % nm(path), '      loadBalancer:', '        passHostHeader: true', '        servers:',
                     "          - url: 'http://%s'" % target]
    for _, svc, path in [f for f in lines if f[0] == 'skip']:
        cover = [p for p, s in real if s == svc and (p == '/' or path.startswith(p))]
        if not cover or (path, svc) in real:   # a real route at the skip path itself has no login already
            continue
        m = ['pa-%s-%s-hdr' % (hid, svc)] if svc in hdr else []
        routers += router('p-%s-s-%s' % (hid, pid(path)), 'Host(`%s`) && PathPrefix(`%s`)' % (host, path), 1000 + len(path), m,
                          nm(max(cover, key=len)))
    mw = []
    for svc in sorted(set(auths) | set(hdr)):
        if svc in auths:
            mw += ['    pa-%s-%s-auth:' % (hid, svc), '      forwardAuth:',
                   "        address: 'http://%s/outpost.goauthentik.io/auth/traefik'" % auths[svc], '        trustForwardHeader: true',
                   '        authResponseHeaders: [%s]' % ', '.join(AUTH_HEADERS)]
        if svc in hdr:
            mw += ['    pa-%s-%s-hdr:' % (hid, svc), '      headers:']
            for key, name in (('reqh', 'customRequestHeaders'), ('resh', 'customResponseHeaders')):
                if hdr[svc][key]:
                    mw.append('        %s:' % name)
                    mw += ['          %s: %s' % (yq(n), yq(v)) for n, v in hdr[svc][key]]
    sections = [x for x in (('routers', routers), ('services', services), ('middlewares', mw)) if x[1]]
    if not sections:
        return '\n'.join(out + ['http: {}']) + '\n'
    out.append('http:')
    for name, body in sections:
        out += ['  %s:' % name] + body
    return '\n'.join(out) + '\n'


def read_pub(path):
    """(host, [spec line as list of fields]) from the header, or None when it is not valid."""
    try:
        with open(path, encoding='utf-8') as f:
            lines = f.read().split('\n')
    except OSError:
        return None
    if not lines or not lines[0].startswith(PUB_MAGIC):
        return None
    host = lines[0][len(PUB_MAGIC):].strip()
    if not HOST.match(host):
        return None
    specs = []
    for ln in lines[1:]:
        if not ln.startswith('# spec '):
            break
        rest = ln[len('# spec '):]
        kind = rest.split(' ', 1)[0]
        if kind not in KINDS:
            return None
        fields = rest.split(' ', NFIELDS[kind])
        if not pub_line_ok(fields):
            return None
        specs.append(fields)
    return (host, specs) if specs else None


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
        die(USAGE)
    cmd = argv[1]
    if cmd == 'local' and len(argv) >= 4:
        routes = []
        for a in argv[3:]:
            p, sep, t = a.partition('=')
            if not sep:
                die('bad route: %s' % a)
            routes.append((p, t))
        sys.stdout.write(render(argv[2], routes))
    elif cmd == 'public' and len(argv) == 4:
        try:
            with open(argv[3], encoding='utf-8') as f:
                lines = [ln.split('\t') for ln in f.read().split('\n') if ln]
        except OSError:
            die('cannot read %s' % argv[3])
        sys.stdout.write(render_public(argv[2], lines))
    elif cmd == 'read' and (len(argv) == 3 or (len(argv) == 5 and argv[3] == '--prefix' and argv[4] in ('local-', 'pub-'))):
        d = argv[2]
        prefix = argv[4] if len(argv) == 5 else 'local-'
        for name in sorted(os.listdir(d) if os.path.isdir(d) else []):
            if not (name.startswith(prefix) and name.endswith('.yml')):
                continue
            if prefix == 'pub-':
                got = read_pub(os.path.join(d, name))
                for f in (got[1] if got else []):
                    if f[0] == 'route':
                        sys.stdout.write('%s\t%s\t%s\t%s\n' % (got[0], f[2], f[3], name))
                continue
            got = read_file(os.path.join(d, name))
            if got:
                for p, t in got[1]:
                    sys.stdout.write('%s\t%s\t%s\t%s\n' % (got[0], p, t, name))
    elif cmd == 'specs' and len(argv) == 3:
        d = argv[2]
        for name in sorted(os.listdir(d) if os.path.isdir(d) else []):
            if name.startswith('pub-') and name.endswith('.yml'):
                got = read_pub(os.path.join(d, name))
                for f in (got[1] if got else []):
                    sys.stdout.write('%s\t%s\n' % (got[0], '\t'.join(f)))
    elif cmd == 'unmanaged' and len(argv) == 3:
        d = argv[2]
        for name in sorted(os.listdir(d) if os.path.isdir(d) else []):
            if not (name.startswith(('00-hs-', 'local-', 'pt-', 'pub-')) or name.startswith('.')):
                sys.stdout.write(name + '\n')
    else:
        die(USAGE)


if __name__ == '__main__':
    main(sys.argv)
