#!/usr/bin/env bash
# help: list the machine.toml changes that wait for a rebuild (staged changes), as data
# help.de: die Änderungen an machine.toml auflisten, die auf einen Rebuild warten (vorgemerkte Änderungen), als Daten
# args: --list
# System command (hs sys rebuild pending), for the web interface's "pending rebuild" banner. A change to a declarative option (docs/adr/0002) is
# written to machine.toml at once and only takes effect with the next `hs rebuild`; several such changes queue up and ONE rebuild applies them all.
# The queue is what differs between machine.toml and the copy `hs rebuild` keeps after a good switch ($HS_STATE_DIR/machine.toml.built).
# Output: one line per option that differs, sorted: key<TAB>built<TAB>now. built = the value the running system was built with, now = the
# value in machine.toml; a missing value is `-`; values are compact JSON, cut at 60 characters. Empty output: nothing waits, or no rebuild
# has kept a copy yet (the queue is unknown until the first rebuild after this version).
# Test knobs: HS_MACHINE_FILE, HS_STATE_DIR.
set -euo pipefail
[ "${1:-}" = --list ] || { echo "usage: pending-rebuild.sh --list" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/machine.sh"
now=$(machine_file)
built=${HS_STATE_DIR:-/var/lib/hs}/machine.toml.built
[ -r "$now" ] && [ -r "$built" ] || exit 0
python3 -I - "$built" "$now" <<'PY'
import json, sys, tomllib
def load(p):
    try:
        with open(p, 'rb') as f: return tomllib.load(f)
    except Exception: return None
a, b = load(sys.argv[1]), load(sys.argv[2])
if a is None or b is None: sys.exit(0)
def show(d, k):
    if k not in d: return '-'
    s = json.dumps(d[k], separators=(',', ':'), ensure_ascii=False)
    s = ''.join(c if c >= ' ' else ' ' for c in s.replace('\t', ' '))
    return (s[:57] + '...') if len(s) > 60 else (s or '-')
for k in sorted(set(a) | set(b)):
    if a.get(k, object()) != b.get(k, object()) or (k in a) != (k in b):
        print(f"{k}\t{show(a, k)}\t{show(b, k)}")
PY
