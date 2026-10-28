#!/usr/bin/env python3
"""Reads, edits and syncs machine.toml (stdlib only).

  machine-toml.py sync EXAMPLE FILE [--check] [--backup PATH] [--from-json JSON|-]
      Rebuild FILE in the layout of EXAMPLE (same sections, order and comments) with the values
      of FILE (or of the JSON object, for the migration from machine.nix). Prints
        new<TAB>key<TAB>description     options that are in the example but not in FILE yet
        unknown<TAB>key                 keys of FILE the example does not know (kept, at the end)
        result<TAB>created|changed|same
      --check changes nothing. The new file must parse and carry the same values, else exit 2
      and the old file stays.
  machine-toml.py get FILE KEY [--json]  value of KEY (a.b = inside a table); exit 1 when not set
  machine-toml.py set FILE KEY TOMLVALUE [--backup PATH]   change one line, comments stay
  machine-toml.py unset FILE KEY [--backup PATH]           comment the line out
  machine-toml.py check EXAMPLE FILE     error/warn<TAB>key<TAB>text lines; exit 1 on an error

The layout rule: the file is paragraphs separated by blank lines; a paragraph's option is its LAST
line that reads "name = ..." or "# name = ..." (exactly one space after the #) and runs to the end
of the paragraph. A commented option is off. Prose lines must not look like that.
"""
import difflib
import json
import os
import re
import shutil
import sys
import tomllib

ASSIGN = re.compile(r'^(# )?([A-Za-z][A-Za-z0-9]*) = ')
BARE = re.compile(r'^[A-Za-z0-9_-]+$')
SECTION = '═══'   # the box-drawing double line of the section headers
TAIL_TITLE = ('# ' + SECTION + ' Not in the example ').ljust(79, '═')


def die(msg, code=1):
    print(msg, file=sys.stderr)
    sys.exit(code)


# ── writing values ──────────────────────────────────────────────────────────

def inline(v):
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return json.dumps(v, ensure_ascii=False)
    if isinstance(v, list):
        return '[' + ', '.join(inline(x) for x in v) + ']'
    if isinstance(v, dict):
        if not v:
            return '{}'
        return '{ ' + ', '.join('%s = %s' % (k if BARE.match(k) else json.dumps(k), inline(x))
                                for k, x in v.items()) + ' }'
    die('machine-toml: cannot write a value of type %s' % type(v).__name__, 2)


def emit(key, v, off=False):
    line = '%s = %s' % (key, inline(v))
    if isinstance(v, list) and v and (len(line) > 88 or any(isinstance(x, str) and len(x) > 40 for x in v)):
        body = ''.join('  %s,\n' % inline(x) for x in v)
        line = '%s = [\n%s]' % (key, body)
    return ('# ' + line) if off else line


# ── reading the layout ──────────────────────────────────────────────────────

def split_blocks(text):
    text = text.strip('\n')
    return re.split(r'\n[ \t]*\n', text) if text else []


def parse_block(block):
    lines = block.split('\n')
    hit = None
    for i, line in enumerate(lines):
        m = ASSIGN.match(line)
        if m:
            hit = (i, m)
    if hit is None:
        return {'lines': lines, 'key': None}
    i, m = hit
    return {'lines': lines, 'key': m.group(2), 'active': m.group(1) is None, 'at': i}


def parse_layout(text):
    return [parse_block(b) for b in split_blocks(text)]


def describe(block):
    for line in block['lines'][:block['at']]:
        s = line.lstrip('#').strip()
        if s and SECTION not in s:
            return s[:110]
    return ''


def example_values(blocks):
    """key -> (value, required): the schema is the example itself."""
    out = {}
    for b in blocks:
        if b['key'] is None:
            continue
        stmt = '\n'.join(b['lines'][b['at']:])
        if not b['active']:
            stmt = stmt[2:]
        try:
            out[b['key']] = (tomllib.loads(stmt)[b['key']], b['active'])
        except (tomllib.TOMLDecodeError, KeyError) as e:
            die('machine-toml: the example is broken at %s: %s' % (b['key'], e), 2)
    return out


def load_file(path):
    with open(path, 'rb') as f:
        raw = f.read().decode('utf-8').replace('\r\n', '\n')   # a file saved on Windows
    try:
        return raw, tomllib.loads(raw)
    except tomllib.TOMLDecodeError as e:
        die('%s: %s' % (path, e), 2)


def write_atomic(path, text, backup=None):
    mode = owner = None
    if os.path.exists(path):
        st = os.stat(path)
        mode, owner = st.st_mode & 0o777, (st.st_uid, st.st_gid)
        if backup:
            shutil.copy2(path, backup)
    tmp = path + '.tmp-%d' % os.getpid()
    with open(tmp, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)
    if mode is not None:
        os.chmod(tmp, mode)
        try:
            os.chown(tmp, *owner)   # a root run keeps the owner of the file
        except (AttributeError, OSError):
            pass
    os.replace(tmp, path)


# ── sync ────────────────────────────────────────────────────────────────────

def build(example_blocks, values):
    out, seen = [], set()
    for b in example_blocks:
        if b['key'] is not None and b['key'] in values:
            seen.add(b['key'])
            head = b['lines'][:b['at']]
            out.append('\n'.join(head + [emit(b['key'], values[b['key']])]))
        else:
            out.append('\n'.join(b['lines']))
    unknown = [k for k in values if k not in seen and k not in {b['key'] for b in example_blocks}]
    if unknown:
        out.append(TAIL_TITLE)
        out.append('# These keys are not in machine.toml.example (a typo, or an option that was removed).\n'
                   '# They are kept here and do nothing unless configuration.nix still reads them.')
        for k in unknown:
            out.append(emit(k, values[k]))
    return '\n\n'.join(out) + '\n', unknown


def cmd_sync(args):
    check = '--check' in args
    backup = opt(args, '--backup')
    from_json = opt(args, '--from-json')
    pos = [a for a in args if not a.startswith('--') and a not in (backup, from_json)]
    if len(pos) != 2:
        die('usage: machine-toml.py sync EXAMPLE FILE [--check] [--backup PATH] [--from-json JSON|-]')
    example, path = pos
    with open(example, encoding='utf-8') as f:
        ex_text = f.read().replace('\r\n', '\n')
    ex_blocks = parse_layout(ex_text)
    example_values(ex_blocks)   # the example itself must parse

    old_text, known = None, set()
    if from_json is not None:
        raw = sys.stdin.read() if from_json == '-' else open(from_json, encoding='utf-8').read()
        values = {k: v for k, v in json.loads(raw).items() if v is not None}   # TOML has no null: off
    elif os.path.exists(path):
        old_text, values = load_file(path)
        known = {b['key'] for b in parse_layout(old_text) if b['key']}
    else:
        values = {}

    text, unknown = build(ex_blocks, values)
    try:
        back = tomllib.loads(text)
    except tomllib.TOMLDecodeError as e:
        die('machine-toml: the new file would not parse (%s); nothing written' % e, 2)
    if any(back.get(k) != v for k, v in values.items()):
        die('machine-toml: the new file would carry other values; nothing written', 2)

    for b in ex_blocks:
        if b['key'] and b['key'] not in known and old_text is not None:
            print('new\t%s\t%s' % (b['key'], describe(b)))
    for k in unknown:
        print('unknown\t%s' % k)

    existed = os.path.exists(path)
    if old_text is not None and old_text == text:
        print('result\tsame')
        return 0
    if not check:
        write_atomic(path, text, backup if existed else None)
    print('result\t%s' % ('changed' if existed else 'created'))
    return 0


# ── get / set / unset ───────────────────────────────────────────────────────

def opt(args, name):
    """--name VALUE; removes nothing, returns the value or None."""
    if name in args:
        i = args.index(name)
        if i + 1 < len(args):
            return args[i + 1]
        die('%s needs a value' % name)
    return None


def cmd_get(args):
    as_json = '--json' in args
    pos = [a for a in args if a != '--json']
    if len(pos) != 2:
        die('usage: machine-toml.py get FILE KEY [--json]')
    _, values = load_file(pos[0])
    v = values
    for part in pos[1].split('.'):
        if not isinstance(v, dict) or part not in v:
            return 1
        v = v[part]
    if as_json or isinstance(v, dict):
        print(json.dumps(v))
    elif isinstance(v, bool):
        print('true' if v else 'false')
    elif isinstance(v, list):
        for x in v:
            print(x if isinstance(x, str) else json.dumps(x))
    else:
        print(v)
    return 0


def stmt_end(lines, i):
    """Last line of the statement that starts at line i (arrays and tables can span lines)."""
    depth = 0
    for j in range(i, len(lines)):
        quote, k, s = None, 0, lines[j]
        while k < len(s):
            c = s[k]
            if quote:
                if c == '\\' and quote == '"':
                    k += 1
                elif c == quote:
                    quote = None
            elif c in '"\'':
                quote = c
            elif c == '#':
                break
            elif c in '[{':
                depth += 1
            elif c in ']}':
                depth -= 1
            k += 1
        if depth <= 0:
            return j
    return len(lines) - 1


def edit(path, key, new_lines, backup):
    text, _ = load_file(path)
    lines = text.split('\n')
    if lines and lines[-1] == '':
        lines.pop()
    on = re.compile(r'^%s = ' % re.escape(key))
    off = re.compile(r'^# %s = ' % re.escape(key))
    at = next((i for i, l in enumerate(lines) if on.match(l)), None)
    if at is not None:
        lines[at:stmt_end(lines, at) + 1] = new_lines
    else:
        at = next((i for i, l in enumerate(lines) if off.match(l)), None)
        if at is not None:
            lines[at:stmt_end(lines, at) + 1] = new_lines
        else:
            lines += [''] + new_lines
    out = '\n'.join(lines) + '\n'
    try:
        tomllib.loads(out)
    except tomllib.TOMLDecodeError as e:
        die('machine-toml: the result would not parse (%s); nothing written' % e, 2)
    write_atomic(path, out, backup)


def cmd_set(args):
    backup = opt(args, '--backup')
    pos = [a for a in args if a != '--backup' and a != backup]
    if len(pos) != 3:
        die('usage: machine-toml.py set FILE KEY TOMLVALUE [--backup PATH]')
    path, key, raw = pos
    if not ASSIGN.match(key + ' = '):
        die('machine-toml: %s is not a key' % key)
    try:
        value = tomllib.loads('v = ' + raw)['v']
    except tomllib.TOMLDecodeError as e:
        die('machine-toml: %r is not a TOML value (%s); strings need quotes' % (raw, e), 2)
    edit(path, key, emit(key, value).split('\n'), backup)
    return 0


def cmd_unset(args):
    backup = opt(args, '--backup')
    pos = [a for a in args if a != '--backup' and a != backup]
    if len(pos) != 2:
        die('usage: machine-toml.py unset FILE KEY [--backup PATH]')
    path, key = pos
    _, values = load_file(path)
    if key in values:
        edit(path, key, [emit(key, values[key], off=True)], backup)
    return 0


# ── check ───────────────────────────────────────────────────────────────────

# options only a home server needs: ZFS host id, network card, Samba networks, VLANs
HOME_ONLY = ('hostId', 'nic', 'smbAllow', 'vlans')

# options whose value may have more than one type
EITHER = {'gpu': (str, list)}


def cmd_check(args):
    if len(args) != 2:
        die('usage: machine-toml.py check EXAMPLE FILE')
    with open(args[0], encoding='utf-8') as f:
        schema = example_values(parse_layout(f.read()))
    _, values = load_file(args[1])
    bad = 0
    for k, v in values.items():
        if k not in schema:
            near = difflib.get_close_matches(k, schema, n=1)
            print('warn\t%s\tunknown option%s' % (k, ' (did you mean %s?)' % near[0] if near else ''))
            continue
        want = EITHER.get(k, (type(schema[k][0]),))
        if type(v) not in want:
            print('error\t%s\tmust be %s, not %s' % (k, ' or '.join(t.__name__ for t in want), type(v).__name__))
            bad = 1
    # a node that is not a home server (role = "edge" or "minimal") has no pools, bridges or Samba: those options are not required there
    home = values.get('role', 'homeserver') == 'homeserver'
    for k, (_, required) in schema.items():
        if required and k not in values and (home or k not in HOME_ONLY):
            print('error\t%s\tmissing' % k)
            bad = 1
    if home and values.get('hostId') == 'CHANGEME':
        print('error\thostId\tstill CHANGEME')
        bad = 1
    return bad


def main(argv):
    sys.stdout.reconfigure(newline='\n')   # no CRLF into shell scripts on Windows
    cmds = {'sync': cmd_sync, 'get': cmd_get, 'set': cmd_set, 'unset': cmd_unset, 'check': cmd_check}
    if len(argv) < 2 or argv[1] not in cmds:
        die(__doc__.split('\n\n')[0] + '\n(see the top of this file)')
    return cmds[argv[1]](argv[2:])


if __name__ == '__main__':
    sys.exit(main(sys.argv))
