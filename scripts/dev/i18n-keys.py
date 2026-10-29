#!/usr/bin/env python3
"""The texts a set of scripts translates (English text = key): i18n-keys.py <script.sh>... prints one key per line.
Used by tests/i18n.sh (core scripts) and by the recipes repository (a recipe's run.sh)."""
import re,sys
sys.stdout.reconfigure(newline='\n')   # Windows Python would write CRLF and every key would miss
call=r'(?:ok|note|warn|fail|step|say|die|ask|ask_secret|confirm|spin|choose|plt|kv|line|status_line|in_ct|_tr|setting [A-Z]+)'
pat_static=re.compile(r'(?<![A-Za-z0-9_])'+call+r' "([^"$`\\]+)"')
pat_static1=re.compile(r"(?<![A-Za-z0-9_])"+call+r" '([^'$`\\]+)'")
pat_t=re.compile(r"(?<![A-Za-z0-9_.-])t '([^']+)'")
pat_t2=re.compile(r'(?<![A-Za-z0-9_.-])t "([^"$`\\]+)"')
keys=set()
for path in sys.argv[1:]:
    raw=open(path,encoding='utf-8').read()
    for m in re.finditer(r'^[ \t]*# i18n: (.+)$', raw, re.M):   # texts looked up at render time (table cells): listed by the script
        keys.update(k.strip() for k in m.group(1).split('|') if k.strip())
    s='\n'.join(l for l in raw.split('\n') if not l.lstrip().startswith('#'))
    for blk in re.finditer(r"say \"\$_l\"; done <<'EOF'\n(.*?)\nEOF\n", s, re.S):
        keys.update(l for l in blk.group(1).split('\n') if l.strip())
    for blk in re.finditer(r"(?<![A-Za-z0-9_])thead((?: '[^'$`\\]+')+)", s):
        keys.update(re.findall(r"'([^']+)'", blk.group(1)))
    for m in re.finditer(r'(?<![A-Za-z0-9_])ask_yes "[^"]*" "([^"$`\\]+)"', s):   # ask_yes <yes-flag> "question"
        keys.add(m.group(1))
    for m in re.finditer(r'(?<![A-Za-z0-9_])status_line "[^"]+" "([^"$`\\]+)"', s):   # the value of status_line is translated too
        keys.add(m.group(1))
    for pat in (pat_static,pat_static1,pat_t,pat_t2):
        keys.update(m.group(1) for m in pat.finditer(s))
# lines the interface reads or machine output: never translated
skip=('Plan','Command','Note:','ALL DATA','Dry run','Current array','layout:','state:','not created yet')
for k in sorted(keys):
    if k.strip() and not k.lstrip().startswith(skip) and k.strip() != '-':
        print(k)
