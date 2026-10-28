#!/usr/bin/env python3
"""Checks, route files and list of the extension passthrough (capabilities/passthrough/NOTES.md), standard library only.

  passthrough.py domain <d>                           normalised domain (lower case), or refuse
  passthrough.py address <a> --host-addrs F --instance-addrs F   a private LAN address that is not this server, or refuse
  passthrough.py port <p>                             1..65535
  passthrough.py guard <d> --proxy-domains a,b --local-domain x --realm r --proxy-hosts F --routes DIR
  passthrough.py render <d> <a> <https> <http|-> <on|off> <public-http port|0>    the route file on stdout
                                                      (public port 80 = the entrypoint lan-http itself, else public-http; 0 = no HTTP router)
  passthrough.py list <dir>                           domain address https http proxy (TAB, sorted, - for empty) of every pt-*.yml

Exit 0 = ok, 1 = refused (the reason is ONE line on stdout), 2 = usage. One YAML error freezes every update of Traefik, so
the files are only ever rendered here (golden tests, tests/passthrough.sh) and moved in atomically by the caller. Only line 1
of a file is read back, YAML is never parsed.
"""
import ipaddress
import os
import re
import sys

DOM = re.compile(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$')
BAD_ENDINGS = ('.local', '.lan', '.home.arpa', '.internal', '.localhost')
MAGIC = '# hs-gateway passthrough v1 '
HEADER = re.compile(r'^# hs-gateway passthrough v1 domain=(\S+) address=(\S+) https=([0-9]{1,5}) http=([0-9]{1,5}|-) proxy=(on|off)$')
LOCAL_HEADER = re.compile(r'^# hs-gateway local v1 host=(\S+)')
PRIVATE_NETS = [ipaddress.ip_network(n) for n in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', 'fc00::/7')]


def refuse(msg):
    sys.stdout.write(msg + '\n')
    sys.exit(1)


def usage():
    sys.stderr.write(__doc__)
    sys.exit(2)


def norm_domain(d):
    if d != d.strip():
        refuse('the domain has spaces or a line break around it')
    d = d.lower()
    if len(d) > 64:
        refuse('%s is longer than 64 characters' % d[:64])
    if '*' in d:
        refuse('give the domain without a wildcard: its subdomains are forwarded anyway')
    if '.' not in d:
        refuse("'%s' is a single name: give a domain such as example.com" % d)
    if not DOM.fullmatch(d):
        refuse("'%s' is not a domain name (letters, digits, - and dots)" % d)
    for e in BAD_ENDINGS:
        if d.endswith(e):
            refuse('%s is a name for the home network, not for the internet' % d)
    return d


def parse_ip(s):
    if '%' in s or not re.fullmatch(r'[0-9a-fA-F:.]+', s):   # a scope id (fe80::1%eth0) takes any character: never accepted
        return None
    try:
        return ipaddress.ip_address(s)
    except ValueError:
        return None


def addrs_of(path):
    """every IP address found in a file (ip -o addr show, incus list csv, one per line): tokens are tried one by one"""
    out = set()
    try:
        with open(path, encoding='utf-8', errors='replace') as f:
            text = f.read()
    except OSError:
        return out
    for tok in re.split(r'[\s",;()]+', text):
        tok = tok.split('/')[0]
        ip = parse_ip(tok)
        if ip is not None:
            out.add(ip)
    return out


def check_address(a, host_file, inst_file):
    ip = parse_ip(a)
    if ip is None:
        refuse("'%s' is not an IP address" % a)
    if ip.is_loopback or ip.is_link_local or ip.is_unspecified or ip.is_multicast or not any(ip in n for n in PRIVATE_NETS):
        refuse('targets must be private LAN addresses (10.x, 172.16-31.x, 192.168.x, fc00::/7)')
    if ip in addrs_of(host_file) or ip in addrs_of(inst_file):
        refuse("that is this server or one of its containers: publish this server's own apps with hs services")
    return str(ip)


def check_port(p):
    if not re.fullmatch(r'[0-9]{1,5}', p) or not 1 <= int(p) <= 65535:
        refuse("'%s' is not a port (1 to 65535)" % p)
    return str(int(p))


def related(a, b):
    return a == b or a.endswith('.' + b) or b.endswith('.' + a)


def read_header(path, pat):
    try:
        with open(path, encoding='utf-8') as f:
            return pat.match(f.readline().rstrip('\n'))
    except OSError:
        return None


def list_rows(d):
    rows = []
    for name in sorted(os.listdir(d) if os.path.isdir(d) else []):
        if not (name.startswith('pt-') and name.endswith('.yml')):
            continue
        m = read_header(os.path.join(d, name), HEADER)
        if m:
            rows.append(m.groups())
    rows.sort()
    return rows


def guard(d, opts):
    for p in [x for x in opts.get('--proxy-domains', '').split(',') if x.strip()]:
        if related(d, p.strip().lower()):
            refuse('%s overlaps %s, a domain of the public reverse proxy' % (d, p.strip().lower()))
    for key, what in (('--local-domain', "the gateway's local domain"), ('--realm', 'the domain of the network (AD realm)')):
        x = opts.get(key, '').strip().lower()
        if x and related(d, x):
            refuse('%s overlaps %s (%s): nothing under it is forwarded from the internet' % (d, x, what))
    try:
        with open(opts.get('--proxy-hosts', os.devnull), encoding='utf-8') as f:
            hosts = [h.strip().lower() for h in f.read().split() if h.strip()]
    except OSError:
        hosts = []
    for h in hosts:
        h = h.lstrip('*.')
        if h and related(d, h):
            refuse('%s overlaps %s, a host of the public reverse proxy' % (d, h))
    routes = opts.get('--routes', '')
    for row in list_rows(routes):
        if row[0] != d and related(d, row[0]):
            refuse('%s overlaps %s, which is forwarded already' % (d, row[0]))
    for name in sorted(os.listdir(routes) if os.path.isdir(routes) else []):
        if name.startswith('local-') and name.endswith('.yml'):
            m = read_header(os.path.join(routes, name), LOCAL_HEADER)
            if m and related(d, m.group(1)):
                refuse('%s overlaps %s, a local name of the gateway proxy' % (d, m.group(1)))


def hostport(a, port):
    return ('[%s]:%s' % (a, port)) if ':' in a else ('%s:%s' % (a, port))


def render(d, a, https, http, proxy, pub_http):
    # defensive: whatever calls this, only these shapes ever reach the YAML
    if not DOM.fullmatch(d) or len(d) > 64 or parse_ip(a) is None or str(parse_ip(a)) != a:
        raise ValueError('bad domain or address')
    for p in (https, http):
        if p != '-' and not re.fullmatch(r'[0-9]{1,5}', p):
            raise ValueError('bad port')
    did = d.replace('.', '-')
    esc = d.replace('.', '\\.')
    out = ['%sdomain=%s address=%s https=%s http=%s proxy=%s' % (MAGIC, d, a, https, http, proxy),
           '# written by hs ext passthrough; do not edit',
           'tcp:', '  routers:', '    pt-%s:' % did, '      entryPoints: [public-https]',
           "      rule: 'HostSNI(`%s`) || HostSNIRegexp(`^.+\\.%s$`)'" % (d, esc),
           '      tls:', '        passthrough: true', '      service: pt-%s' % did,
           '  services:', '    pt-%s:' % did, '      loadBalancer:', '        servers:',
           "          - address: '%s'" % hostport(a, https)]
    if proxy == 'on':
        out += ['        proxyProtocol:', '          version: 2']
    if http != '-' and pub_http != '0':
        entry = 'lan-http' if pub_http == '80' else 'public-http'
        out += ['http:', '  routers:', '    pt-%s-http:' % did, '      entryPoints: [%s]' % entry,
                "      rule: 'Host(`%s`) || HostRegexp(`^.+\\.%s$`)'" % (d, esc), '      service: pt-%s-http' % did,
                '  services:', '    pt-%s-http:' % did, '      loadBalancer:', '        passHostHeader: true', '        servers:',
                "          - url: 'http://%s'" % hostport(a, http)]
    return '\n'.join(out) + '\n'


def options(argv):
    opts, i = {}, 0
    while i < len(argv):
        if argv[i].startswith('--') and i + 1 < len(argv):
            opts[argv[i]] = argv[i + 1]
            i += 2
        else:
            usage()
    return opts


def main(argv):
    if len(argv) < 2:
        usage()
    cmd, rest = argv[1], argv[2:]
    if cmd == 'domain' and len(rest) == 1:
        print(norm_domain(rest[0]))
    elif cmd == 'address' and len(rest) == 5:
        o = options(rest[1:])
        print(check_address(rest[0], o.get('--host-addrs', os.devnull), o.get('--instance-addrs', os.devnull)))
    elif cmd == 'port' and len(rest) == 1:
        print(check_port(rest[0]))
    elif cmd == 'guard' and len(rest) >= 1 and len(rest) % 2 == 1:
        guard(norm_domain(rest[0]), options(rest[1:]))
    elif cmd == 'render' and len(rest) == 6:
        d, a, https, http, proxy, pub = rest
        if not DOM.fullmatch(d) or parse_ip(a) is None or proxy not in ('on', 'off') or not re.fullmatch(r'[0-9]{1,5}', pub):
            usage()
        check_port(https)
        if http != '-':
            check_port(http)
        if chr(10) in a or parse_ip(a) is None:
            usage()
        try:
            sys.stdout.write(render(d, str(parse_ip(a)), https, http, proxy, pub))
        except ValueError:
            usage()
    elif cmd == 'list' and len(rest) == 1:
        for row in list_rows(rest[0]):
            sys.stdout.write('\t'.join(row) + '\n')
    else:
        usage()


if __name__ == '__main__':
    main(sys.argv)
