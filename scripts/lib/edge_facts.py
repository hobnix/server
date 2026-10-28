#!/usr/bin/env python3
"""Facts of an edge node (a public VPS, role = "edge"; , capabilities/edge-*/NOTES.md).

  edge_facts.py status      the status document (JSON, schema 1, "kind": "proxyserver"): what the web pages Proxy*.svelte read
                            (docs/PLAN-web-backend.md, "The VPS status document"), the same shape the old proxyserver repo served
  edge_facts.py problems    what is wrong, one "key<TAB>text" line each (scripts/edge-health.sh turns it into push messages)

Read only, no secrets (no addresses of people, no mail subjects; a secret appears as the path of its file). A source that cannot
be read leaves its key null, so a page never shows an old value as a fresh one. Standard library only (no jq on the node needed).

The shape of the node comes from /etc/hs/edge-<part>.json, which the Nix modules of the capabilities write (edge-mail, edge-ports,
edge-watcher, edge-status); a part that is not there is a capability that is off, and its keys are left out.

Test knobs (every external command can be replaced by a script): HS_ETC_DIR, HS_STATE_DIR, HS_PROC, HS_NET_DIR, HS_NOW, HS_HOSTNAME,
HS_EDGE_ROOT (the disk to measure), HS_EDGE_DF_FAKE ("size used"), HS_REPO, HS_OS_RELEASE, HS_EDGE_TCP_FAKE ("host:port=ok|refused|timeout,..."), and
HS_EDGE_<TOOL> for SYSTEMCTL, POSTQUEUE, POSTCONF, TAILSCALE, NFT, OPENSSL, GIT, IP, JOURNALCTL, CURL.
"""
import calendar
import json
import os
import re
import shlex
import shutil
import socket
import subprocess
import sys
import time


def env(key, default=''):
    return os.environ.get(key, default)


ETC = env('HS_ETC_DIR', '/etc/hs')
STATE = env('HS_STATE_DIR', '/var/lib/hs')
PROC = env('HS_PROC', '/proc')
NETDIR = env('HS_NET_DIR', '/sys/class/net')
NOW = int(env('HS_NOW') or time.time())


def part(name):
    """/etc/hs/edge-<name>.json as a dict, or None while that capability is off."""
    try:
        with open(os.path.join(ETC, 'edge-%s.json' % name), encoding='utf-8') as f:
            data = json.load(f)
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


def run(tool, *args, timeout=10):
    """(returncode, stdout) of a tool, (None, '') when it cannot be run. HS_EDGE_<TOOL> replaces the command."""
    exe = shlex.split(env('HS_EDGE_' + tool.upper(), tool))
    try:
        r = subprocess.run(exe + list(args), capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
        return r.returncode, r.stdout
    except (OSError, subprocess.TimeoutExpired):
        return None, ''


def read(path, default=None):
    try:
        with open(path, encoding='utf-8') as f:
            return f.read()
    except OSError:
        return default


def number(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        try:
            return float(value)
        except (TypeError, ValueError):
            return None


# --- network probes

def tcp(host, port, timeout=5):
    """('ok'|'refused'|'timeout'|'error', milliseconds). A refusal means the machine answers; a timeout means it does not."""
    fake = env('HS_EDGE_TCP_FAKE')
    if fake:
        for item in fake.split(','):
            key, _, result = item.partition('=')
            if key == '%s:%s' % (host, port):
                return result, 1
        return 'error', None
    started = time.time()
    try:
        with socket.create_connection((host, int(port)), timeout=timeout):
            return 'ok', int((time.time() - started) * 1000)
    except ConnectionRefusedError:
        return 'refused', int((time.time() - started) * 1000)
    except socket.timeout:
        return 'timeout', None
    except OSError:
        return 'error', None


def tcp_retry(host, port, tries=3, pause=4):
    """Tried three times so one lost packet is not an alarm (the old health check did the same)."""
    result = ('error', None)
    for i in range(tries):
        result = tcp(host, port)
        if result[0] in ('ok', 'refused'):
            return result
        if i < tries - 1 and not env('HS_EDGE_TCP_FAKE'):
            time.sleep(pause)
    return result


# --- ports

def span(spec):
    """'25565-25579' -> (25565, 25579); '7881' -> (7881, 7881)."""
    lo, _, hi = str(spec).partition('-')
    return int(lo), int(hi or lo)


def count(spec):
    try:
        lo, hi = span(spec)
        return hi - lo + 1
    except ValueError:
        return 0


def first_port(specs):
    for s in specs:
        try:
            return span(s)[0]
        except ValueError:
            continue
    return None


def nft_text():
    rc, out = run('nft', 'list', 'ruleset')
    return out if rc == 0 and out else None


def in_rules(text, proto, spec, needle):
    """Is there a rule line with `needle` (dnat to <ip> / accept), the protocol and the port spec?"""
    if text is None:
        return None
    pat = re.compile(r'(?<![0-9-])%s(?![0-9-])' % re.escape(str(spec)))
    for line in text.splitlines():
        if 'dport' in line and needle in line and re.search(r'\b%s\b' % proto, line) and pat.search(line):
            return True
    return False


def forwarded(text, proto, spec, ip):
    return in_rules(text, proto, spec, 'dnat to %s' % ip)


def opened(text, proto, spec):
    return in_rules(text, proto, spec, 'accept')


def ports_document(mail, ports):
    nft = nft_text()
    groups = []
    if ports:
        wings = ports.get('wingsIp') or ''
        rows = []
        for spec in ports.get('gamePorts', []):
            rows.append({'name': 'Games %s' % spec, 'proto': 'tcp+udp', 'ports': str(spec), 'count': count(spec),
                         'forwarded': (forwarded(nft, 'tcp', spec, wings) and forwarded(nft, 'udp', spec, wings)) if wings and nft else None})
        for proto, key in (('tcp', 'gameTcp'), ('udp', 'gameUdp')):
            for spec in ports.get(key, []):
                rows.append({'name': 'Games %s %s' % (proto, spec), 'proto': proto, 'ports': str(spec), 'count': count(spec),
                             'forwarded': forwarded(nft, proto, spec, wings) if wings and nft else None})
        probe = None
        port = first_port(ports.get('gamePorts', []) + ports.get('gameTcp', []))
        if wings and port:
            state, ms = tcp(wings, port)
            probe = {'ok': state in ('ok', 'refused'), 'ms': ms}   # a refusal is fine: nothing listens while no server runs
        groups.append({'id': 'games', 'name': 'Games', 'target': 'pelican-wings' if wings else None, 'probe': probe, 'rows': rows})
        rtc = ports.get('rtcIp') or ''
        if rtc:
            rows = []
            for proto, key in (('tcp', 'rtcTcp'), ('udp', 'rtcUdp')):
                for spec in ports.get(key, []):
                    rows.append({'name': 'Calls %s %s' % (proto, spec), 'proto': proto, 'ports': str(spec), 'count': count(spec),
                                 'forwarded': forwarded(nft, proto, spec, rtc) if nft else None})
            probe = None
            port = first_port(ports.get('rtcTcp', []))
            if port:
                state, ms = tcp(rtc, port)
                probe = {'ok': state in ('ok', 'refused'), 'ms': ms}
            groups.append({'id': 'rtc', 'name': 'Matrix calls (LiveKit)', 'target': 'livekit', 'probe': probe, 'rows': rows})
    if mail:
        groups.append({'id': 'mail', 'name': 'Mail', 'target': 'stalwart', 'probe': None, 'rows': [
            {'name': 'SMTP', 'proto': 'tcp', 'ports': '25', 'count': 1, 'forwarded': opened(nft, 'tcp', 25)}]})
    own = [{'name': 'Certificate check', 'proto': 'tcp', 'ports': '80', 'count': 1, 'forwarded': opened(nft, 'tcp', 80)}] if mail else []
    own.append({'name': 'Tailscale', 'proto': 'udp', 'ports': '41641', 'count': 1, 'forwarded': opened(nft, 'udp', 41641)})
    groups.append({'id': 'own', 'name': "This server's own ports", 'target': None, 'probe': None, 'rows': own})
    return {'groups': groups}


def game_ports_legacy(ports_doc):
    """The old `game_ports` key (blocks + wings probe); kept while the proxyserver pages may still ask for it."""
    games = next((g for g in ports_doc['groups'] if g['id'] == 'games'), None)
    if not games:
        return None
    blocks = [{'name': r['name'], 'proto': r['proto'], 'ports': r['ports'], 'count': r['count'], 'forwarded': bool(r['forwarded'])} for r in games['rows']]
    probe = games['probe'] or {}
    return {'blocks': blocks, 'wings': {'ok': probe.get('ok'), 'ms': probe.get('ms')}}


# --- mail

def queue():
    """(messages, age in seconds of the oldest one or None); (None, None) when postfix cannot be asked."""
    rc, out = run('postqueue', '-j')
    if rc is None:
        return None, None
    arrivals = []
    for line in out.splitlines():
        try:
            arrivals.append(int(json.loads(line).get('arrival_time')))
        except (ValueError, TypeError, AttributeError):
            continue
    return len(arrivals), (NOW - min(arrivals) if arrivals else None)


def spf_state():
    rc, out = run('postconf', '-h', 'smtpd_recipient_restrictions')
    if rc is None:
        return None
    return 'pass' if 'policyd-spf' in out else 'off'


def last_delivery():
    rc, out = run('journalctl', '-u', 'postfix', '-g', 'status=sent', '-n', '1', '-o', 'short-unix', '--no-pager')
    m = re.match(r'(\d{9,})', out.strip()) if rc == 0 else None
    return int(m.group(1)) if m else None


def mail_document(mail):
    count_, oldest = queue()
    state, _ = tcp(mail['stalwartIp'], 25, timeout=3) if mail.get('stalwartIp') else (None, None)
    return {'queue': count_, 'oldest_s': oldest, 'stalwart': (state in ('ok', 'refused')) if state else None,
            'spf': spf_state(), 'last_delivery': last_delivery()}


def certificate(mail):
    cert = mail.get('certFile')
    if not cert:
        return None
    rc, out = run('openssl', 'x509', '-enddate', '-noout', '-in', cert)
    m = re.search(r'notAfter=(.+)', out) if rc == 0 else None
    if not m:
        return {'days_left': None, 'domain': mail.get('mxHost')}
    try:
        end = calendar.timegm(time.strptime(re.sub(r'\s+', ' ', m.group(1).strip()).replace(' GMT', ''), '%b %d %H:%M:%S %Y'))
    except ValueError:
        return {'days_left': None, 'domain': mail.get('mxHost')}
    return {'days_left': int((end - NOW) // 86400), 'domain': mail.get('mxHost')}


# --- watcher

def watcher_document(watch):
    state_file = watch.get('stateFile') or '/var/lib/hs-watch/state'
    text = read(state_file)
    problems = [l for l in (text or '').splitlines()[1:] if l.strip()]
    ran = number((read(state_file + '.run') or '').strip())
    beat = number((read(state_file + '.beat') or '').strip())
    sites = []
    for line in (read(state_file + '.sites') or '').splitlines():
        f = line.split('\t')
        if len(f) >= 4:
            sites.append({'name': f[0], 'url': f[1], 'code': number(f[2]) if f[2] not in ('', '-', '000') else None, 'since': number(f[3])})
    if ran is None and text is None:
        state = 'stale'
    elif ran is not None and NOW - ran > 900:
        state = 'stale'
    else:
        state = 'alert' if problems else 'ok'
    return {'state': state, 'heartbeat_age_s': (NOW - beat) if beat else None, 'sites': sites}


# --- tailscale, revision, system

def tailscale_status():
    rc, out = run('tailscale', 'status', '--json')
    if rc != 0:
        return None
    try:
        return json.loads(out)
    except ValueError:
        return None


def tailscale_info(ts, mail, ports):
    if not ts:
        return None
    me = ts.get('Self') or {}
    ips = me.get('TailscaleIPs') or []
    tags = me.get('Tags') or []
    latency = None
    peer = (mail or {}).get('stalwartIp') or (ports or {}).get('wingsIp')
    if peer:
        rc, out = run('tailscale', 'ping', '--c', '1', '--timeout', '3s', peer, timeout=8)
        m = re.search(r'in (\d+(?:\.\d+)?)ms', out or '')
        latency = float(m.group(1)) if m else None
    may = []
    if mail and mail.get('stalwartIp'):
        may.append({'target': 'stalwart', 'ports': '25'})
    if ports and ports.get('wingsIp') and (ports.get('gamePorts') or ports.get('gameTcp') or ports.get('gameUdp')):
        may.append({'target': 'pelican-wings', 'ports': ', '.join(str(p) for p in ports.get('gamePorts', []) + ports.get('gameTcp', []) + ports.get('gameUdp', []))})
    if ports and ports.get('rtcIp'):
        may.append({'target': 'livekit', 'ports': ', '.join(str(p) for p in ports.get('rtcTcp', []) + ports.get('rtcUdp', []))})
    never = [{'target': 'stalwart admin page (8080)', 'why': 'an admin page is never reached from the public side'},
             {'target': 'pelican-wings 8080 / 2022', 'why': 'the node API and SFTP of Wings stay inside the tailnet'}]
    return {'address': ips[0] if ips else None, 'tag': tags[0] if tags else None, 'latency_ms': latency, 'may_reach': may, 'never_reach': never}


def revision():
    repo = env('HS_REPO', '/etc/nixos')
    rc, out = run('git', '-C', repo, 'log', '-1', '--format=%h%n%s')
    lines = out.splitlines()
    if rc != 0 or not lines:
        return None
    return {'hash': lines[0], 'subject': lines[1] if len(lines) > 1 else ''}


def os_name():
    text = read(env('HS_OS_RELEASE', '/etc/os-release'), '')
    m = re.search(r'^PRETTY_NAME="?([^"\n]+)"?', text, re.M)
    return m.group(1) if m else None


def region():
    saved = (read(os.path.join(STATE, 'region')) or '').strip()
    if saved:
        return saved
    rc, out = run('curl', '-fsS', '-m', '2', 'http://169.254.169.254/hetzner/v1/metadata/availability-zone', timeout=4)
    return out.strip() or None if rc == 0 else None


def default_iface():
    rc, out = run('ip', 'route', 'show', 'default')
    m = re.search(r'\bdev (\S+)', out) if rc == 0 else None
    return m.group(1) if m else None


def counters(iface):
    if not iface:
        return None
    rx = read(os.path.join(NETDIR, iface, 'statistics', 'rx_bytes'))
    tx = read(os.path.join(NETDIR, iface, 'statistics', 'tx_bytes'))
    if rx is None or tx is None:
        return None
    return {'iface': iface, 'rx_bytes': int(rx), 'tx_bytes': int(tx)}


def machine_facts():
    cpu = mem = load = up = None
    for line in (read(os.path.join(PROC, 'stat')) or '').splitlines():
        f = line.split()
        if f and f[0] == 'cpu':
            vals = [int(x) for x in f[1:]]
            cpu = {'total': sum(vals), 'idle': vals[3] + (vals[4] if len(vals) > 4 else 0)}
            break
    info = {}
    for line in (read(os.path.join(PROC, 'meminfo')) or '').splitlines():
        k, _, v = line.partition(':')
        info[k] = v.split()[0] if v.split() else None
    if info.get('MemTotal') and info.get('MemAvailable'):
        mem = {'total': int(info['MemTotal']) * 1024, 'available': int(info['MemAvailable']) * 1024}
    f = (read(os.path.join(PROC, 'loadavg')) or '').split()
    if len(f) >= 3:
        load = [float(x) for x in f[:3]]
    f = (read(os.path.join(PROC, 'uptime')) or '').split()
    if f:
        up = int(float(f[0]))
    return cpu, mem, load, up


def failed_units():
    rc, out = run('systemctl', '--failed', '--no-legend', '--plain')
    if rc is None:
        return None
    return [l.split()[0] for l in out.splitlines() if l.strip()]


def health_problems_count():
    text = read(os.path.join(STATE, 'health.state'))
    if text is None:
        return None
    return len([l for l in text.splitlines()[1:] if l.strip()])


def settings_document():
    """The non-secret settings of the node, from the parts the capabilities wrote; a secret is the path of its file."""
    merged = {}
    for name in ('mail', 'ports', 'watcher', 'status'):
        data = part(name)
        if data:
            merged.update({k: v for k, v in data.items() if not k.startswith('_')})
    return merged


def system_disk():
    """(size, used) of the root disk; HS_EDGE_DF_FAKE="size used" for the tests."""
    fake = env('HS_EDGE_DF_FAKE').split()
    if len(fake) == 2:
        return int(fake[0]), int(fake[1])
    du = shutil.disk_usage(env('HS_EDGE_ROOT', '/'))
    return du.total, du.used


def status():
    mail, ports, watch, node = part('mail'), part('ports'), part('watcher'), part('status')
    cpu, mem, load, up = machine_facts()
    ts = tailscale_status()
    try:
        total, used = system_disk()
        system = {'size': total, 'used': used}
    except OSError:
        system = None
    failed = failed_units()
    mail_doc = mail_document(mail) if mail else None
    ports_doc = ports_document(mail, ports) if (mail or ports) else None
    doc = {
        'schema': 1, 'kind': 'proxyserver', 'host': env('HS_HOSTNAME') or socket.gethostname(), 'time': NOW,
        'uptime_s': up, 'load': load, 'cpu': cpu, 'mem': mem,
        'net': counters(default_iface()), 'net_tailscale': counters('tailscale0'),
        'pools': {'system': system},
        'problems': health_problems_count(),
        'tailscale': (ts or {}).get('BackendState'),
        'failed_units': len(failed) if failed is not None else None,
        'revision': revision(), 'os': os_name(), 'region': region(),
        'tailscale_info': tailscale_info(ts, mail, ports),
        'settings': settings_document(),
        # the parts that are on, as the capability names (the web interface builds the node's pages from them); a part is on while its file exists
        'capabilities': sorted('edge-%s' % n for n, d in (('mail', mail), ('ports', ports), ('watcher', watch), ('status', node)) if d is not None),
    }
    if mail_doc is not None:
        doc['mail'] = mail_doc
        doc['mail_queue'] = mail_doc['queue']
        doc['certificate'] = certificate(mail)
    if ports_doc is not None:
        doc['ports'] = ports_doc
        legacy = game_ports_legacy(ports_doc)
        if legacy:
            doc['game_ports'] = legacy
    if watch:
        doc['watcher'] = watcher_document(watch)
    if node is None and not (mail or ports or watch):
        doc['settings'] = {}
    return doc


# --- problems

def problems():
    out = []
    queue_max_age = int(env('HS_EDGE_QUEUE_MAX_AGE', '1800'))
    queue_max_count = int(env('HS_EDGE_QUEUE_MAX_COUNT', '20'))
    cert_days = int(env('HS_EDGE_CERT_DAYS', '14'))
    disk_max = int(env('HS_EDGE_DISK_MAX', '85'))
    mail, ports, watch = part('mail'), part('ports'), part('watcher')

    for unit in failed_units() or []:
        out.append(('unit:%s' % unit, 'systemd unit %s failed (journalctl -u %s)' % (unit, unit)))

    ts = tailscale_status()
    state = (ts or {}).get('BackendState') or 'unknown'
    if state != 'Running':
        out.append(('tailscale', 'Tailscale is %s: SSH, the mail relay and the game forward all go through it' % state))

    if mail and mail.get('stalwartIp'):
        result, _ = tcp_retry(mail['stalwartIp'], 25)
        if result not in ('ok', 'refused'):
            out.append(('stalwart', 'the mail server (%s:25) does not answer: incoming mail waits in the queue' % mail['stalwartIp']))
    if ports and ports.get('wingsIp'):
        port = first_port(ports.get('gamePorts', []) + ports.get('gameTcp', []))
        if port:
            result, _ = tcp_retry(ports['wingsIp'], port)
            if result == 'timeout':   # a refusal is fine: nothing listens while no game server runs
                out.append(('wings', 'the game host (%s) does not answer: offline, or the Tailscale ACL changed' % ports['wingsIp']))

    if mail:
        n, oldest = queue()
        if n:
            if oldest is not None and oldest > queue_max_age:
                out.append(('queue-old', 'mail has been waiting %d minutes in the queue (%d messages): postqueue -p' % (oldest // 60, n)))
            if n > queue_max_count:
                out.append(('queue-big', '%d messages in the mail queue: postqueue -p' % n))
        cert = mail.get('certFile')
        if cert:
            doc = certificate(mail)
            if doc is None or doc['days_left'] is None:
                out.append(('cert', 'no usable certificate file %s' % cert))
            elif doc['days_left'] < cert_days:
                out.append(('cert', 'the certificate for %s expires in under %d days: journalctl -u acme-%s' % (mail.get('mxHost'), cert_days, mail.get('mxHost'))))

    if watch:
        ran = number((read((watch.get('stateFile') or '/var/lib/hs-watch/state') + '.run') or '').strip())
        if ran is not None and NOW - ran > 1200:
            out.append(('watcher', 'the outside watcher has not run for %d minutes: systemctl status hs-edge-watch.timer' % ((NOW - ran) // 60)))

    try:
        total, used_bytes = system_disk()
        used = used_bytes * 100 // total if total else 0
        if used >= disk_max:
            out.append(('disk', 'the system disk is %d %% full' % used))
    except OSError:
        pass
    return out


def main(argv):
    sys.stdout.reconfigure(newline='\n')   # no CRLF into shell scripts on Windows
    if len(argv) != 2 or argv[1] not in ('status', 'problems'):
        print('usage: edge_facts.py status|problems', file=sys.stderr)
        return 2
    if argv[1] == 'status':
        print(json.dumps(status(), separators=(',', ':')))
    else:
        for key, text in problems():
            print('%s\t%s' % (key, text))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
