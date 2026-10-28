#!/usr/bin/env bash
# Provider "dashboard", variant homepage (docs/PLAN-modular-core.md step 4d). The contract:
#   homepage.sh info    key<TAB>value lines: name, mode
#   homepage.sh sync    write the links again from the services that want a dashboard tile; prints one line ("12 links"), exit 1 on an error
# The links of Homepage are written by the recipe (scripts/recipes/homepage.sh, which reads the tiles from `hs services tiles`); sync is its
# fast path (--refresh): no container set-up, no questions.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
case "${1:-}" in
  info) printf 'name\thomepage\nmode\tauto\n' ;;
  sync)
    out=$(bash "$(. "$here/../../lib/recipe-path.sh"; recipe_script homepage)" --refresh 2>&1) || { tail -n 1 <<<"$out" >&2; exit 1; }
    tail -n 1 <<<"$out" ;;
  *) echo "usage: homepage.sh info|sync" >&2; exit 1 ;;
esac
