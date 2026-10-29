#!/usr/bin/env bash
# help: the app recipes (hs recipe <name>) with a description, the instance each one sets up and whether it is there
# help.de: die App-Rezepte (hs recipe <Name>) mit Beschreibung, der Instanz, die jedes einrichtet, und ob sie da ist
# args: [--list]
# System command (hs sys recipes list), read only, plain, never translated (English description), never asks. One line per recipe
# (scripts/recipes/<name>.sh, files starting with "_" are helpers), in name order, tab separated:
#   name  description  containers  state
#   description  the `# recipe:` line of the recipe; a short fixed text for a recipe without one
#   containers   the instances the recipe sets up under their default names (comma separated), "-" for none
#   state        installed (all of its instances exist) | partly | not installed | parked (sunshine) | unknown (incus does not answer, e.g. storage locked)
#                matrix-hook sets up no instance of its own: containers = synapse, installed when /var/lib/hs/matrix-hook exists
# Test knobs: HS_INCUS, HS_RECIPES_DIR, HS_STATE_DIR.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/recipe-path.sh"
. "$here/lib/dc.sh"
state_dir=${HS_STATE_DIR:-/var/lib/hs}

# the instance(s) a recipe creates: its `ct=${RECIPE_NAME:-X}` line, or a fixed answer where the script does not have one
containers_of() {
  case "$1" in
    pelican) echo "pelican-panel pelican-wings" ;;
    matrix-hook) echo "synapse" ;;
    domain) dc_name ;;   # dc1, or dc2 on a second server: the ct= line of the recipe is a command, not a name
    *) sed -n 's/^ct=\${RECIPE_NAME:-\([A-Za-z0-9._-]*\)}.*/\1/p' "$(recipe_script "$1")" | head -n1 || true ;;
  esac
}

if have=$(${HS_INCUS:-incus} list -f csv -c n 2>/dev/null); then known=yes; else known=no; have=""; fi
for n in $(recipe_names); do
  f=$(recipe_script "$n")
  d=$(sed -n 's/^# recipe: //p' "$f" | head -n1 || true); d=${d//$'\r'/}
  case "${d,,}" in "$n: "*) d=${d#*: } ;; esac   # "arr: Radarr and ..." -> "Radarr and ..." (the name is shown beside it)
  d=${d^}
  [ -n "$d" ] || d="App recipe $n (hs recipe $n)"
  cts=$(containers_of "$n" || true)
  if [ "$n" = sunshine ]; then state=parked
  elif [ "$known" = no ]; then state=unknown
  elif [ "$n" = matrix-hook ]; then
    if [ -e "$state_dir/matrix-hook" ]; then state=installed; else state="not installed"; fi
  else
    have_n=0; all_n=0
    for c in $cts; do all_n=$((all_n + 1)); if grep -qxF "$c" <<<"$have"; then have_n=$((have_n + 1)); fi; done
    if [ "$all_n" = 0 ] || [ "$have_n" = 0 ]; then state="not installed"; elif [ "$have_n" = "$all_n" ]; then state=installed; else state=partly; fi
  fi
  list=${cts// /,}
  printf '%s\t%s\t%s\t%s\n' "$n" "$d" "${list:--}" "$state"
done
