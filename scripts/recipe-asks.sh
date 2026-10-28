#!/usr/bin/env bash
# help: the questions a recipe wants answered before it runs (for the web interface): key, label, kind, default, pattern, when
# help.de: die Fragen, die ein Rezept vor dem Start beantwortet haben will (für die Weboberfläche): Schlüssel, Text, Art, Vorgabe, Muster, Bedingung
# args: <recipe>
# System command (hs sys recipes asks <recipe>): one tab separated row per `# ask:` line in the header of scripts/recipes/<recipe>.sh, no header row.
#   # ask: KEY|label|kind|default|pattern|when
#   kind     text | secret | choice:a,b,c   (a secret travels on standard input and is never shown again)
#   default  what the field starts with ("-" in the output when empty)
#   pattern  a regular expression the whole value must match (text only; "-" when empty)
#   when     KEY=value: the question only counts while the answer to KEY is that value ("-" when empty)
# A row with an empty first row means the recipe asks nothing. The last row `input<TAB>form|terminal|none` says how the recipe takes its answers:
# form = the web interface can (the rows above), terminal = it needs a person at a terminal, none = nothing to ask.
# Test knob: HS_RECIPES_DIR.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/recipe-path.sh"
name=${1:-}
[[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || { echo "usage: hs sys recipes asks <recipe>" >&2; exit 1; }
file=$(recipe_script "$name" 2>/dev/null) || { echo "There is no recipe called '$name'." >&2; exit 1; }
sed -n 's/^# ask: //p' "$file" | awk -F'|' 'NF >= 3 {
  for (i = 4; i <= 6; i++) if ($i == "") $i = "-"
  printf "%s\t%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4, $5, $6
}' OFS='|'
input=$(sed -n 's/^# input: //p' "$file" | head -n1 || true)
printf 'input\t%s\n' "${input:-none}"
