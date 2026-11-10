#!/usr/bin/env bash
# help: the steps a recipe groups its questions into (for the web interface): step id, label, help text, the keys asked in it
# help.de: die Schritte, in die ein Rezept seine Fragen gruppiert (für die Weboberfläche): Schritt, Text, Hilfetext, die Schlüssel der Fragen
# args: <recipe> [<container>]
# System command (hs sys recipes steps <recipe>): one tab separated row per `# step:` line in the header of the recipe, no header row, in the order
# of the header. A recipe without `# step:` lines has no rows (the web interface then shows one step for all questions).
#   # step: ID|label            a page of the wizard (ID: lower-case letters, digits, dashes)
#   # help: ID|text             the grey line under that page's heading (plain text)
#   # ask: KEY|label|kind|default|pattern|when|step     the 7th field puts the question on that page (recipe-change.sh and recipe-asks.sh
#                                                          ignore it, so their output does not change)
# Columns: id, label, help, keys (comma separated, in the order of the `# ask:` lines); "-" when empty. A question without a step stays out of
# every row: the web interface puts it on a page of its own, after the declared ones. A step nobody asks in is still listed (it is a page of
# text only). Test knob: HS_RECIPES_DIR.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/recipe-path.sh"
name=${1:-}
[[ "${2:-x}" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] && [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || { echo "usage: hs sys recipes steps <recipe> [<container>]" >&2; exit 1; }
file=$(recipe_script "$name" 2>/dev/null) || { echo "There is no recipe called '$name'." >&2; exit 1; }
sed -n -e 's/^# step: /S|/p' -e 's/^# help: /H|/p' -e 's/^# ask: /A|/p' "$file" | awk -F'|' '
  function clean(s) { gsub(/[\t\r]/, " ", s); return s }
  $1 == "S" && $2 ~ /^[a-z0-9][a-z0-9-]{0,40}$/ && !($2 in lab) { order[++n] = $2; lab[$2] = clean($3) }
  $1 == "H" && $2 ~ /^[a-z0-9][a-z0-9-]{0,40}$/ { h = $3; for (i = 4; i <= NF; i++) h = h "|" $i; hlp[$2] = clean(h) }
  $1 == "A" && NF >= 8 && $8 != "" { keys[$8] = keys[$8] (keys[$8] == "" ? "" : ",") $2 }
  END {
    for (i = 1; i <= n; i++) {
      id = order[i]
      printf "%s\t%s\t%s\t%s\n", id, (lab[id] == "" ? "-" : lab[id]), (hlp[id] == "" ? "-" : hlp[id]), (keys[id] == "" ? "-" : keys[id])
    }
  }'
