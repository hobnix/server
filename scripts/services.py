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
  blocked_paths = ["/if/admin/"]  on a public proxy these paths of its hosts go to the dead end, even if the root is public
  auth = "authentik"         forward auth on the public proxy (the only value; the outpost is the service named authentik)
  auth_skip = ["/api"]       paths that bypass forward auth (needs auth)
  request_headers = ["X-Forwarded-Proto: https"]   set on the request to the service (at most 8)
  response_headers = ["Access-Control-Expose-Headers: User-Agent"]   set on the answer to the client (at most 8)
                             HEADERS ARE NOT SECRETS: the descriptor is world readable (0644); never put a token in a value
  cleared = ["auth"]         offers (auth, public_paths) a person switched off: declare does not set them again
  admin = true               written by declare for a never-public recipe: keeps the admin rule (public-ok needs public_paths) after the
                             exposure was raised for its public paths
  icon, health               optional
  [want] reverse-proxy = true  dns = true  dashboard = true ...   what is wanted from which provider

  services.py list     [--dir D]                        name, title, target, exposure, names, wants (TSV)
  services.py check    [--dir D]                        problems in the descriptors, one per line; exit 1 when there are some
  services.py add NAME [--dir D] --port N (--container C | --host H) [--title T] [--scheme S] [--names a,b] [--fqdn x,y]
                       [--exposure E] [--public-path /p]... [--blocked-path /p]... [--auth authentik|none] [--auth-skip /p]...
                       [--request-header 'N: v']... [--response-header 'N: v']... [--want a,b] [--icon I] [--health /]
  services.py declare NAME [--dir D] (what a recipe says: --container C --port N --title T --icon I --group G --description D --exposure E
                       --want a,b --public-name x.y --public-path /p --blocked-path /p --auth authentik --auth-skip /p --request-header 'N: v'
                       --response-header 'N: v' --admin; an existing service keeps what a person decided: exposure, public_paths and auth
                       are only set when absent; blocked paths, skips, headers and admin are the recipe's facts and replaced)  prints created or updated
                       --stat 'kind|label|path|pointer|reduce|where|secret|auth|unit|format' (repeatable, empty = unset; replaces the
                       service's [[stats]]; --no-stats removes them; neither keeps them)
  services.py stats-plan --addrs F [--meta] [--dir D]           service, index, url, secret, auth (TSV, `-` = none) of every stat to fetch
  services.py stat-value SERVICE INDEX [--dir D]        JSON on stdin -> the formatted value; exit 1 and no output when it does not fit
  [[stats]] (at most 3): kind="http-json" label path pointer reduce="count" where secret="stat-<name>" auth unit format; a secret is
  only NAMED here (the key lives in the state dir), never held
  services.py tiles  [--dir D] [--addrs F] [--plan F] [--info F] [--containers] [--local-domain D] group, title, link, description, icon, name of the dashboard tiles
  services.py remove NAME [--dir D]
  services.py plan   --info F --routes F --addrs F [--owned F] [--specs F] [--dir D]   act<TAB>host<TAB>path<TAB>target<TAB>service<TAB>note
  services.py hostspecs --info F --routes F --addrs F --host H [--owned F] [--specs F] [--dir D]   the host spec of H (route/auth/skip/reqh/resh lines, TSV; nothing = delete)
  services.py import --info F --routes F --addrs F [--dir D] [--write]   create|skip<TAB>name<TAB>target<TAB>exposure<TAB>names<TAB>note

Files: --info = key<TAB>value (public yes|no, domains a,b, mode, name, features paths,headers,auth; missing = paths); --routes = host path target id; --addrs = container ip.
plan acts: ok, add, change, confirm (add of a public-ok service on a public proxy: needs a typed confirmation), blocked,
manual (a header or forward auth the provider cannot make: --info features lacks headers/auth; a person sets it by hand),
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
AUTHS = ('authentik',)
AUTH_SERVICE = 'authentik'
CLEARABLE = ('auth', 'public_paths')   # the offers of a recipe that a person can switch off for good (key `cleared`)
OUTPOST_PATH = '/outpost.goauthentik.io'
PATH_RE = re.compile(r'/[A-Za-z0-9._/-]*')
HDR_NAME = re.compile(r'[A-Za-z0-9-]{1,64}')
HDR_VALUE = re.compile(r'[\x20-\x7e]{1,200}')
HDR_REFUSED = ('host', 'content-length', 'transfer-encoding', 'connection')
MAX_HEADERS = 8
MAX_STATS = 3
STAT_KEYS = ('kind', 'label', 'path', 'pointer', 'reduce', 'where', 'secret', 'auth', 'unit', 'format')
STAT_AUTHS = ('mediabrowser', 'x-api-key', 'bearer')
STAT_FORMATS = ('int', 'float1', 'text')
STAT_PATH = re.compile(r'^/[A-Za-z0-9._~/?&=%,-]{0,200}$')
STAT_SECRET = re.compile(r'^stat-[a-z0-9][a-z0-9-]{0,40}$')
POINTER = re.compile(r'^(/[^/]*)*$')
STAT_MAX_BODY = 1048576
# containers whose web page is an admin interface: found on a public proxy they are imported as never-public
# (or public-ok with only their public paths), the way CLAUDE.md describes the two exceptions (Arcane webhook, Kuma status page)
ADMIN_TARGETS = {('docker', 80), ('zoraxy', 8000), ('monitoring', 3000), ('monitoring', 80), ('uptime-kuma', 3001), ('paperclip', 3100), ('stalwart', 8080)}


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


def path_ok(x):
    return isinstance(x, str) and PATH_RE.fullmatch(x) is not None and '..' not in x


def header_problem(x):
    """why 'Name: value' is refused, or None"""
    if not isinstance(x, str) or ':' not in x:
        return 'is not Name: value'
    n, _, v = x.partition(':')
    v = v.strip()
    if not HDR_NAME.fullmatch(n):
        return 'has a bad name (letters, digits and - only, 64 at most)'
    if n.lower() in HDR_REFUSED:
        return 'may not set %s' % n
    if not HDR_VALUE.fullmatch(v):
        return 'has a bad value (printable ASCII, 1 to 200 characters, no line break)'
    return None


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
    # an admin page (Arcane, Zoraxy's page, Grafana, Kuma's dashboard, a recipe's never-public service) is never public-ok as a whole, only
    # through its public_paths (blocked_paths do not count: the root would still be public)
    if s.get('exposure') == 'public-ok' and not s.get('public_paths') and (s.get('admin') is True or (s.get('container'), s.get('port')) in ADMIN_TARGETS):
        p.append('%s: %s is an admin page and has no login of its own that can be trusted on the internet: use never-public, or give it public_paths (CLAUDE.md: no Zoraxy rule for admin pages)'
                 % (fname, 'it' if s.get('admin') is True else '%s:%s' % (s.get('container'), s.get('port'))))
    for k in ('title', 'icon', 'group', 'description', 'health'):
        if k in s and (not isinstance(s[k], str) or len(s[k]) > 160):
            p.append('%s: %s must be a short text' % (fname, k))
    for n in s.get('names', [fname]):
        if not isinstance(n, str) or not LABEL.match(n):
            p.append('%s: name label %r is not a host label' % (fname, n))
    for n in s.get('fqdn', []):
        if not isinstance(n, str) or not FQDN.match(n):
            p.append('%s: fqdn %r is not a full name' % (fname, n))
    lists = {}
    for k, label in (('public_paths', 'public path'), ('blocked_paths', 'blocked path'), ('auth_skip', 'auth_skip path')):
        v = s.get(k, [])
        if not isinstance(v, list):
            p.append('%s: %s must be a list' % (fname, k))
            continue
        lists[k] = v
        for x in v:
            if not path_ok(x):
                p.append('%s: %s %r is not a path' % (fname, label, x))
    seen = {}
    for k, v in lists.items():
        for x in v:
            if x in seen and seen[x] != k:
                p.append('%s: path %s is in both %s and %s' % (fname, x, seen[x], k))
            seen[x] = k
    if 'auth' in s and s['auth'] not in AUTHS:
        p.append('%s: auth must be one of %s' % (fname, ', '.join(AUTHS)))
    if s.get('auth_skip') and 'auth' not in s:
        p.append('%s: auth_skip needs auth' % fname)
    cl = s.get('cleared', [])
    if not isinstance(cl, list) or any(k not in CLEARABLE for k in cl):
        p.append('%s: cleared may only hold %s' % (fname, ', '.join(CLEARABLE)))
    if 'admin' in s and not isinstance(s['admin'], bool):
        p.append('%s: admin must be true or false' % fname)
    for k in ('request_headers', 'response_headers'):
        v = s.get(k, [])
        if not isinstance(v, list):
            p.append('%s: %s must be a list' % (fname, k))
            continue
        if len(v) > MAX_HEADERS:
            p.append('%s: at most %d %s' % (fname, MAX_HEADERS, k))
        for x in v:
            why = header_problem(x)
            if why:
                p.append('%s: %s entry %r %s' % (fname, k, x, why))
    w = s.get('want', {})
    if not isinstance(w, dict) or any(k not in WANTS or not isinstance(v, bool) for k, v in w.items()):
        p.append('%s: want may only hold %s, each true or false' % (fname, ', '.join(WANTS)))
    st = s.get('stats', [])
    if not isinstance(st, list) or any(not isinstance(x, dict) for x in st):
        p.append('%s: stats must be a list of [[stats]] tables' % fname)
    else:
        if len(st) > MAX_STATS:
            p.append('%s: at most %d stats' % (fname, MAX_STATS))
        for i, x in enumerate(st):
            p.extend(stat_problems(fname, i, x))
    return p


def stat_problems(fname, i, x):
    """The rules of one [[stats]] table (docs: a stat names a secret, it never holds a value)"""
    pre = '%s: stats[%d]' % (fname, i)
    p = []
    for k in x:
        if k not in STAT_KEYS:
            p.append('%s: unknown key %s' % (pre, k))

    def text(k, n):
        v = x.get(k)
        return isinstance(v, str) and len(v) <= n
    if x.get('kind') != 'http-json':
        p.append('%s: kind must be http-json' % pre)
    if not text('label', 24) or not x.get('label'):
        p.append('%s: label must be 1 to 24 characters' % pre)
    elif any(ord(c) < 32 or ord(c) == 127 for c in x['label']):
        p.append('%s: label has a control character' % pre)
    path = x.get('path')
    if not isinstance(path, str) or not STAT_PATH.match(path) or '//' in path or '@' in path or '..' in path:
        p.append('%s: path must start with / and use only A-Z a-z 0-9 . _ ~ / ? & = %% , - (no //, @, ..; 200 characters at most)' % pre)
    for k in ('pointer', 'where'):
        if k in x and (not isinstance(x[k], str) or not POINTER.match(x[k]) or len(x[k]) > 200):
            p.append('%s: %s must be a JSON pointer (empty or /a/b)' % (pre, k))
    if x.get('reduce', 'count') != 'count':
        p.append('%s: reduce may only be count' % pre)
    if 'where' in x and x.get('reduce') != 'count':
        p.append('%s: where needs reduce = "count"' % pre)
    if 'secret' in x and (not isinstance(x['secret'], str) or not STAT_SECRET.match(x['secret'])):
        p.append('%s: secret must be a name like stat-<service>' % pre)
    if x.get('auth') is not None and x['auth'] not in STAT_AUTHS:
        p.append('%s: auth must be one of %s' % (pre, ', '.join(STAT_AUTHS)))
    if 'secret' in x and 'auth' not in x:
        p.append('%s: secret needs auth' % pre)
    if 'auth' in x and 'secret' not in x:
        p.append('%s: auth needs secret' % pre)
    if 'unit' in x and not text('unit', 8):
        p.append('%s: unit must be 8 characters at most' % pre)
    if x.get('format', 'int') not in STAT_FORMATS:
        p.append('%s: format must be one of %s' % (pre, ', '.join(STAT_FORMATS)))
    return p


def q(v):
    return '"' + str(v).replace('\\', '\\\\').replace('"', '\\"') + '"'


def dump(s):
    lines = []
    for k in ('name', 'title', 'container', 'host', 'port', 'scheme', 'names', 'fqdn', 'exposure', 'public_paths', 'blocked_paths', 'auth', 'auth_skip',
              'request_headers', 'response_headers', 'admin', 'cleared', 'icon', 'group', 'description', 'health'):
        if k not in s:
            continue
        v = s[k]
        if isinstance(v, list):
            lines.append('%s = [%s]' % (k, ', '.join(q(x) for x in v)))
        elif isinstance(v, bool):   # before int: isinstance(True, int) is true
            lines.append('%s = %s' % (k, 'true' if v else 'false'))
        elif isinstance(v, int):
            lines.append('%s = %d' % (k, v))
        else:
            lines.append('%s = %s' % (k, q(v)))
    if s.get('want'):
        lines.append('')
        lines.append('[want]')
        for k, v in s['want'].items():
            lines.append('%s = %s' % (k, 'true' if v else 'false'))
    for x in s.get('stats', []):
        lines.append('')
        lines.append('[[stats]]')
        for k in STAT_KEYS:
            if k in x:
                lines.append('%s = %s' % (k, q(x[k])))
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


def take_proxy_opts(args, s):
    """--blocked-path, --auth authentik|none, --auth-skip, --request-header, --response-header (add and edit): the lists replace when given;
    --auth none drops auth and auth_skip"""
    for key, o in (('blocked_paths', '--blocked-path'), ('auth_skip', '--auth-skip'), ('request_headers', '--request-header'),
                   ('response_headers', '--response-header')):
        v = opts(args, o)
        if v:
            s[key] = v
    auth = opt(args, '--auth')
    if auth == 'none':
        s.pop('auth', None)
        s.pop('auth_skip', None)
        mark_cleared(s, 'auth')
    elif auth:
        s['auth'] = auth
        unmark_cleared(s, 'auth')


def mark_cleared(s, key):
    """a person switched an offer off (--auth none, --clear public-path): `cleared` remembers it so a later declare does not offer it again"""
    if key in CLEARABLE and key not in s.get('cleared', []):
        s['cleared'] = s.get('cleared', []) + [key]


def unmark_cleared(s, key):
    if key in s.get('cleared', []):
        s['cleared'] = [k for k in s['cleared'] if k != key]
        if not s['cleared']:
            del s['cleared']


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
        unmark_cleared(s, 'public_paths')
    take_proxy_opts(args, s)
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


EDIT_WANTS = ('reverse-proxy', 'dashboard')   # the wants the edit form owns; every other want of the file stays as it is
EDIT_CLEAR = {'title': 'title', 'icon': 'icon', 'group': 'group', 'description': 'description', 'names': 'names', 'public-path': 'public_paths',
              'blocked-path': 'blocked_paths', 'auth': 'auth', 'auth-skip': 'auth_skip', 'request-header': 'request_headers', 'response-header': 'response_headers'}


def cmd_edit(d, args):
    """Change a described service: only the options given change, everything else in the file stays (fqdn, scheme, health, wants the form
    does not own). --clear <title|icon|group|description|names|public-path|blocked-path|auth|auth-skip|request-header|response-header> drops that key
    (auth also drops auth_skip). --want names the wants of EDIT_WANTS that are
    on; one of them that was in the file and is not named becomes false. Nothing is sent to the proxy: `apply` does that."""
    name = args.pop(0) if args and not args[0].startswith('--') else die('edit needs a name')
    existing = load_all(d).get(name)
    if not existing or '_error' in existing:
        print('%s is not a service' % name, file=sys.stderr)
        return 3
    s = dict(existing)
    container, host = opt(args, '--container'), opt(args, '--host')
    if container and host:
        die('give a container or a host, not both')
    if container:
        s['container'] = container
        s.pop('host', None)
    if host:
        s['host'] = host
        s.pop('container', None)
    port = opt(args, '--port')
    if port is not None:
        try:
            s['port'] = int(port)
        except ValueError:
            die('port must be a number')
    for key, o in (('title', '--title'), ('scheme', '--scheme'), ('exposure', '--exposure'), ('icon', '--icon'), ('group', '--group'),
                   ('description', '--description'), ('health', '--health')):
        v = opt(args, o)
        if v:
            s[key] = v
    names = opt(args, '--names')
    if names:
        s['names'] = [x for x in names.split(',') if x]
    fq = opt(args, '--fqdn')
    if fq:
        s['fqdn'] = [x for x in fq.split(',') if x]
    paths = opts(args, '--public-path')
    if paths:
        s['public_paths'] = paths
        unmark_cleared(s, 'public_paths')
    take_proxy_opts(args, s)
    wants = opt(args, '--want')
    if wants is not None:
        named = {k for k in wants.split(',') if k and k != 'none'}   # `none`: the form switched every want it owns off
        want = dict(s.get('want', {}))
        for k in EDIT_WANTS:
            if k in named:
                want[k] = True
            elif k in want:
                want[k] = False
        for k in named - set(EDIT_WANTS):
            want[k] = True
        s['want'] = want
    for c in opts(args, '--clear'):
        if c not in EDIT_CLEAR:
            die('--clear takes one of %s' % ', '.join(EDIT_CLEAR))
        s.pop(EDIT_CLEAR[c], None)
        if c == 'auth':
            s.pop('auth_skip', None)   # the skips mean nothing without auth
        if c in ('auth', 'public-path'):
            mark_cleared(s, EDIT_CLEAR[c])
    if args:
        die('unknown option %s' % args[0])
    bad = problems(name, s)
    if bad:
        print('\n'.join(bad), file=sys.stderr)
        return 1
    write(d, s)
    return 0


def cmd_show(d, args):
    """One service as key<TAB>value lines (the edit form reads them): name, title, where (container|host), machine, port, scheme, names, fqdn,
    exposure, public_paths, blocked_paths, auth, auth_skip, request_headers, response_headers (headers joined with ' | '), icon, group,
    description, health, want. A list is comma separated; - when empty."""
    name = args[0] if args else die('show needs a name')
    s = load_all(d).get(name)
    if not s or '_error' in s:
        print('%s is not a service' % name, file=sys.stderr)
        return 3
    def val(v):
        v = ','.join(v) if isinstance(v, list) else v
        return str(v).replace('\t', ' ').replace('\n', ' ') if v not in (None, '') else '-'
    rows = [('name', name), ('title', s.get('title')), ('where', 'container' if s.get('container') else 'host'),
            ('machine', s.get('container') or s.get('host')), ('port', s.get('port')), ('scheme', s.get('scheme', 'http')),
            ('names', s.get('names', [name])), ('fqdn', s.get('fqdn')), ('exposure', s.get('exposure', 'private-ok')),
            ('public_paths', s.get('public_paths')), ('blocked_paths', s.get('blocked_paths')), ('auth', s.get('auth')),
            ('auth_skip', s.get('auth_skip')), ('request_headers', ' | '.join(s.get('request_headers', []))),
            ('response_headers', ' | '.join(s.get('response_headers', []))), ('icon', s.get('icon')), ('group', s.get('group')),
            ('description', s.get('description')), ('health', s.get('health')),
            ('want', [k for k, v in s.get('want', {}).items() if v])]
    for k, v in rows:
        print('%s\t%s' % (k, val(v)))
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
    info['features'] = {x for x in info.get('features', 'paths').split(',') if x} or {'paths'}   # what the provider can render
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
    if s.get('fqdn') and 'names' not in s:   # a public name replaces the default <name>.<domain> label on the public proxy
        return list(dict.fromkeys(s['fqdn']))
    hosts = ['%s.%s' % (n, dom) for n in s.get('names', [s['name']]) for dom in info['domains']]
    return list(dict.fromkeys(hosts + list(s.get('fqdn', []))))


def address_of(s, addrs):
    if s.get('host'):
        return s['host']
    return addrs.get(s.get('container'))


# ── the plan ───────────────────────────────────────────────────────────────

SPEC_KINDS = ('route', 'auth', 'skip', 'reqh', 'resh')


def read_specs(path):
    """host -> set of host spec lines (TSV, without the host) from `provider specs` (host<TAB>line)"""
    out = {}
    if path and os.path.exists(path):
        with open(path, encoding='utf-8') as f:
            for line in f:
                h, _, rest = line.rstrip('\n').partition('\t')
                if h and rest:
                    out.setdefault(h.lower(), set()).add(rest)
    return out


def host_spec_lines(extra, wants, h):
    """the sorted host spec lines of host h (TSV): every winning route, then auth/skip/headers of the services (a duplicate header name: the last wins)"""
    lines = [('route', name, p, t) for (hh, p), (t, name, _) in wants.items() if hh == h]
    heads = {}
    for f in extra.get(h, []):
        if f[0] in ('reqh', 'resh'):
            heads[(f[0], f[1], f[2].lower())] = f
        else:
            lines.append(f)
    lines += heads.values()
    return sorted(('\t'.join(f) for f in lines), key=lambda x: (SPEC_KINDS.index(x.split('\t')[0]), x.split('\t')[1:]))


def make_plan(d, info, routes, addrs, owned=frozenset(), slot='public', explicit=None, specs_have=None, specs_out=None):
    want_key = 'reverse-proxy' if slot == 'public' else 'local-proxy'
    explicit = explicit or {}
    have = {(h, p): (t, i) for h, p, t, i in routes}
    claimed, out, wants, extra = set(), [], {}, {}
    features = info.get('features') or {'paths'}
    pname = (info.get('name') or 'the proxy').capitalize()
    services = load_all(d)

    def want(h, p, t, name, strong=False):
        """wants[(h, p)] = (target, service, strong). The dead end of a paths-only service's root is weak and loses to anything; a blocked
        path is strong: it beats a real target of another service (that one gets a conflict row), two real targets conflict as before."""
        cur = wants.get((h, p))
        if cur is None:
            wants[(h, p)] = (t, name, strong)
        elif slot != 'local' and cur[0] == t and t != DEAD_END and cur[1] != name and bool(services[cur[1]].get('auth')) != bool(services[name].get('auth')):
            # same target, but only one of the two asks for a login: whichever wins, the other's rule would be wrong or open
            out.append(('conflict', h, p, t, name, 'also wanted by %s with %s, but only one of them has auth' % (cur[1], cur[0])))
        elif cur[0] == t:
            wants[(h, p)] = (t, cur[1], cur[2] or strong)
        elif cur[0] == DEAD_END and not cur[2]:
            wants[(h, p)] = (t, name, strong)
        elif t == DEAD_END and not strong:
            pass
        elif t == DEAD_END:
            out.append(('conflict', h, p, cur[0], cur[1], 'blocked by %s' % name))
            wants[(h, p)] = (t, name, True)
        else:
            out.append(('conflict', h, p, t, name, 'also wanted by %s with %s' % (cur[1], cur[0])))

    for name, s in services.items():
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
        pub = info['public'] and slot == 'public'   # the new keys, like public_paths, are for a public proxy only
        paths = s.get('public_paths', []) if pub else []
        blocked = s.get('blocked_paths', []) if pub else []
        auth_target = None
        if pub and s.get('auth'):
            a = services.get(AUTH_SERVICE)
            aip = address_of(a, addrs) if a and '_error' not in a and not problems(AUTH_SERVICE, a) else None
            if not aip:   # never route a service that wants a login without the thing that asks for it
                out.append(('blocked', ','.join(hosts), '-', '-', name, 'auth needs the authentik service (hs recipe authentik)'))
                for h in hosts:
                    claimed.update(k for k in have if k[0] == h)
                continue
            auth_target = '%s:%s' % (aip, a['port'])
        for h in hosts:
            wanted = [('/', DEAD_END, False)] + [(p, target, False) for p in paths] if paths else [('/', target, False)]
            wanted += [(p, DEAD_END, True) for p in blocked]
            if auth_target and 'auth' in features:
                wanted.append((OUTPOST_PATH, auth_target, True))   # the callback of the login: owned by the service that has auth
            for p, t, strong in wanted:
                want(h, p, t, name, strong)
            if not pub:
                continue
            if specs_have is not None or specs_out is not None:
                ex = extra.setdefault(h, [])
                if auth_target and 'auth' in features:
                    ex.append(('auth', name, auth_target))
                    ex += [('skip', name, x) for x in s.get('auth_skip', [])]
                if 'headers' in features:
                    for kind, key in (('reqh', 'request_headers'), ('resh', 'response_headers')):
                        for x in s.get(key, []):
                            n, _, v = x.partition(':')
                            ex.append((kind, name, n.strip(), v.strip()))
            for kind, key in (('request', 'request_headers'), ('response', 'response_headers')):
                if 'headers' not in features:
                    for x in s.get(key, []):
                        out.append(('manual', h, '/', '-', name, '%s header %s (%s: set it by hand on this rule)' % (kind, x, pname)))
            if auth_target and 'auth' not in features:
                claimed.add((h, OUTPOST_PATH))   # the callback route a person made by hand belongs to this service, it is not unmanaged
                skip = s.get('auth_skip', [])
                out.append(('manual', h, '/', '-', name, 'forward auth to %s%s/auth/traefik%s (%s: set it by hand)'
                            % (auth_target, OUTPOST_PATH, ', skip ' + ','.join(skip) if skip else '', pname)))

    def nested(h, p, name):
        """the longest other path of ANOTHER service on this host that p lies inside (not the root), as a note"""
        best = None
        for (h2, p2), (_, name2, _) in wants.items():
            if h2 == h and name2 != name and p2 != '/' and p.startswith(p2.rstrip('/') + '/') and (best is None or len(p2) > len(best[0])):
                best = (p2, name2)
        return 'inside %s of %s: the longer path wins' % best if best else ''

    for (h, p), (t, name, _) in wants.items():
        claimed.add((h, p))
        if (h, p) not in have:
            act = 'confirm' if info['public'] else 'add'
            note = 'public-ok on a public proxy: needs a typed confirmation' if act == 'confirm' else ''
            if h in explicit:
                note = 'an explicit DNS record %s beats the wildcard: this name goes straight to %s, not through the gateway' % (h, explicit[h])
            out.append((act, h, p, t, name, '; '.join(x for x in (note, nested(h, p, name)) if x)))
        elif have[(h, p)][0] != t:
            out.append(('change', h, p, t, name, 'now %s%s' % (have[(h, p)][0], '' if (h, p) in owned else '; not made by hs: adopt it first (hs services adopt)')
                        + ('; ' + nested(h, p, name) if nested(h, p, name) else '')))
        else:
            note = '' if (h, p) in owned else 'not adopted (hs services adopt)'
            if h in explicit:
                note = 'an explicit DNS record %s beats the wildcard: this name goes straight to %s, not through the gateway' % (h, explicit[h])
            out.append(('ok', h, p, t, name, '; '.join(x for x in (note, nested(h, p, name)) if x)))
    for (h, p), (t, i) in sorted(have.items()):
        if (h, p) not in claimed:
            if (h, p) in owned:
                out.append(('remove', h, p, t, '-', 'made by hs and no service wants it any more'))
            else:
                out.append(('unmanaged', h, p, t, '-', 'the default site of the proxy' if h == '*' else 'no service owns this route'))
    if specs_have is not None or specs_out is not None:
        mine = {h: host_spec_lines(extra, wants, h) for h in {h for h, _ in wants}}
        if specs_out is not None:
            specs_out.update(mine)
        for h in sorted(set(mine) | set(specs_have or {})):
            rows = [r for r in out if h in r[1].split(',')]
            if specs_have is None or not rows or any(r[0] != 'ok' for r in rows) or set(mine.get(h, [])) == specs_have.get(h, set()):
                continue
            root = wants.get((h, '/'))
            first = next((n for (hh, _), (_, n, _) in wants.items() if hh == h), '-')
            out.append(('change', h, '/', root[0] if root else '-', root[1] if root else first, 'login or headers differ (hs services plan shows the rule)'))
    return out


# ── import ─────────────────────────────────────────────────────────────────

def make_import(d, info, routes, addrs, specs=None):
    """Services out of the routes. A host has a root route and maybe more routes by path:
       - a real root target is one service (an admin page on a public proxy: never-public, else public-ok);
       - paths to ANOTHER real target are a service of their own with those public_paths (Matrix and the Kuma status page on one apex host,
         JMAP next to the webmail);
       - a path to the dead end 127.0.0.1:1 under a real root is a blocked_path of the root's service; without a real root, and a path to the
         root's own target, add nothing and are left out;
       - the path /outpost.goauthentik.io to the address of the container authentik is `auth = "authentik"` of the root's service;
       - the default site (host *) is no service."""
    by_ip = {v: k for k, v in addrs.items()}
    specs = specs or {}
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
                                   'paths': list(paths), 'names': [], 'fqdn': [], 'hosts': [], 'blocked': [], 'auth': False,
                                   'skip': [], 'reqh': [], 'resh': []})
        if val not in e[kind]:
            e[kind].append(val)
        e['hosts'].append(h)
        return e
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
            re_ = add(h, root, exposure, [])
        else:
            re_ = None
        if re_ is not None and info['public']:
            # login and headers of the live host (provider specs: kind TAB service TAB ...); the route list alone cannot show them
            for line in sorted(specs.get(h, ())):
                c = line.split('\t')
                if c[0] == 'auth' and len(c) > 2 and by_ip.get(c[2].rpartition(':')[0]) == AUTH_SERVICE:
                    re_['auth'] = True
                elif c[0] == 'skip' and len(c) > 2 and path_ok(c[2]) and c[2] not in re_['skip']:
                    re_['skip'].append(c[2])
                elif c[0] in ('reqh', 'resh') and len(c) > 3:
                    hd = '%s: %s' % (c[2], c[3])
                    if hd not in re_[c[0]]:
                        re_[c[0]].append(hd)
        for t, ps in sorted(g['paths'].items()):
            if not info['public']:
                continue
            if t == DEAD_END:
                if re_ is not None:
                    re_['blocked'] += [x for x in sorted(ps) if path_ok(x) and x not in re_['blocked']]
                continue
            if t == root:
                continue
            if re_ is not None and by_ip.get(t.rpartition(':')[0]) == AUTH_SERVICE and OUTPOST_PATH in ps:
                re_['auth'] = True
                ps = [x for x in ps if x != OUTPOST_PATH]
            if ps:
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
        if e['blocked']:
            s['blocked_paths'] = e['blocked']
        if e['auth']:
            s['auth'] = 'authentik'
            if e['skip']:
                s['auth_skip'] = sorted(e['skip'])
        if e['reqh']:
            s['request_headers'] = e['reqh']
        if e['resh']:
            s['response_headers'] = e['resh']
        s['want'] = {'reverse-proxy': True}
        if e['paths']:
            note = 'only its public paths are routed'
        elif e['exposure'] == 'never-public':
            note = 'an admin page: it should not be public (plan shows its route as a violation)'
        elif e['exposure'] == 'public-ok':
            note = 'is public today: check that it should be'
        else:
            note = ''
        extra = ([('blocked: ' + ','.join(e['blocked']))] if e['blocked'] else []) + (['forward auth'] if e['auth'] else [])
        note = '; '.join(x for x in [note] + extra if x)
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
    (container, port, title, icon, group, description, scheme) are refreshed; what a person decided (exposure, names, fqdn, any `want` that
    is already set, and public_paths and auth, which a recipe only offers) is never touched; blocked_paths, auth_skip, request_headers,
    response_headers and admin are the recipe's facts and are replaced every run; a `want` the descriptor does not have yet is added. The one exception is
    --public-name <full name>: the person said (in the recipe's question) that the service has that public name. It becomes the fqdn and a
    private-ok service becomes public-ok (never-public stays, unless the service has public_paths: see raise_exposure; a route still needs `hs services apply`, which asks for the typed host name)."""
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
    offer = {}   # set only when the descriptor does not have the key (a person's choice stays)
    if opts_pp := opts(args, '--public-path'):
        offer['public_paths'] = opts_pp
    if auth := opt(args, '--auth'):
        offer['auth'] = auth
    facts = {}   # the recipe's own facts: replaced on every run (a recipe that stops saying one drops it)
    for key, o in (('blocked_paths', '--blocked-path'), ('auth_skip', '--auth-skip'), ('request_headers', '--request-header'),
                   ('response_headers', '--response-header')):
        if v := opts(args, o):
            facts[key] = v
    if flag(args, '--admin'):
        facts['admin'] = True
    stat_args = opts(args, '--stat')
    no_stats = flag(args, '--no-stats')
    if args:
        die('unknown option %s' % args[0])
    stats = None   # None: keep what the descriptor has
    if stat_args:
        stats = []
        for sa in stat_args:
            f = sa.split('|')
            if len(f) != len(STAT_KEYS):
                die('--stat needs %d fields: %s' % (len(STAT_KEYS), '|'.join(STAT_KEYS)))
            stats.append({k: v for k, v in zip(STAT_KEYS, f) if v != ''})
            if 'pointer' not in stats[-1]:
                stats[-1]['pointer'] = ''
    elif no_stats:
        stats = []
    existing = load_all(d).get(name)
    if existing and '_error' not in existing:
        s = dict(existing)
        if stats is not None:
            s.pop('stats', None)
            if stats:
                s['stats'] = stats
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
        for k, v in offer.items():
            if k not in s.get('cleared', []):   # a person switched it off (edit --auth none, --clear public-path): stays off
                s.setdefault(k, v)
        for k in ('blocked_paths', 'auth_skip', 'request_headers', 'response_headers', 'admin'):
            s.pop(k, None)
        s.update(facts)
        if 'auth' not in s:
            s.pop('auth_skip', None)   # auth was switched off (edit --auth none): its open paths mean nothing without it
        if public_name:
            s['fqdn'] = [public_name]
            raise_exposure(s, 'admin' in facts)   # only a recipe that says admin (never-public by its own design) may raise it
        verb = 'updated'
    else:
        s = {'name': name}
        s.update(new)
        s.setdefault('exposure', 'private-ok')
        s.update(offer)
        s.update(facts)
        if public_name:
            s['fqdn'] = [public_name]
            raise_exposure(s)
        if new_want:
            s['want'] = new_want
        if stats:
            s['stats'] = stats
        verb = 'created'
    bad = problems(name, s)
    if bad:
        print('\n'.join(bad), file=sys.stderr)
        return 1
    write(d, s)
    print(verb)
    return 0


def raise_exposure(s, recipe_admin=True):
    """--public-name: private-ok becomes public-ok; a never-public service that has public_paths becomes public-ok with admin = true (only
    its paths go public: the admin rule and the typed confirmation in apply stay); without public paths never-public stays"""
    exp = s.get('exposure', 'private-ok')
    if exp == 'private-ok':
        s['exposure'] = 'public-ok'
    elif exp == 'never-public' and s.get('public_paths') and recipe_admin:   # a never-public a person set stays so
        s['exposure'] = 'public-ok'
        s['admin'] = True


def is_admin(s):
    return s.get('exposure') == 'never-public' or s.get('admin') is True or (s.get('container'), s.get('port')) in ADMIN_TARGETS


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


def cmd_stats_plan(d, args):
    """service<TAB>index<TAB>url<TAB>secret<TAB>auth for every stat of a valid service whose address is known. The url comes from the
    descriptor's own target only (nothing a person or the network says); `-` for no secret."""
    addrs_f = opt(args, '--addrs')
    with_label = flag(args, '--meta')   # two more columns: label and unit (hs services stats shows them)
    if args or not addrs_f:
        die('stats-plan needs --addrs F')
    addrs = read_addrs(addrs_f) if os.path.exists(addrs_f) else {}
    for name, s in load_all(d).items():
        if '_error' in s or problems(name, s):
            continue
        ip = address_of(s, addrs)
        if not ip:
            continue
        port = s['port']
        scheme = s.get('scheme', 'http')
        base = '%s://%s%s' % (scheme, ip, '' if port == {'http': 80, 'https': 443}.get(scheme) else ':%d' % port)
        for i, x in enumerate(s.get('stats', [])):
            cols = [name, str(i), base + x['path'], x.get('secret') or '-', x.get('auth') or '-']
            if with_label:
                cols.append(' '.join(str(x.get('label') or '-').split()) or '-')
                cols.append(' '.join(str(x.get('unit') or '-').split()) or '-')
            print('\t'.join(cols))
    return 0


def pointer_get(doc, ptr):
    """RFC 6901; raises KeyError when it misses"""
    if ptr == '':
        return doc
    for tok in ptr[1:].split('/'):
        tok = tok.replace('~1', '/').replace('~0', '~')
        if isinstance(doc, dict) and tok in doc:
            doc = doc[tok]
        elif isinstance(doc, list) and tok.isdigit() and int(tok) < len(doc):
            doc = doc[int(tok)]
        else:
            raise KeyError(ptr)
    return doc


def cmd_stat_value(d, args):
    """stat-value SERVICE INDEX: JSON on stdin -> the value, formatted; exit 1 (nothing printed) when it does not fit"""
    import json
    if len(args) != 2 or not args[1].isdigit():
        die('stat-value needs SERVICE INDEX')
    s = load_all(d).get(args[0])
    if not s or '_error' in s or problems(args[0], s):
        return 1
    stats = s.get('stats', [])
    if int(args[1]) >= len(stats):
        return 1
    x = stats[int(args[1])]
    raw = sys.stdin.buffer.read(STAT_MAX_BODY + 1)
    if len(raw) > STAT_MAX_BODY:
        return 1
    try:
        v = pointer_get(json.loads(raw.decode('utf-8')), x.get('pointer', ''))
    except (ValueError, KeyError):
        return 1
    if x.get('reduce') == 'count':
        if not isinstance(v, list):
            return 1
        w = x.get('where')
        if w is not None:
            def has(item):
                try:
                    return pointer_get(item, w) not in (None, False, '')
                except KeyError:
                    return False
            v = [i for i in v if has(i)]
        v = len(v)
    fmt = x.get('format', 'int')
    if fmt == 'text':
        if isinstance(v, (dict, list)) or v is None or isinstance(v, bool):
            return 1
        out = ''.join(' ' if ord(c) < 32 or ord(c) == 127 else c for c in str(v)).strip()[:24]
        if not out:
            return 1
    else:
        if isinstance(v, bool) or not isinstance(v, (int, float)):
            return 1
        out = str(int(v)) if fmt == 'int' else '%.1f' % v
    print(out)
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


def cmd_hostspecs(d, args):
    """the host spec lines of one host (what the provider writes whole); nothing = the host has no route any more"""
    info_f, routes_f, addrs_f, host = opt(args, '--info'), opt(args, '--routes'), opt(args, '--addrs'), opt(args, '--host')
    if not (info_f and routes_f and addrs_f and host):
        die('hostspecs needs --info, --routes, --addrs and --host')
    owned_f, specs_f = opt(args, '--owned'), opt(args, '--specs')
    info, routes, addrs = read_info(info_f), read_routes(routes_f), read_addrs(addrs_f)
    got = {}
    make_plan(d, info, routes, addrs, read_owned(owned_f), 'public', None, read_specs(specs_f), got)
    for line in got.get(host.lower(), []):
        print(line)
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
    if cmd == 'stats-plan':
        return cmd_stats_plan(d, args)
    if cmd == 'stat-value':
        return cmd_stat_value(d, args)
    if cmd == 'list':
        cmd_list(d)
        return 0
    if cmd == 'check':
        return cmd_check(d)
    if cmd == 'add':
        return cmd_add(d, args)
    if cmd == 'edit':
        return cmd_edit(d, args)
    if cmd == 'show':
        return cmd_show(d, args)
    if cmd == 'remove':
        return cmd_remove(d, args)
    if cmd == 'hostspecs':
        return cmd_hostspecs(d, args)
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
        specs_f = opt(args, '--specs')
        slot = opt(args, '--slot', 'public')
        explicit_f = opt(args, '--explicit')
        if slot not in ('public', 'local'):
            die('--slot must be public or local')
        info, routes, addrs = read_info(info_f), read_routes(routes_f, slot == 'local'), read_addrs(addrs_f)
        if cmd == 'plan':
            specs_have = read_specs(specs_f) if specs_f else None
            for row in make_plan(d, info, routes, addrs, read_owned(owned_f), slot, read_explicit(explicit_f), specs_have):
                print('\t'.join(row))
            return 0
        for row in make_import(d, info, routes, addrs, read_specs(specs_f) if specs_f else None):
            *shown, s = row
            print('\t'.join(shown))
            if do_write and row[0] == 'create':
                write(d, s)
        return 0
    die('unknown command %s' % cmd)


if __name__ == '__main__':
    sys.exit(main(sys.argv))
