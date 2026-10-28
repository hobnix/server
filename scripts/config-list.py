#!/usr/bin/env python3
"""scripts/config-list.py FILE: every option of config/schema.toml, one tab separated line each:
section, key, current, default, type, help, settable, store.
Called by config-read.sh (hs sys config list). "current" is the value in machine.toml (store = machine) or in
/var/lib/hs/settings (store = settings; same lookup as scripts/lib/setting.sh). Secrets show only whether they are set."""
import importlib.util
import os
import sys
import tomllib

here = os.path.dirname(os.path.abspath(__file__))


def load_module(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(here, file))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


mt = load_module("machine_toml", "machine-toml.py")
sg = load_module("schema_gen", "schema-gen.py")


def setting_value(key, legacy):
    """what scripts/lib/setting.sh setting_get gives: the settings file, else the /etc/hs file Nix still writes; None when set nowhere"""
    state = os.environ.get('HS_STATE_DIR') or '/var/lib/hs'
    files = {'notifyUrl': 'notify-url', 'heartbeatUrl': 'heartbeat-url'}
    f = os.path.join(state, files[key]) if key in files else os.path.join(os.environ.get('HS_SETTINGS_DIR') or os.path.join(state, 'settings'), key)
    for path, old in ((f, False), (os.path.join(os.environ.get('HS_ETC_DIR') or '/etc/hs', legacy) if legacy else None, True)):
        if path and os.path.isfile(path):
            with open(path, encoding='utf-8') as fh:
                v = fh.readline().rstrip('\n')
            if old and key in ('loginMessage', 'backupNewShares'):
                v = {'on': 'true', 'off': 'false'}.get(v, v)
            return v
    return None


def kind(v):
    if isinstance(v, bool):
        return 'bool'
    if isinstance(v, (int, float)):
        return 'number'
    if isinstance(v, str):
        return 'string'
    if isinstance(v, list):
        return 'list'
    return 'table'


def show(v):
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, str):
        return v
    return mt.inline(v)


def clean(s):
    return ' '.join(str(s).replace('\t', ' ').split())


def help_text(doc):
    """the prose of the paragraph: its comment lines without the indented examples, on one line"""
    out = []
    for line in doc.split('\n'):
        s = line[1:] if line.startswith('#') else line
        if not s.strip() or mt.SECTION in s or s.startswith('  '):
            continue
        out.append(s.strip())
    return clean(' '.join(out))[:400]


def main(argv):
    sys.stdout.reconfigure(newline='\n', encoding='utf-8')
    path = argv[1]
    values = {}
    if os.path.exists(path):
        _, values = mt.load_file(path)
    section = ''
    for it in sg.load():
        if it['kind'] == 'section':
            section = it['title']
            continue
        if it['kind'] != 'option':
            continue
        k = it['key']
        ex = tomllib.loads(it['value'])[k]
        store = it.get('store', 'machine')
        sv = setting_value(k, it.get('legacy', '')) if store == 'settings' else None
        if it['secret']:
            have = (k in values) if store == 'machine' else (sv is not None)
            cur = '(set)' if have else '(not set)'
            dflt = ''
        else:
            cur = show(values[k]) if (store == 'machine' and k in values) else (sv or '')
            dflt = show(ex)
        print('\t'.join([section, k, clean(cur), clean(dflt), kind(ex), help_text(it['doc']),
                         'yes' if it['settable'] else 'no', store]))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
