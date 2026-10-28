#!/usr/bin/env bash
# help: install and set up a complete app in one go (without a name: choose from a list)
# help.de: richtet eine ganze Anwendung in einem Schritt ein (ohne Namen: Auswahl aus einer Liste)
# args: [name] [--name <container>] [--dry-run]
set -euo pipefail

# A recipe is a script in scripts/recipes/ that creates the container,
# installs the app and connects it to this server, without questions.
# Running it again repairs or updates the setup instead of starting over.
# Files starting with "_" are shared helpers, not recipes.
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/recipe-path.sh"

# The header lines of a recipe: "# kind: generic|personal" (personal = built around this server's own setup), "# needs: docker share tailscale"
# (what must be there, "-" = nothing) and "# uses: gpu" (used when there). tests/recipes-meta.sh keeps them true.
recipe_needs() {   # recipe_needs <file>: what it needs, and "(personal)" for a recipe built around one setup
  local n k
  n=$(sed -n 's/^# needs: //p' "$1" | head -n1 || true); k=$(sed -n 's/^# kind: //p' "$1" | head -n1 || true)
  [ "$n" != - ] || n=""
  [ "$k" != personal ] || n="${n:+$n }(personal)"
  echo "${n:--}"
}

recipes() {   # name<TAB>description<TAB>needs (in the language of machine.toml, English where there is none)
  local f d n
  for n in $(recipe_names); do
    f=$(recipe_script "$n")
    d=""
    [ "$hs_lang" = en ] || d=$(sed -n "s/^# recipe.$hs_lang: //p" "$f" | head -n1)
    printf '%s\t%s\t%s\n' "$n" "${d:-$(sed -n 's/^# recipe: //p' "$f" | head -n1)}" "$(recipe_needs "$f")"
  done
}

if [ $# -eq 0 ] && [ -t 0 ] && [ -t 1 ] && [ -z "${HS_PLAIN:-}" ]; then
  # pick one from a list (gum, or a numbered list without it); esc or no answer leaves without running anything
  mapfile -t options < <(recipes | awk -F'\t' '{ printf "%-12s  %s\n", $1, $2 }')
  choice=$(choose "Which recipe? (enter runs it, esc cancels)" "${options[@]}") || exit 0
  set -- "${choice%% *}"
  confirm "$(t "Run the recipe '%s' now? (no: only show what it would do)" "$1")" || set -- "$1" --dry-run
fi

if [ $# -eq 0 ] || [ "$1" = --list ]; then
  line "Recipes (run with: hs recipe <name>):"
  { thead 'RECIPE' 'WHAT' 'NEEDS'; recipes; } | table
  exit 0
fi

name="$1"; shift
# --name <container>: a container of your own name, to run one recipe more than once (a second Jellyfin, another Docker host).
# The recipes read it as RECIPE_NAME; each keeps its answers per container (recipe-<container>.conf).
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --name) [ $# -ge 2 ] || { fail "$(t 'Give a container name after --name.')"; exit 1; }; export RECIPE_NAME=$2; shift 2 ;;
    --name=*) export RECIPE_NAME=${1#--name=}; shift ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]+"${args[@]}"}"
if [ -n "${RECIPE_NAME:-}" ] && ! [[ "$RECIPE_NAME" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]]; then
  fail "$(t "'%s' is not a container name (lower-case letters, digits and dashes, starting with a letter or digit)." "$RECIPE_NAME")"
  exit 1
fi
# a recipe from a repository (hs pkg install) brings its own run.sh; it sources the helpers through $HS_RECIPE_LIB
# a recipe is packages/<name>/run.sh (the checkout, /etc/nixos, or a package installed from a repository); it finds the shared helpers through these
script=$(recipe_script "$name" 2>/dev/null) || script=""
export HS_SCRIPTS="$here" HS_RECIPE_LIB="$here/recipes/_lib.sh" HS_RECIPE_MEDIA="$here/recipes/_media.sh"
if [[ "$name" == _* ]] || [ -z "$script" ]; then
  warn "$(t "No recipe called '%s'." "$name")"
  bash "$0" --list
  exit 1
fi
# --check: what would a run change? Only recipes that name their pieces (check_done in the script) can say; the others are not run at all
case " $* " in *" --check "*)
  if ! grep -q '^ *check_done' "$script"; then
    note "$(t "The recipe '%s' does not report its pieces yet; hs recipe %s --dry-run says what it does." "$name" "$name")"
    exit 0
  fi ;;
esac
# a finished run remembers the package version it applied (hs pkg updates compares it with the tree); a look (--dry-run, --refresh) does not count
rc=0
bash "$script" "$@" || rc=$?
case " $* " in *" --dry-run "*|*" --refresh "*|*" --list "*|*" --check "*) ;; *) [ "$rc" -ne 0 ] || python3 -I "$here/pkg.py" record "$name" 2>/dev/null || true ;; esac
exit "$rc"
