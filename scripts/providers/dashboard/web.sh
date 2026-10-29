#!/usr/bin/env bash
# Provider "dashboard", variant web (the tile page of the web interface). The contract:
#   web.sh info    key<TAB>value lines: name, mode
#   web.sh sync    nothing to write: hs-web reads the tiles itself; prints one line, exit 0
set -uo pipefail
case "${1:-}" in
  info) printf 'name\tweb\nmode\tauto\n' ;;
  sync) echo "tiles are live" ;;
  *) echo "usage: web.sh info|sync" >&2; exit 1 ;;
esac
