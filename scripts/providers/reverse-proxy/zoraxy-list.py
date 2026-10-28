#!/usr/bin/env python3
"""Zoraxy's rule files on stdin ("## <path>" line, then the JSON of one rule) -> host<TAB>path<TAB>target<TAB>id, one line per route.
The field names differ between Zoraxy versions, so every name is looked up under its old and its new spelling; a file that does not
parse is skipped (scripts/ports.sh reads the same files the same tolerant way)."""
import json
import sys


def first(d, *names):
    for n in names:
        v = d.get(n)
        if v:
            return v
    return None


def blocks(text):
    cur, name = [], None
    for line in text.split('\n'):
        if line.startswith('## '):
            if name is not None:
                yield name, '\n'.join(cur)
            name, cur = line[3:].strip(), []
        else:
            cur.append(line)
    if name is not None:
        yield name, '\n'.join(cur)


def from_api(text):
    """the JSON array of /api/proxy/list -> the same (path, body) pairs as the rule files, so one parser serves both"""
    try:
        data = json.loads(text)
    except ValueError:
        return
    for d in data if isinstance(data, list) else []:
        if isinstance(d, dict) and d.get('RootOrMatchingDomain'):
            yield 'api/' + str(d['RootOrMatchingDomain']) + '.config', json.dumps(d)


def main():
    sys.stdout.reconfigure(newline='\n', encoding='utf-8')
    text = sys.stdin.read()
    for path, body in (from_api(text) if '--json' in sys.argv[1:] else blocks(text)):
        try:
            d = json.loads(body)
        except ValueError:
            continue
        if not isinstance(d, dict):
            continue
        host = first(d, 'RootOrMatchingDomain')
        if not host:
            continue
        if host == '/':
            host = '*'   # Zoraxy's default site (what answers a name no rule knows): not a host name
        ident = path.rsplit('/', 1)[-1].replace('.config', '')
        hosts = [host] + [a for a in (d.get('MatchingDomainAlias') or []) if isinstance(a, str)]
        root = None
        origins = d.get('ActiveOrigins') or []
        if origins and isinstance(origins[0], dict):
            root = first(origins[0], 'OriginIpOrDomain', 'Domain')
        root = root or (d.get('Domain') if isinstance(d.get('Domain'), str) else None)
        vdirs = []
        for v in d.get('VirtualDirectories') or []:
            if isinstance(v, dict):
                p, t = first(v, 'MatchingPath'), first(v, 'Domain', 'OriginIpOrDomain')
                if p and t:
                    vdirs.append((p, t))
        for h in hosts:
            if root:
                print('\t'.join([h, '/', root, ident]))
            for p, t in vdirs:
                print('\t'.join([h, p, t, ident]))


if __name__ == '__main__':
    main()
