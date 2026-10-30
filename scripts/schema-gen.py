#!/usr/bin/env python3
"""The option schema of machine.toml (config/schema.toml; docs/PLAN-modular-core.md, step 1).

  schema-gen.py write      regenerate everything derived from the schema
  schema-gen.py check      same, but change nothing: exit 1 and list what is stale (tests/schema.sh)
  schema-gen.py list       key<TAB>type<TAB>settable<TAB>secret<TAB>section<TAB>store, in file order
  schema-gen.py capabilities   key<TAB>capability, for every option that belongs to a capability (capabilities/<name>/)
  schema-gen.py settings   key<TAB>legacy file in /etc/hs (or empty), for every option with store = "settings"
  schema-gen.py defaults   key<TAB>nix expression, for every option that has a default
  schema-gen.py pages      key<TAB>page, in file order (the settings page each option is shown on, besides Advanced)
  schema-gen.py rule KEY   type<TAB>choices<TAB>min<TAB>pattern<TAB>hint of one option (what hs sys config set checks); exit 1 if unknown

Derived files (never edit them by hand):
  machine.toml.example     the layout `hs config sync|check|list` work from
  scripts/lib/config-keys.sh   CONFIG_SETTABLE / CONFIG_SECRET
  config/defaults.nix          the plain-value defaults, read by the Nix files as `machine = defaults // <machine.toml>`
  scripts/lib/capabilities.tsv the capabilities and the settings that imply them (from capabilities/*/capability.toml)
  web/src/settings/layout.gen.json  which Settings subpage shows which key, and the capability pages (from `page` and [settings])
  scripts/web-serve.py     the CONFIG_KEYS allowlist (between the two "schema:" marker comments)

The schema is a TOML file with an ordered array of [[item]] tables:
  kind = "header"   text = the opening comment of the example
  kind = "section"  title = name of a section header line
  kind = "option"   key, type (bool|string|int|float|list|table), required (on in the example),
                    settable (the web interface may change it), secret (value never shown),
                    doc (the comment lines above the option), value (the option line(s), without a leading "# "),
                    default (optional: the Nix expression after `or` in configuration.nix, e.g. '"en"', 'false', 'null',
                    '[ 100 199 ]'; no default = required, or read some other way). tests/schema.sh keeps both in step.
                    capability: the folder in capabilities/ the option belongs to (its manifest capability.toml);
                    store: "machine" (default; machine.toml, Nix reads it, a change needs `hs rebuild`) or "settings"
                    (a file in /var/lib/hs/settings/, scripts read it at run time, no rebuild; scripts/lib/setting.sh);
                    legacy: the /etc/hs/<name> file Nix still writes from machine.toml for it, read as a fallback.
                    Rules for a value (checked by config-change.sh, usable by forms): choices (list), min (number),
                    pattern (regex a string must match) with hint (what to say: "a colour such as #9184d9").
                    page: the Settings subpage that shows the option (also on a section: the default of its options). One of
                    general network storage backups access updates capabilities advanced, or cap:<name> (a capabilities/ folder).
                    Order: option page, else cap:<capability> if it has `capability`, else the section page. Every option is also
                    listed on Advanced; `advanced` alone is only allowed for an option that is not settable.
A capability manifest may carry a table [settings]: icon (a Phosphor name, default puzzle-piece) and entry (true|false: a page in the
tree even without options). Nothing else is supported yet.
`required` false means the example shows the option commented out, i.e. it is off and has a default.
"""
import json
import os
import re
import sys
import tomllib

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))


def find_schema():
    """HS_SCHEMA, else config/schema.toml next to scripts/, else the one in the checkout beside machine.toml (the scripts
    run from a copy in /nix/store that has no config/ folder, like machine.toml.example)."""
    here = os.path.join(ROOT, 'config', 'schema.toml')
    machine = os.environ.get('HS_MACHINE_FILE') or '/etc/nixos/machine.toml'
    for c in (os.environ.get('HS_SCHEMA'), here, os.path.join(os.path.dirname(machine), 'config', 'schema.toml')):
        if c and os.path.exists(c):
            return c
    return here


SCHEMA = find_schema()
EXAMPLE = os.path.join(ROOT, 'machine.toml.example')
KEYS_SH = os.path.join(ROOT, 'scripts', 'lib', 'config-keys.sh')
CAPS_TSV = os.path.join(ROOT, 'scripts', 'lib', 'capabilities.tsv')
DEFAULTS_NIX = os.path.join(ROOT, 'config', 'defaults.nix')
# a default that is a plain Nix value (string, number, true/false/null, list of those) can go into config/defaults.nix;
# one that refers to another binding (siteName: hostName) stays an `or` in configuration.nix
LITERAL = re.compile(r'^("[^"\\$]*"|-?[0-9]+|true|false|null|\[[ 0-9a-z"-]*\])$')
WEB = os.path.join(ROOT, 'scripts', 'web-serve.py')
TYPES = ('bool', 'string', 'int', 'float', 'list', 'table')
LAYOUT_JSON = os.path.join(ROOT, 'web', 'src', 'settings', 'layout.gen.json')
PAGES = ('general', 'network', 'storage', 'backups', 'access', 'updates', 'capabilities', 'advanced')
SETTINGS_KEYS = ('icon', 'entry')
SECTION_FILL = 76
WEB_BEGIN = '# schema:begin CONFIG_KEYS (generated by scripts/schema-gen.py; edit config/schema.toml)'
WEB_END = '# schema:end CONFIG_KEYS'


def die(msg):
    print('schema-gen: ' + msg, file=sys.stderr)
    sys.exit(2)


def has_capability(name):
    """capabilities/<name>/ exists. The scripts also run from a copy in /nix/store that has no capabilities/ folder (see find_schema):
    there nothing can be checked, and the checkout has been checked when the schema was generated."""
    cdir = os.path.join(ROOT, 'capabilities')
    return not os.path.isdir(cdir) or os.path.isdir(os.path.join(cdir, name))


def check_page(it, what):
    """`page` of a section or an option: a page id, or cap:<name> where capabilities/<name>/ exists (the settable rule is checked later)"""
    if 'page' not in it:
        return
    pg = it['page']
    if pg in PAGES:
        return
    if isinstance(pg, str) and pg.startswith('cap:') and re.fullmatch(r'[a-z][a-z0-9-]*', pg[4:]) and has_capability(pg[4:]):
        return
    die('%s: page must be one of %s or cap:<name> of a folder in capabilities/ (got %r)' % (what, ' '.join(PAGES), pg))


def load():
    with open(SCHEMA, 'rb') as f:
        data = tomllib.load(f)
    items = data.get('item')
    if not items:
        die('%s has no [[item]]' % SCHEMA)
    seen = set()
    for it in items:
        kind = it.get('kind')
        if kind == 'header' and 'text' in it:
            continue
        if kind == 'section' and 'title' in it:
            check_page(it, it['title'])
            continue
        if kind == 'option':
            key = it.get('key')
            if not key or key in seen:
                die('option key missing or twice: %r' % key)
            seen.add(key)
            if it.get('type') not in TYPES:
                die('%s: type must be one of %s' % (key, '|'.join(TYPES)))
            for f in ('required', 'settable', 'secret'):
                if not isinstance(it.get(f), bool):
                    die('%s: %s must be true or false' % (key, f))
            if not it.get('doc') or not it.get('value'):
                die('%s: doc and value are required' % key)
            if 'default' in it and not (isinstance(it['default'], str) and it['default'].strip()):
                die('%s: default must be a non-empty Nix expression (a string)' % key)
            if 'capability' in it and not (isinstance(it['capability'], str) and re.fullmatch(r'[a-z][a-z0-9-]*', it['capability'])):
                die('%s: capability must be a name like "metrics"' % key)
            check_page(it, key)
            if it.get('store', 'machine') not in ('machine', 'settings'):
                die('%s: store must be machine or settings' % key)
            if 'legacy' in it and it.get('store') != 'settings':
                die('%s: legacy only fits store = "settings"' % key)
            if 'choices' in it and not (isinstance(it['choices'], list) and it['choices']):
                die('%s: choices must be a non-empty list' % key)
            if 'min' in it and it['type'] not in ('int', 'float'):
                die('%s: min only fits a number' % key)
            if 'pattern' in it:
                if it['type'] != 'string' or not it.get('hint'):
                    die('%s: pattern needs type string and a hint' % key)
                try:
                    re.compile(it['pattern'])
                except re.error as e:
                    die('%s: bad pattern: %s' % (key, e))
            if it['settable'] and it['secret']:
                die('%s: a secret option cannot be settable from the web' % key)
            continue
        die('bad item: %r' % (it,))
    return items


def section_line(title):
    return ('# ═══ %s ' % title).ljust(SECTION_FILL, '═')


def render_example(items):
    """Only options with store = "machine" are in the example; a section with none left is dropped too."""
    blocks, section = [], None
    for it in items:
        if it['kind'] == 'header':
            blocks.append(it['text'])
        elif it['kind'] == 'section':
            section = section_line(it['title'])
        elif it.get('store', 'machine') == 'machine':
            if section:
                blocks.append(section)
                section = None
            value = it['value'] if it['required'] else '# ' + it['value']
            blocks.append(it['doc'] + '\n' + value)
    return '\n\n'.join(blocks) + '\n'


def options(items):
    return [it for it in items if it['kind'] == 'option']


def render_keys_sh(items):
    opts = options(items)
    return (
        '# shellcheck shell=bash\n'
        '# GENERATED by scripts/schema-gen.py from config/schema.toml: edit the schema, then run `python3 scripts/schema-gen.py write`.\n'
        '# The options of machine.toml the web interface may change (hs sys config plan|start set), and the ones whose value is\n'
        '# never shown. Read by config-read.sh (settable=yes|no) and config-change.sh; scripts/web-serve.py gets the same names.\n'
        'CONFIG_SETTABLE="%s"\n'
        'CONFIG_SECRET="%s"\n' % (' '.join(o['key'] for o in opts if o['settable']),
                                  ' '.join(o['key'] for o in opts if o['secret'])))


def render_web(text, items):
    keys = [o['key'] for o in options(items) if o['settable']]
    lines, cur = [], ''
    for k in keys:
        piece = ('|' if cur else '') + k
        if len(cur) + len(piece) > 100:
            lines.append(cur + '|')
            cur = k
        else:
            cur += piece
    lines.append(cur)
    body = 'CONFIG_KEYS = (' + '\n               '.join('"%s"' % l for l in lines) + ')\n'
    pat = re.compile(re.escape(WEB_BEGIN) + r'\n.*?' + re.escape(WEB_END), re.S)
    if not pat.search(text):
        die('%s has no schema markers around CONFIG_KEYS' % WEB)
    return pat.sub(lambda m: WEB_BEGIN + '\n' + body + WEB_END, text, count=1)


def manifests():
    """name -> manifest of every capabilities/<name>/capability.toml"""
    out = {}
    cdir = os.path.join(ROOT, 'capabilities')
    if os.path.isdir(cdir):
        for name in sorted(os.listdir(cdir)):
            f = os.path.join(cdir, name, 'capability.toml')
            if os.path.isfile(f):
                with open(f, 'rb') as fh:
                    out[name] = tomllib.load(fh)
    return out


def render_caps_tsv(items):
    """scripts/lib/capabilities.tsv for capability.sh and web-serve.py (the scripts run from a copy that has no capabilities/ folder):
    name <TAB> implied_by (comma separated runtime settings) <TAB> title"""
    rows = ['# GENERATED by scripts/schema-gen.py from capabilities/*/capability.toml: edit the manifest, then run `python3 scripts/schema-gen.py write`.',
            '# name<TAB>implied_by (runtime settings that switch it on, comma separated)<TAB>title']
    for name, m in manifests().items():
        if m.get('name') != name:
            die('capabilities/%s/capability.toml: name must be %s' % (name, name))
        rows.append('\t'.join([name, ','.join(m.get('implied_by', [])), m.get('title', name)]))
    return '\n'.join(rows) + '\n'


def read(path):
    with open(path, 'rb') as f:
        return f.read().decode('utf-8').replace('\r\n', '\n')


def render_defaults_nix(items):
    """config/defaults.nix: the default of every option whose default is a plain value. configuration.nix, install.nix and the
    capability modules read `machine = defaults // <machine.toml>`, so a default is written down once, in the schema."""
    rows = ['# GENERATED by scripts/schema-gen.py from config/schema.toml: edit the schema, then run `python3 scripts/schema-gen.py write`.',
            '# The defaults of the options of machine.toml (the ones that are a plain value). configuration.nix reads',
            '# `machine = defaults // (machine.toml)`. A default that refers to another setting stays an `or` in configuration.nix.',
            '{']
    for it in options(items):
        if 'default' in it and LITERAL.match(it['default']):
            rows.append('  %s = %s;' % (it['key'], it['default']))
    rows.append('}')
    return '\n'.join(rows) + '\n'


def page_rows(items):
    """[(key, page)] in file order: option page > cap:<capability> > section page; an option without any dies"""
    rows, sect = [], None
    for it in items:
        if it['kind'] == 'section':
            sect = it
        elif it['kind'] == 'option':
            pg = it.get('page') or ('cap:' + it['capability'] if 'capability' in it else None) or (sect or {}).get('page')
            if not pg:
                die('%s: no settings page (set `page` on the option or on its section, or give it a `capability`)' % it['key'])
            if pg == 'advanced' and it['settable']:
                die('%s: page advanced is only for options that are not settable' % it['key'])
            if pg.startswith('cap:') and not has_capability(pg[4:]):
                die('%s: page %s names no folder in capabilities/' % (it['key'], pg))
            rows.append((it['key'], pg))
    return rows


def render_settings_layout(items):
    """web/src/settings/layout.gen.json: the page of every key and the capability pages (title, icon, entry) for the Settings tree"""
    keys = dict(page_rows(items))
    with_opts = {pg[4:] for pg in keys.values() if pg.startswith('cap:')}
    caps = {}
    for name, m in manifests().items():
        st = m.get('settings', {})
        if not isinstance(st, dict):
            die('capabilities/%s/capability.toml: [settings] must be a table' % name)
        for k in st:
            if k not in SETTINGS_KEYS:
                die('capabilities/%s/capability.toml: [settings] %s is not supported yet' % (name, k))
        if 'entry' in st and not isinstance(st['entry'], bool):
            die('capabilities/%s/capability.toml: [settings] entry must be true or false' % name)
        if 'icon' in st and not (isinstance(st['icon'], str) and re.fullmatch(r'[a-z][a-z0-9-]*', st['icon'])):
            die('capabilities/%s/capability.toml: [settings] icon must be a Phosphor name' % name)
        caps[name] = {'title': m.get('title', name), 'icon': st.get('icon', 'puzzle-piece'), 'entry': bool(st.get('entry', name in with_opts))}
    doc = {'pages': list(PAGES), 'keys': keys, 'caps': caps}
    return json.dumps(doc, indent=1, ensure_ascii=False) + '\n'


def targets(items):
    return [
        (EXAMPLE, render_example(items)),
        (KEYS_SH, render_keys_sh(items)),
        (CAPS_TSV, render_caps_tsv(items)),
        (LAYOUT_JSON, render_settings_layout(items)),
        (DEFAULTS_NIX, render_defaults_nix(items)),
        (WEB, render_web(read(WEB), items)),
    ]


def main(argv):
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(newline='\n', encoding='utf-8')   # lines for scripts, also on Windows
    cmd = argv[1] if len(argv) > 1 else ''
    items = load()
    if cmd in ('write', 'check'):
        stale = []
        for path, want in targets(items):
            if not os.path.exists(path) or read(path) != want:
                stale.append(os.path.relpath(path, ROOT).replace(os.sep, '/'))
                if cmd == 'write':
                    with open(path, 'w', encoding='utf-8', newline='\n') as f:
                        f.write(want)
        if stale and cmd == 'check':
            print('stale (run: python3 scripts/schema-gen.py write):\n  ' + '\n  '.join(stale))
            return 1
        for s in stale:
            print('wrote ' + s)
        return 0
    if cmd == 'list':
        sect = ''
        for it in items:
            if it['kind'] == 'section':
                sect = it['title']
            elif it['kind'] == 'option':
                print('\t'.join([it['key'], it['type'], 'yes' if it['settable'] else 'no',
                                 'yes' if it['secret'] else 'no', sect, it.get('store', 'machine')]))
        return 0
    if cmd == 'pages':
        for k, pg in page_rows(items):
            print('%s	%s' % (k, pg))
        return 0
    if cmd == 'capabilities':
        for it in options(items):
            if 'capability' in it:
                print('%s	%s' % (it['key'], it['capability']))
        return 0
    if cmd == 'settings':
        for it in options(items):
            if it.get('store') == 'settings':
                print('%s	%s' % (it['key'], it.get('legacy', '')))
        return 0
    if cmd == 'rule':
        for it in options(items):
            if it['key'] == (argv[2] if len(argv) > 2 else ''):
                print('	'.join([it['type'], ' '.join(str(c) for c in it.get('choices', [])), str(it.get('min', '')),
                                 it.get('pattern', ''), it.get('hint', '')]))
                return 0
        return 1
    if cmd == 'defaults':
        for it in options(items):
            if 'default' in it:
                print('%s	%s' % (it['key'], it['default']))
        return 0
    print(__doc__.strip().split('\n\n')[0], file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
