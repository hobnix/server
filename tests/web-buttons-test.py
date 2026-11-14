#!/usr/bin/env python3
"""No bare `<button class="btn ...">` in the web interface: every such button is web/src/ui/Button.svelte.
Prints one line per offender (file:line) and exits 1 when there is one."""
import pathlib
import re
import sys

SRC = pathlib.Path(__file__).resolve().parent.parent / 'web' / 'src'
# Deliberate exceptions, each with its reason.
ALLOW = (
    'ui/Button.svelte',     # the component itself
    'pages/Files.svelte',   # the file manager keeps its own buttons: its handlers return promises and a Button would turn them busy
    'files/',               # (spinner, ignored clicks); to move it over, give those buttons an explicit busy state first
)


def tag_end(s, i):
    """Index of the '>' that closes the opening tag starting at i (braces and quotes of attribute values are skipped)."""
    depth, quote = 0, None
    for j in range(i, len(s)):
        c = s[j]
        if quote:
            if c == quote:
                quote = None
        elif c in '"\'`' and depth == 0:
            quote = c
        elif c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
        elif c == '>' and depth == 0:
            return j
    return len(s)


bad = []
for p in sorted(SRC.rglob('*.svelte')):
    rel = p.relative_to(SRC).as_posix()
    if any(rel == a or (a.endswith('/') and rel.startswith(a)) for a in ALLOW):
        continue
    s = p.read_text()
    for m in re.finditer(r'<button\b', s):
        line_start = s.rfind('\n', 0, m.start()) + 1
        if s[line_start:m.start()].lstrip().startswith('//'):    # a usage example in a comment
            continue
        tag = s[m.start():tag_end(s, m.start())]
        if re.search(r'class\s*=\s*(?:"[^"]*|\{[^}]*)(?<![\w-])btn(?![\w-])', tag):
            bad.append(f'{rel}:{s.count(chr(10), 0, m.start()) + 1}')

for b in bad:
    print(f'bare <button class="btn"> (use ui/Button.svelte): {b}')
sys.exit(1 if bad else 0)
