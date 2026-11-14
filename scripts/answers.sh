#!/usr/bin/env bash
# help: check an answers file for unattended installs (format: docs/install.md); hs-install does not read it yet
# help.de: eine Antwortdatei für unbeaufsichtigte Installationen prüfen (Format: docs/install.md); hs-install liest sie noch nicht
# args: <file>
# Runs scripts/lib/answers.py: errors and warnings as a table; exit 0 no errors, 1 errors, 2 file unreadable or not valid TOML.
# Secret values are never printed and secret files are never read (only their mode and size).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/ui.sh"

case "${1:-}" in
  -h|--help) note "usage: hs installer check-answers <file>"; exit 0 ;;
  "") note "usage: hs installer check-answers <file>"; exit 1 ;;
esac
file=$1
[ $# -eq 1 ] || { note "usage: hs installer check-answers <file>"; exit 1; }

step "Check the answers file"
rc=0
res=$(python3 -I "$here/lib/answers.py" check "$file") || rc=$?
if [ "$rc" -eq 2 ]; then
  while IFS=$'\t' read -r _ where text; do
    warn "$text"
  done <<<"$res"
  [ -n "$res" ] || warn "the file cannot be read"
  warn "$(t '%s is not a readable TOML file' "$file")"
  exit 2
fi
if [ -n "$res" ]; then
  { thead "Level" "Where" "Problem"; printf '%s\n' "$res"; } | table
fi
if [ "$rc" -ne 0 ]; then
  fail "the answers file has errors; nothing was changed"
fi
ok "the answers file is valid"
note "hs-install does not read it yet"
