#!/usr/bin/env python3
"""A stand-in for Zoraxy's admin API (tests/services-zoraxy-api.sh); a helper, not a test.

  zoraxy-fake.py RULEDIR PORTFILE [--user admin --password secret]

Speaks the part of the API that hs uses (checked against the Zoraxy sources, v3.3.x): GET /login.html (sets the cookie zoraxy_csrf, the token is in
<meta name="zoraxy.csrf.Token">; every POST must send it back in the header X-CSRF-Token, else 403), POST /api/auth/login (form username, password, rmbme;
answers "OK" (like the real one) and sets a session cookie), then with the cookie POST /api/proxy/list (type=host), /api/proxy/add (type=host, rootname, ep),
/api/proxy/vdir/add (type=host, endpoint, path, domain), /vdir/edit and /vdir/del (type=host, vdir, path = the host), /api/proxy/del (ep),
/api/proxy/upstream/add and /remove (ep, origin). Without the cookie: 401. Every rule is also written as
RULEDIR/<host>.config in the JSON shape of Zoraxy's rule files, so a fake `incus exec` can cat them like the real container's files.
The port it listens on (it picks a free one) is written to PORTFILE."""
import http.server
import json
import os
import secrets
import sys
import urllib.parse

rules = {}
issued = set()   # CSRF tokens handed out
user, password = 'admin', 'secret'
args = sys.argv[1:]
ruledir, portfile = args[0], args[1]
if '--user' in args:
    user = args[args.index('--user') + 1]
if '--password' in args:
    password = args[args.index('--password') + 1]


def save(host):
    path = os.path.join(ruledir, host + '.config')
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(rules[host], f)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, body, status=200, cookie=None):
        data = (body if isinstance(body, str) else json.dumps(body)).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        if cookie:
            self.send_header('Set-Cookie', cookie)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        # like Zoraxy 3.3.x (gorilla/csrf): the login page sets the cookie zoraxy_csrf and carries a token in a meta tag
        if self.path.split('?')[0] != '/login.html':
            return self.reply('404', 404)
        token = secrets.token_hex(16)
        issued.add(token)
        html = '<html><head><meta name="zoraxy.csrf.Token" content="%s"></head><body>login</body></html>' % token
        data = html.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.send_header('Set-Cookie', 'zoraxy_csrf=%s; Path=/; HttpOnly' % secrets.token_hex(8))
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        form = {k: v[0] for k, v in urllib.parse.parse_qs(self.rfile.read(n).decode()).items()}
        # every POST needs the token (header X-CSRF-Token) and the cookie, else 403 as the real one says
        if self.headers.get('X-CSRF-Token') not in issued or 'zoraxy_csrf=' not in (self.headers.get('Cookie') or ''):
            return self.reply('Forbidden - CSRF token not found in request', 403)
        if self.path == '/api/auth/login':
            if form.get('username') == user and form.get('password') == password:
                return self.reply('"OK"', cookie='zoraxy-session=yes; Path=/; HttpOnly')
            return self.reply({'error': 'Invalid username or password.'})
        if 'zoraxy-session=yes' not in (self.headers.get('Cookie') or ''):
            return self.reply('401 - Unauthorized', 401)
        if self.path == '/api/proxy/list':
            if form.get('type') != 'host':
                return self.reply({'error': 'Invalid type given'})
            # the default site ("/") is the "root" rule of Zoraxy: type=host does not list it, its rule file exists all the same
            return self.reply([rules[h] for h in sorted(rules) if h != '/'])
        if self.path == '/api/proxy/add':
            host, ep = form.get('rootname', '').lower(), form.get('ep', '')
            if form.get('type') != 'host' or not host or not ep:
                return self.reply({'error': 'missing field'})
            if host in rules:
                return self.reply({'error': 'Proxy rule with same matching domain already exists'})
            rules[host] = {'RootOrMatchingDomain': host, 'MatchingDomainAlias': [], 'ActiveOrigins': [{'OriginIpOrDomain': ep}],
                           'VirtualDirectories': []}
            save(host)
            return self.reply('"OK"')
        if self.path == '/api/proxy/vdir/add':
            host, path, domain = form.get('endpoint', '').lower(), form.get('path', ''), form.get('domain', '')
            if host not in rules:
                return self.reply({'error': 'Proxy rule not found'})
            if any(v['MatchingPath'] == path for v in rules[host]['VirtualDirectories']):
                return self.reply({'error': 'Virtual directory with same path already exists'})
            rules[host]['VirtualDirectories'].append({'MatchingPath': path, 'Domain': domain})
            save(host)
            return self.reply('"OK"')
        if self.path == '/api/proxy/del':
            host = form.get('ep', '').lower()
            if host not in rules:
                return self.reply({'error': 'Proxy rule not found'})
            del rules[host]
            try:
                os.remove(os.path.join(ruledir, host + '.config'))
            except OSError:
                pass
            return self.reply('"OK"')
        if self.path == '/api/proxy/vdir/edit':
            host, vdir = form.get('path', '').lower(), form.get('vdir', '')
            if host not in rules:
                return self.reply({'error': 'target proxy rule not found'})
            for v in rules[host]['VirtualDirectories']:
                if v['MatchingPath'] == vdir:
                    v['Domain'] = form.get('domain', '')
                    save(host)
                    return self.reply('"OK"')
            return self.reply({'error': 'target virtual directory rule not exists'})
        if self.path == '/api/proxy/vdir/del':
            host, vdir = form.get('path', '').lower(), form.get('vdir', '')
            if host not in rules:
                return self.reply({'error': 'target proxy rule not found'})
            before = len(rules[host]['VirtualDirectories'])
            rules[host]['VirtualDirectories'] = [v for v in rules[host]['VirtualDirectories'] if v['MatchingPath'] != vdir]
            if len(rules[host]['VirtualDirectories']) == before:
                return self.reply({'error': 'virtual directory not found'})
            save(host)
            return self.reply('"OK"')
        if self.path == '/api/proxy/upstream/add':
            host, origin = form.get('ep', '').lower(), form.get('origin', '')
            if host not in rules:
                return self.reply({'error': 'target endpoint not found'})
            if any(o['OriginIpOrDomain'] == origin for o in rules[host]['ActiveOrigins']):
                return self.reply({'error': 'upstream with same origin already exists'})
            rules[host]['ActiveOrigins'].append({'OriginIpOrDomain': origin})
            save(host)
            return self.reply('"OK"')
        if self.path == '/api/proxy/upstream/remove':
            host, origin = form.get('ep', '').lower(), form.get('origin', '')
            if host not in rules:
                return self.reply({'error': 'target endpoint not found'})
            kept = [o for o in rules[host]['ActiveOrigins'] if o['OriginIpOrDomain'] != origin]
            if len(kept) == len(rules[host]['ActiveOrigins']):
                return self.reply({'error': 'target upstream not found'})
            rules[host]['ActiveOrigins'] = kept
            save(host)
            return self.reply('"OK"')
        return self.reply('404', 404)


# rules that are already there: RULEDIR/*.config are loaded
for name in sorted(os.listdir(ruledir)):
    if name.endswith('.config'):
        with open(os.path.join(ruledir, name), encoding='utf-8') as f:
            d = json.load(f)
        rules[d['RootOrMatchingDomain']] = d
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
with open(portfile, 'w') as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
