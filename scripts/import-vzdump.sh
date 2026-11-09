#!/usr/bin/env bash
# help: -
# help.de: -
# args: <archive>
# hs ct import-vzdump: look into a Proxmox vzdump archive and show how an LXC backup would map onto an Incus instance. Read-only: the archive is
# streamed (only etc/vzdump/pct.conf is read, nothing is unpacked or written), nothing is created. A VM archive (.vma) is only recognised.
# The restore into Incus is NOT built: docs/adr/0024-import-proxmox-vzdump.md is the plan. UNVERIFIED on real Proxmox archives.
# The analysis is scripts/lib/vzdump_import.py.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/ui.sh"

[ $# -eq 1 ] && [[ "$1" != -* ]] || fail "$(t 'Usage: hs ct import-vzdump <archive>')"
[ -f "$1" ] && [ -r "$1" ] || fail "$(t 'Cannot read the archive: %s' "$1")"
errf=$(mktemp); trap 'rm -f "$errf"' EXIT
rows=$(python3 -I "$here/lib/vzdump_import.py" "$1" 2>"$errf") || {
  warn "$(t 'The archive could not be read: %s' "$(head -n1 "$errf")")"
  exit 1
}
show() {   # show <heading> <kind>
  local h=$1 kind=$2 k lv where text first=1
  while IFS=$'\t' read -r k lv where text; do
    [ "$k" = "$kind" ] || continue
    if [ "$first" = 1 ]; then step "$h"; first=0; fi
    if [ "$lv" = warn ]; then warn "$text ($where)"; else kv "$where" "$text"; fi
  done <<<"$rows"
}
step "$(t 'Proxmox archive %s' "$(basename "$1")")"
show "$(t 'Archive')" summary
show "$(t 'Top folders')" top
show "$(t 'Maps to Incus')" map
show "$(t 'Not carried over')" unmapped
ok "$(t 'Read-only: nothing was unpacked or created.')"
note "$(t 'UNVERIFIED: the restore is not built yet, and this plan was checked against test archives only.')"
