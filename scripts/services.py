#!/usr/bin/env python3
"""Service descriptors and the plan of the reconciler (docs/PLAN-modular-core.md step 4). stdlib only, no side effects except
the descriptor files: everything it needs from the system (the proxy's routes, container addresses) comes in as files.

A descriptor is /var/lib/hs/services.d/<name>.toml (--dir DIR):
  name = "jellyfin"          unique, [a-z0-9-]; the default host label
  title = "Jellyfin"         tile text (default: the name)
  container = "jellyfin"     Incus instance; its address is looked up when needed, never stored
  host = "10.10.10.50"       instead of container: a target that is not an Incus instance
  port = 8096   scheme = "http"|"https"
  names = ["jellyfin"]       host labels wanted on proxies (label.domain for each domain of the proxy)
  fqdn = ["media.example.org"]   full names, used as they are
  exposure = "never-public" | "private-ok" | "public-ok"
  public_paths = ["/status"]  on a public proxy only these paths lead to the service (the root is a dead end)
  icon, health               optional
  [want] reverse-proxy = true  dns = true  dashboard = true ...   what is wanted from which provider

  services.py list     [--dir D]                        name, title, target, exposure, names, wants (TSV)
  services.py check    [--dir D]                        problems in the descriptors, one per line; exit 1 when there are some
  services.py add NAME [--dir D] --port N (--container C | --host H) [--title T] [--scheme S] [--names a,b] [--fqdn x,y]
                       [--exposure E] [--public-path /p]... [--want a,b] [--icon I] [--health /]
  services.py declare NAME [--dir D] (what a recipe says: --container C --port N --title T --icon I --group G --description D --exposure E
                       --want a,b --public-name x.y; an existing service keeps what a person decided)  prints created or updated
  services.py tiles  [--dir D] [--addrs F] [--plan F] [--info F] [--containers] [--local-domain D] group, title, link, description, icon, name of the dashboard tiles
  services.py remove NAME [--dir D]
  services.py plan   --info F --routes F --addrs F [--owned F] [--dir D]   act<TAB>host<TAB>path<TAB>target<TAB>service<TAB>note
  services.py import --info F --routes F --addrs F [--dir D] [--write]   create|skip<TAB>name<TAB>target<TAB>exposure<TAB>names<TAB>note

Files: --info = key<TAB>value (public yes|no, domains a,b, mode, name); --routes = host path target id; --addrs = container ip.
plan acts: ok, add, change, confirm (add of a public-ok service on a public proxy: needs a typed confirmation), blocked,
violation (a route that exists although the guard forbids it), unresolved (no address), unmanaged (a route no descriptor owns),
remove (a route hs made or adopted that no service wants any more; --owned lists the routes hs made or adopted).
The guard: on a public proxy a never-public or private-ok service gets no route; a public-ok one needs the confirmation.
"""
import os
import re
import sys
import tomllib

EXPOSURES = ('never-public', 'private-ok', 'public-ok')
WANTS = ('reverse-proxy', 'local-proxy', 'dns', 'dashboard', 'monitoring', 'private-access')
NAME = re.compile(r'^[a-z0-9][a-z0-9-]{0,40}$')
LABEL = re.compile(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?$')
FQDN = re.compile(r'^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$')
HOST = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,100}$')
DEAD_END = '127.0.0.1:1'
# containers whose web page is an admin interface: found on a public proxy they are imported as never-public
# (or public-ok with only their public paths), the way CLAUDE.md describes the two exceptions (Arcane webhook, Kuma status page)
ADMIN_TARGETS = {('docker', 80), ('homepage', 80), ('zoraxy', 8000), ('monitoring', 3000), ('monitoring', 80), ('uptime-kuma', 3001), ('paperclip', 3100), ('stalwart', 8080)}


def die(msg, code=2):
    print('services: ' + msg, file=sys.stderr)
    sys.exit(code)


def opt(args, name, default=None):
    if name in args:
        i = args.index(name)
        if i + 1 >= len(args):
            die('%s needs a value' % name)
        v = args[i + 1]
        del args[i:i + 2]
        return v
    return default


def opts(args, name):
    out = []
    while name in args:
        out.append(opt(args, name))
    return out


def flag(args, name):
    if name in args:
        args.remove(name)
        return True
    return False


# ── descriptors ─────────────────────────────────────────────────────────────

def load_all(d):
    out = {}
    if not os.path.isdir(d):
        return out
    for f in sorted(os.listdir(d)):
        if f.endswith('.toml'):
            p = os.path.join(d, f)
            try:
                with open(p, 'rb') as fh:
                    out[f[:-5]] = tomllib.load(fh)
            except (tomllib.TOMLDecodeError, OSError) as e:
                out[f[:-5]] = {'_error': str(e)}
    return out


def problems(fname, s):
    p = []
    if '_error' in s:
        return ['%s: does not parse: %s' % (fname, s['_error'])]
    if s.get('name') != fname:
        p.append('%s: name must be %s' % (fname, fname))
    if not NAME.match(str(s.get('name', ''))):
        p.append('%s: name must be lower case letters, digits and -' % fname)
    if bool(s.get('container')) == bool(s.get('host')):
        p.append('%s: give exactly one of container and host' % fname)
    if s.get('host') and not HOST.match(str(s['host'])):
        p.append('%s: host is not a host name or address' % fname)
    port = s.get('port')
    if not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65535:
        p.append('%s: port must be 1 to 65535' % fname)
    if s.get('scheme', 'http') not in ('http', 'https'):
        p.append('%s: scheme must be http or https' % fname)
    if s.get('exposure', 'private-ok') not in EXPOSURES:
        p.append('%s: exposure must be one of %s' % (fname, ', '.join(EXPOSURES)))
    # an admin page (Arcane, Homepage, Zoraxy's page, Grafana, Kuma's dashboard) is never public-ok as a whole, only through its public_paths
    if s.get('exposure') == 'public-ok' and not s.get('public_paths') and (s.get('container'), s.get('port')) in ADMIN_TARGETS:
        p.append('%s: %s:%s is an admin page and has no login of its own that can be trusted on the internet: use never-public, or give it public_paths (CLAUDE.md: no Zoraxy rule for admin pages)'
                 % (fname, s.get('container'), s.get('port')))
    for k in ('title', 'icon', 'group', 'description', 'health'):
        if k in s and (not isinstance(s[k], str) or len(s[k]) > 160):
            p.append('%s: %s must be a short text' % (fname, k))
    for n in s.get('names', [fname]):
        if not isinstance(n, str) or not LABEL.match(n):
            p.append('%s: name label %r is not a host label' % (fname, n))
    for n in s.get('fqdn', []):
        if not isinstance(n, str) or not FQDN.match(n):
            p.append('%s: fqdn %r is not a full name' % (fname, n))
    for x in s.get('public_paths', []):
        if not isinstance(x, str) or not re.match(r'^/[A-Za-z0-9._/-]*$', x) or '..' in x:
            p.append('%s: public path %r is not a path' % (fname, x))
    w = s.get('want', {})
    if not isinstance(w, dict) or any(k not in WANTS or not isinstance(v, bool) for k, v in w.items()):
        p.append('%s: want may only hold %s, each true or false' % (fname, ', '.join(WANTS)))
    return p


def q(v):
    return '"' + str(v).replace('\\', '\\\\').replace('"', '\\"') + '"'


def dump(s):
    lines = []
    for k in ('name', 'title', 'container', 'host', 'port', 'scheme', 'names', 'fqdn', 'exposure', 'public_paths', 'icon', 'group', 'description', 'health'):
        if k not in s:
            continue
        v = s[k]
        if isinstance(v, list):
            lines.append('%s = [%s]' % (k, ', '.join(q(x) for x in v)))
        elif isinstance(v, int):
            lines.append('%s = %d' % (k, v))
        else:
            lines.append('%s = %s' % (k, q(v)))
    if s.get('want'):
        lines.append('')
        lines.append('[want]')
        for k, v in s['want'].items():
            lines.append('%s = %s' % (k, 'true' if v else 'false'))
    return '\n'.join(lines) + '\n'


def write(d, s):
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, s['name'] + '.toml')
    tmp = path + '.tmp-%d' % os.getpid()
    with open(tmp, 'w', encoding='utf-8', newline='\n') as f:
        f.write(dump(s))
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def target_of(s):
    return '%s:%s' % (s.get('container') or s.get('host'), s.get('port'))


def cmd_list(d):
    for name, s in load_all(d).items():
        if '_error' in s:
            print('\t'.join([name, name, '(unreadable)', '-', '-', '-']))
            continue
        want = ','.join(k for k, v in s.get('want', {}).items() if v) or '-'
        print('\t'.join([name, s.get('title', name), target_of(s), s.get('exposure', 'private-ok'),
                         ','.join(s.get('names', [name])) or '-', want]))


def cmd_check(d):
    bad = []
    for name, s in load_all(d).items():
        bad += problems(name, s)
    for line in bad:
        print(line)
    return 1 if bad else 0


def cmd_add(d, args):
    name = args.pop(0) if args and not args[0].startswith('--') else die('add needs a name')
    s = {'name': name}
    title = opt(args, '--title')
    container, host = opt(args, '--container'), opt(args, '--host')
    port = opt(args, '--port')
    if title:
        s['title'] = title
    if container:
        s['container'] = container
    if host:
        s['host'] = host
    try:
        s['port'] = int(port) if port is not None else None
    except ValueError:
        die('port must be a number')
    sch = opt(args, '--scheme')
    if sch:
        s['scheme'] = sch
    names = opt(args, '--names')
    if names:
        s['names'] = [x for x in names.split(',') if x]
    fq = opt(args, '--fqdn')
    if fq:
        s['fqdn'] = [x for x in fq.split(',') if x]
    s['exposure'] = opt(args, '--exposure', 'private-ok')
    paths = opts(args, '--public-path')
    if paths:
        s['public_paths'] = paths
    for key, o in (('icon', '--icon'), ('group', '--group'), ('description', '--description'), ('health', '--health')):
        v = opt(args, o)
        if v:
            s[key] = v
    wants = opt(args, '--want')
    if wants:
        s['want'] = {k: True for k in wants.split(',') if k}
    if args:
        die('unknown option %s' % args[0])
    bad = problems(name, s)
    if bad:
        print('\n'.join(bad), file=sys.stderr)
        return 1
    if os.path.exists(os.path.join(d, name + '.toml')):
        print('%s exists already' % name, file=sys.stderr)
        return 3
    write(d, s)
    return 0


def cmd_remove(d, args):
    name = args[0] if args else die('remove needs a name')
    if not NAME.match(name):
        die('bad name')
    path = os.path.join(d, name + '.toml')
    if not os.path.exists(path):
        print('%s is not a service' % name, file=sys.stderr)
        return 3
    os.remove(path)
    return 0


# ── reading what the system tells ──────────────────────────────────────────

def read_info(path):
    info = {}
    with open(path, encoding='utf-8') as f:
        for line in f:
            if '\t' in line:
                k, v = line.rstrip('\n').split('\t', 1)
                info[k] = v
    info['domains'] = [x for x in info.get('domains', '').split(',') if x]
    info['public'] = info.get('public', 'yes') == 'yes'
    return info


def read_routes(path, keep_https=False):
    out = []
    with open(path, encoding='utf-8') as f:
        for line in f:
            c = line.rstrip('\n').split('\t')
            if len(c) >= 3 and c[0]:
                out.append((c[0].lower(), c[1] or '/', norm_target(c[2], keep_https), c[3] if len(c) > 3 else ''))
    return out


def read_owned(path):
    """routes hs made or adopted (host<TAB>path per line): the only ones it may change or remove"""
    out = set()
    if path and os.path.exists(path):
        with open(path, encoding='utf-8') as f:
            for line in f:
                c = line.rstrip('\n').split('\t')
                if len(c) >= 2 and c[0]:
                    out.add((c[0].lower(), c[1] or '/'))
    return out


def read_addrs(path):
    out = {}
    with open(path, encoding='utf-8') as f:
        for line in f:
            c = line.rstrip('\n').split('\t')
            if len(c) >= 2 and c[0]:
                out[c[0]] = c[1]
    return out


def norm_target(t, keep_https=False):
    """host:port of a target, without scheme and path (a missing port is 80); keep_https: the local slot keeps https://"""
    t = t.strip()
    https = keep_https and t.startswith('https://')
    t = re.sub(r'^https?://', '', t)
    t = t.split('/')[0]
    t = t if re.search(r':[0-9]+$', t) else t + ':80'
    return 'https://' + t if https else t


def desired_hosts(s, info, slot='public'):
    if slot == 'local':   # fqdn is a public name: the local slot only has <label>.<local domain>
        return list(dict.fromkeys('%s.%s' % (n, dom) for n in s.get('names', [s['name']]) for dom in info['domains']))
    hosts = ['%s.%s' % (n, dom) for n in s.get('names', [s['name']]) for dom in info['domains']]
    return list(dict.fromkeys(hosts + list(s.get('fqdn', []))))


def address_of(s, addrs):
    if s.get('host'):
        return s['host']
    return addrs.get(s.get('container'))


# ── the plan ───────────────────────────────────────────────────────────────

def make_plan(d, info, routes, addrs, owned=frozenset(), slot='public', explicit=None):
    want_key = 'reverse-proxy' if slot == 'public' else 'local-proxy'
    explicit = explicit or {}
    have = {(h, p): (t, i) for h, p, t, i in routes}
    claimed, out, wants = set(), [], {}
    for name, s in load_all(d).items():
        if '_error' in s or problems(name, s):
            out.append(('invalid', '-', '-', '-', name, 'fix the descriptor: hs services check'))
            continue
        if not s.get('want', {}).get(want_key):
            continue
        exposure = s.get('exposure', 'private-ok')
        ip = address_of(s, addrs)
        hosts = desired_hosts(s, info, slot)
        if not hosts:
            if slot == 'local':
                out.append(('blocked', '-', '-', '-', name, 'no local domain: the gateway proxy needs adDomain in machine.toml'))
            else:
                out.append(('blocked', '-', '-', '-', name, 'no host name: the proxy has no domain (hs config set proxyDomains) and the service no fqdn'))
            continue
        if info['public'] and exposure != 'public-ok':
            why = 'never-public' if exposure == 'never-public' else 'private-ok'
            for h in hosts:
                for (hh, pp), (tt, _) in have.items():
                    if hh == h:
                        claimed.add((hh, pp))
                        out.append(('violation', hh, pp, tt, name, '%s service has a route on the public proxy' % why))
                if not any(hh == h for hh, _ in have):
                    out.append(('blocked', h, '/', '-', name, '%s: no route on the public proxy %s' % (why, info.get('name', ''))))
            continue
        if ip is None:
            out.append(('unresolved', ','.join(hosts), '-', '-', name, 'no address for %s (is it running?)' % s.get('container')))
            continue
        target = '%s:%s' % (ip, s['port'])
        if slot == 'local' and s.get('scheme') == 'https':
            target = 'https://' + target
        paths = s.get('public_paths', []) if info['public'] and slot == 'public' else []
        for h in hosts:
            wanted = [('/', DEAD_END)] + [(p, target) for p in paths] if paths else [('/', target)]
            for p, t in wanted:
                cur = wants.get((h, p))
                if cur is None or (cur[0] == DEAD_END and t != DEAD_END):
                    wants[(h, p)] = (t, name)   # a real root beats the dead end that a services with only paths wants for the same host
                elif cur[0] != t and t != DEAD_END:
                    out.append(('conflict', h, p, t, name, 'also wanted by %s with %s' % (cur[1], cur[0])))
    for (h, p), (t, name) in wants.items():
        claimed.add((h, p))
        if (h, p) not in have:
            act = 'confirm' if info['public'] else 'add'
            note = 'public-ok on a public proxy: needs a typed confirmation' if act == 'confirm' else ''
            if h in explicit:
                note = 'an explicit DNS record %s beats the wildcard: this name goes straight to %s, not through the gateway' % (h, explicit[h])
            out.append((act, h, p, t, name, note))
        elif have[(h, p)][0] != t:
            out.append(('change', h, p, t, name, 'now %s%s' % (have[(h, p)][0], '' if (h, p) in owned else '; not made by hs: adopt it first (hs services adopt)')))
        else:
            note = '' if (h, p) in owned else 'not adopted (hs services adopt)'
            if h in explicit:
                note = 'an explicit DNS record %s beats the wildcard: this name goes straight to %s, not through the gateway' % (h, explicit[h])
            out.append(('ok', h, p, t, name, note))
    for (h, p), (t, i) in sorted(have.items()):
        if (h, p) not in claimed:
            if (h, p) in owned:
                out.append(('remove', h, p, t, '-', 'made by hs and no service wants it any more'))
            else:
                out.append(('unmanaged', h, p, t, '-', 'the default site of the proxy' if h == '*' else 'no service owns this route'))
    return out


# ── import ─────────────────────────────────────────────────────────────────

def make_import(d, info, routes, addrs):
    """Services out of the routes. A host has a root route and maybe more routes by path:
       - a real root target is one service (an admin page on a public proxy: never-public, else public-ok);
       - paths to ANOTHER real target are a service of their own with those public_paths (Matrix and the Kuma status page on one apex host,
         JMAP next to the webmail);
       - a path to the dead end 127.0.0.1:1 only blocks that path and a path to the root's own target adds nothing: both are left out;
       - the default site (host *) is no service."""
    by_ip = {v: k for k, v in addrs.items()}
    existing = load_all(d)
    hosts = {}
    for h, p, t, _ in routes:
        if h == '*':
            continue
        g = hosts.setdefault(h, {'root': None, 'paths': {}})
        if p == '/':
            g['root'] = t
        else:
            g['paths'].setdefault(t, []).append(p)
    found = {}
    def add(h, target, exposure, paths):
        host_, _, port = target.rpartition(':')
        ct = by_ip.get(host_)
        label, _, dom = h.partition('.')
        kind, val = ('names', label) if dom in info['domains'] else ('fqdn', h)
        key = (ct or host_, int(port), exposure, tuple(paths))
        e = found.setdefault(key, {'container': ct, 'host': None if ct else host_, 'port': int(port), 'exposure': exposure,
                                   'paths': list(paths), 'names': [], 'fqdn': [], 'hosts': []})
        if val not in e[kind]:
            e[kind].append(val)
        e['hosts'].append(h)
    for h, g in sorted(hosts.items()):
        root = g['root']
        if root and root != DEAD_END:
            ct = by_ip.get(root.rpartition(':')[0])
            port = int(root.rpartition(':')[2])
            if not info['public']:
                exposure = 'private-ok'
            elif (ct, port) in ADMIN_TARGETS:
                exposure = 'never-public'
            else:
                exposure = 'public-ok'
            add(h, root, exposure, [])
        for t, ps in sorted(g['paths'].items()):
            if t in (DEAD_END, root) or not info['public']:
                continue
            add(h, t, 'public-ok', sorted(ps))
    rows = []
    clean = lambda x: re.sub(r'[^a-z0-9-]', '-', x.lower()).strip('-') or 'service'
    for key, e in found.items():
        label = (e['names'] or e['fqdn'] or ['service'])[0].split('.')[0]
        shared = sum(1 for x in found.values() if x['container'] and x['container'] == e['container']) > 1
        base = clean(e['container'] or label)
        taken = {r[1] for r in rows}
        # the container's name; when several services live in one container, each is named by its own host label; then a number
        name = next((c for c in ((clean(label), base) if shared else (base, clean(label))) if c not in taken), None)
        i = 2
        while name is None:
            name = '%s-%d' % (base, i) if '%s-%d' % (base, i) not in taken else None
            i += 1
        s = {'name': name, 'title': name[:1].upper() + name[1:], 'port': e['port'], 'exposure': e['exposure']}
        if e['container']:
            s['container'] = e['container']
        else:
            s['host'] = e['host']
        if e['names']:
            s['names'] = e['names']
        if e['fqdn']:
            s['fqdn'] = e['fqdn']
        if e['paths']:
            s['public_paths'] = e['paths']
        s['want'] = {'reverse-proxy': True}
        if e['paths']:
            note = 'only its public paths are routed'
        elif e['exposure'] == 'never-public':
            note = 'an admin page: it should not be public (plan shows its route as a violation)'
        elif e['exposure'] == 'public-ok':
            note = 'is public today: check that it should be'
        else:
            note = ''
        if name in existing:
            rows.append(('skip', name, target_of(s), e['exposure'], ','.join(e['hosts']), 'a service of that name exists', s))
        else:
            rows.append(('create', name, target_of(s), e['exposure'], ','.join(e['hosts']), note, s))
    return rows


def read_explicit(path):
    """name -> value of the DNS records that exist (hs sys dns list: name TAB type TAB value): an explicit record beats the wildcard"""
    out = {}
    if path and os.path.exists(path):
        with open(path, encoding='utf-8') as f:
            for line in f:
                c = line.rstrip('\n').split('\t')
                if len(c) >= 3 and c[0] and not c[0].startswith('*'):
                    out[c[0].lower()] = c[2]
    return out


def make_local_import(d):
    """the migration: every valid descriptor without a local-proxy want gets local-proxy = true (a person's false stays).
       Rows: (act, service, names, target, descriptor); act is enable."""
    rows = []
    for name, s in load_all(d).items():
        if '_error' in s or problems(name, s) or 'local-proxy' in s.get('want', {}):
            continue
        rows.append(('enable', name, ','.join(s.get('names', [name])), target_of(s), s))
    return rows


def cmd_declare(d, args):
    """What a recipe says about its service. New: written as it says (exposure default private-ok). Existing: the facts the recipe knows
    (container, port, title, icon, group, description, scheme) are refreshed; what a person decided (exposure, names, fqdn, public_paths,
    any `want` that is already set) is never touched; a `want` the descriptor does not have yet is added. The one exception is
    --public-name <full name>: the person said (in the recipe's question) that the service has that public name. It becomes the fqdn and a
    private-ok service becomes public-ok (never-public stays; a route still needs `hs services apply`, which asks for the typed host name)."""
    name = args.pop(0) if args and not args[0].startswith('--') else die('declare needs a name')
    new = {}
    for key, o in (('title', '--title'), ('container', '--container'), ('host', '--host'), ('scheme', '--scheme'), ('icon', '--icon'),
                   ('group', '--group'), ('description', '--description'), ('health', '--health'), ('exposure', '--exposure')):
        v = opt(args, o)
        if v:
            new[key] = v
    port = opt(args, '--port')
    if port is not None:
        try:
            new['port'] = int(port)
        except ValueError:
            die('port must be a number')
    wants = opt(args, '--want')
    new_want = {k: True for k in (wants or '').split(',') if k}
    public_name = opt(args, '--public-name')
    if args:
        die('unknown option %s' % args[0])
    existing = load_all(d).get(name)
    if existing and '_error' not in existing:
        s = dict(existing)
        for k in ('title', 'container', 'host', 'port', 'scheme', 'icon', 'group', 'description', 'health'):
            if k in new:
                s[k] = new[k]
        if 'container' in new:
            s.pop('host', None)
        if 'host' in new:
            s.pop('container', None)
        want = dict(s.get('want', {}))
        for k, v in new_want.items():
            want.setdefault(k, v)
        if want:
            s['want'] = want
        if public_name:
            s['fqdn'] = [public_name]
            if s.get('exposure', 'private-ok') == 'private-ok':
                s['exposure'] = 'public-ok'
        verb = 'updated'
    else:
        s = {'name': name}
        s.update(new)
        s.setdefault('exposure', 'private-ok')
        if public_name:
            s['fqdn'] = [public_name]
            if s['exposure'] == 'private-ok':
                s['exposure'] = 'public-ok'
        if new_want:
            s['want'] = new_want
        verb = 'created'
    bad = problems(name, s)
    if bad:
        print('\n'.join(bad), file=sys.stderr)
        return 1
    write(d, s)
    print(verb)
    return 0


def is_admin(s):
    return s.get('exposure') == 'never-public' or (s.get('container'), s.get('port')) in ADMIN_TARGETS


def cmd_set(d, args):
    """Change what a person decided about an existing service: --local yes|no (want.local-proxy), --public yes|no (want.reverse-proxy,
    fqdn, exposure private-ok <-> public-ok), --public-name FQDN (required with --public yes; alone it renames a public service).
    Routes are not touched: `hs services apply` makes them."""
    name = args.pop(0) if args and not args[0].startswith('--') else die('set needs a name')
    local, public, pname = opt(args, '--local'), opt(args, '--public'), opt(args, '--public-name')
    if args:
        die('unknown option %s' % args[0])
    for v in (local, public):
        if v not in (None, 'yes', 'no'):
            die('--local and --public take yes or no')
    if local is None and public is None and pname is None:
        die('set needs --local, --public or --public-name')
    s = load_all(d).get(name)
    if not s or '_error' in s:
        print("'%s' is not a service" % name, file=sys.stderr)
        return 1
    s = dict(s)
    want = dict(s.get('want', {}))
    if local is not None:
        want['local-proxy'] = local == 'yes'
    if public == 'yes' or (public is None and pname):
        if public is None and not want.get('reverse-proxy'):
            die('%s is not public: use --public yes with --public-name' % name)
        if is_admin(s) and not s.get('public_paths'):
            print('%s is an admin page, never public' % name, file=sys.stderr)
            return 1
        if not pname:
            die('--public yes needs --public-name <full name>')
        if not FQDN.match(pname):
            die('%r is not a full name' % pname)
        want['reverse-proxy'] = True
        s['fqdn'] = [pname]
        if s.get('exposure', 'private-ok') == 'private-ok':
            s['exposure'] = 'public-ok'
    elif public == 'no':
        want['reverse-proxy'] = False
        s.pop('fqdn', None)
        if s.get('exposure') == 'public-ok':
            s['exposure'] = 'private-ok'
    s['want'] = want
    bad = problems(name, s)
    if bad:
        print('\n'.join(bad), file=sys.stderr)
        return 1
    write(d, s)
    print('updated')
    return 0


def cmd_apps(d):
    """One row per service for the Apps page: name, container, title, local, public, fqdn, exposure, admin (no empty field)"""
    for name, s in load_all(d).items():
        if '_error' in s:
            continue
        w = s.get('want', {})
        print('\t'.join([name, s.get('container') or '-', s.get('title') or name, 'yes' if w.get('local-proxy') else 'no',
                         'yes' if w.get('reverse-proxy') else 'no', ','.join(s.get('fqdn', [])) or '-',
                         s.get('exposure', 'private-ok'), 'yes' if is_admin(s) else 'no']))
    return 0


def cmd_tiles(d, args):
    """The dashboard tiles: group, title, link, description, icon, name for every service that wants a dashboard tile (--containers: only
    the containers they live in). The link: the public host when the service is published on a public proxy, else (--local-domain D given and
    the service wants local-proxy) http://<first name or service name>.D, else the address and port. A service whose container is not running
    has no tile."""
    only_containers = flag(args, '--containers')
    addrs_f, plan_f, info_f = opt(args, '--addrs'), opt(args, '--plan'), opt(args, '--info')
    local_dom = opt(args, '--local-domain')
    services = {n: s for n, s in load_all(d).items() if '_error' not in s and not problems(n, s) and s.get('want', {}).get('dashboard')}
    if only_containers:
        for c in sorted({s['container'] for s in services.values() if s.get('container')}):
            print(c)
        return 0
    addrs = read_addrs(addrs_f) if addrs_f and os.path.exists(addrs_f) else {}
    public = True
    if info_f and os.path.exists(info_f):
        public = read_info(info_f)['public']
    hosts = {}
    if plan_f and os.path.exists(plan_f):
        with open(plan_f, encoding='utf-8') as f:
            for line in f:
                c = line.rstrip('\n').split('\t')
                if len(c) >= 5 and c[0] == 'ok' and c[2] == '/' and norm_target(c[3]) != DEAD_END:
                    hosts.setdefault(c[4], c[1])
    for name, s in services.items():
        ip = address_of(s, addrs)
        if name in hosts:
            href = ('https://' if public else 'http://') + hosts[name]
        elif ip and local_dom and s.get('want', {}).get('local-proxy'):
            href = 'http://%s.%s' % ((s.get('names') or [name])[0], local_dom)
        elif ip:
            scheme = s.get('scheme', 'http')
            href = '%s://%s%s' % (scheme, ip, '' if s['port'] in (80, 443) else ':%d' % s['port'])
        else:
            continue
        # no empty field: a reader that splits on tabs in bash (read) skips an empty one and shifts the rest, so an empty description is "-"
        print('\t'.join([s.get('group', 'Apps'), s.get('title', name), href, s.get('description') or '-', s.get('icon', 'mdi-application'), name]))
    return 0


def cmd_addrs():
    """`incus list --format json` on stdin -> container<TAB>address (the first global IPv4 of a running instance, eth0 or enp5s0 first)"""
    import json
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return 1
    for inst in data:
        if str(inst.get('status', '')).lower() != 'running':
            continue
        nets = ((inst.get('state') or {}).get('network') or {})
        order = [n for n in ('eth0', 'enp5s0') if n in nets] + [n for n in nets if n not in ('eth0', 'enp5s0', 'lo') and not n.startswith('docker')]
        for n in order:
            ips = [a['address'] for a in nets[n].get('addresses', []) if a.get('family') == 'inet' and a.get('scope') == 'global']
            if ips:
                print('%s\t%s' % (inst['name'], ips[0]))
                break
    return 0


def main(argv):
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(newline='\n', encoding='utf-8')
    args = argv[1:]
    if not args:
        print(__doc__.strip().split('\n\n')[0], file=sys.stderr)
        return 2
    cmd = args.pop(0)
    d = opt(args, '--dir', os.environ.get('HS_SERVICES_DIR') or os.path.join(os.environ.get('HS_STATE_DIR') or '/var/lib/hs', 'services.d'))
    if cmd == 'addrs':
        return cmd_addrs()
    if cmd == 'declare':
        return cmd_declare(d, args)
    if cmd == 'set':
        return cmd_set(d, args)
    if cmd == 'apps':
        return cmd_apps(d)
    if cmd == 'tiles':
        return cmd_tiles(d, args)
    if cmd == 'list':
        cmd_list(d)
        return 0
    if cmd == 'check':
        return cmd_check(d)
    if cmd == 'add':
        return cmd_add(d, args)
    if cmd == 'remove':
        return cmd_remove(d, args)
    if cmd in ('plan', 'import'):
        info_f, routes_f, addrs_f = opt(args, '--info'), opt(args, '--routes'), opt(args, '--addrs')
        do_write = flag(args, '--write')
        if cmd == 'import' and opt(args, '--slot', 'public') == 'local':   # the migration reads the descriptors only
            for row in make_local_import(d):
                *shown, s = row
                print('\t'.join(shown))
                if do_write:
                    s.setdefault('want', {})['local-proxy'] = True
                    write(d, s)
            return 0
        if not (info_f and routes_f and addrs_f):
            die('%s needs --info, --routes and --addrs' % cmd)
        owned_f = opt(args, '--owned')
        slot = opt(args, '--slot', 'public')
        explicit_f = opt(args, '--explicit')
        if slot not in ('public', 'local'):
            die('--slot must be public or local')
        info, routes, addrs = read_info(info_f), read_routes(routes_f, slot == 'local'), read_addrs(addrs_f)
        if cmd == 'plan':
            for row in make_plan(d, info, routes, addrs, read_owned(owned_f), slot, read_explicit(explicit_f)):
                print('\t'.join(row))
            return 0
        for row in make_import(d, info, routes, addrs):
            *shown, s = row
            print('\t'.join(shown))
            if do_write and row[0] == 'create':
                write(d, s)
        return 0
    die('unknown command %s' % cmd)


if __name__ == '__main__':
    sys.exit(main(sys.argv))
