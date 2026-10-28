# shellcheck shell=bash
# Where a recipe lives (docs/PLAN-packages.md): packages/<name>/run.sh in the checkout, the same under /etc/nixos (the scripts run from a copy
# in the Nix store that has no packages/), or /var/lib/hs/packages/current/<name>/run.sh for one installed from a repository (hs pkg install).
# The first folder that has the recipe wins. Test knob: HS_RECIPES_DIR names the ONE folder that holds <name>/run.sh.
#   recipe_dirs            the folders that hold recipes, one per line
#   recipe_script <name>   the path of the recipe's run.sh (exit 1 when there is none)
#   recipe_names           every recipe name, one per line, sorted, without duplicates
_recipe_lib=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
recipe_dirs() {
  local d
  if [ -n "${HS_RECIPES_DIR:-}" ]; then echo "$HS_RECIPES_DIR"; return 0; fi
  for d in "$_recipe_lib/../../packages" /etc/nixos/packages "${HS_STATE_DIR:-/var/lib/hs}/packages/current"; do
    [ ! -d "$d" ] || (cd "$d" && pwd)
  done | awk '!seen[$0]++'
}
recipe_script() {
  local d
  [[ "${1:-}" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || return 1
  while IFS= read -r d; do
    if [ -f "$d/$1/run.sh" ]; then echo "$d/$1/run.sh"; return 0; fi
  done < <(recipe_dirs)
  return 1
}
recipe_names() {
  local d f
  while IFS= read -r d; do
    for f in "$d"/*/run.sh; do
      [ -f "$f" ] || continue
      f=$(basename "$(dirname "$f")")
      [[ "$f" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] && echo "$f"
    done
  done < <(recipe_dirs) | sort -u
}
