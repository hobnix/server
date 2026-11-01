#!/usr/bin/env bash
# help: the app recipes (hs recipe <name>) with the available and the applied version
# help.de: die App-Rezepte (hs recipe <Name>) mit der verfügbaren und der angewendeten Version
# args: [--list]
# System command (hs sys recipes versions), read only, plain, never translated, never asks. One line per recipe
# (same names as recipes-list.sh), in name order, tab separated, no empty field:
#   name  available  applied  state
#   available  version in the recipe's package.toml, "-" if there is none
#   applied    version the last successful run of the default container applied (installed.toml key applied), "-" = not known
#   state      current (equal) | update (they differ) | unknown (one of them is "-")
# Test knobs: HS_RECIPES_DIR, HS_STATE_DIR.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/recipe-path.sh"

applied=$(python3 -I "$here/pkg.py" applied 2>/dev/null || true)
for n in $(recipe_names); do
  f="$(dirname "$(recipe_script "$n")")/package.toml"
  avail=$(sed -n '/^version *= *"/{s/^version *= *"\([^"]*\)".*/\1/p;q}' "$f" 2>/dev/null || true)
  [ -n "$avail" ] || avail=-
  app=$(awk -F'\t' -v n="$n" '$1 == n { print $2; exit }' <<<"$applied")
  [ -n "$app" ] || app=-
  if [ "$avail" = - ] || [ "$app" = - ]; then state=unknown
  elif [ "$avail" = "$app" ]; then state=current
  else state=update; fi
  printf '%s\t%s\t%s\t%s\n' "$n" "$avail" "$app" "$state"
done
