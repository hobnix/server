#!/usr/bin/env bash
# help: build the documentation pages (guides plus a command reference made from the command registry)
# help.de: die Dokumentationsseiten bauen (Anleitungen und eine Befehlsübersicht aus der Befehlsliste)
# args: [--out <dir>] [--quiet]
# Writes plain Markdown (<out>/en) plus index.json (the groups and titles, scripts/lib/docs-index.py). The web interface (capability
# docs, page Docs) serves and renders them; nothing is compiled and nothing is fetched. The command pages come from scripts/lib/registry.tsv
# plus the commands.tsv of the extension packages that are on (scripts/lib/registry-load.sh), so they cannot be out of date. `hs update` builds them again while the capability is on.
# HS_DOCS_OUT, HS_STATE_DIR, HS_REGISTRY: tests and stand-ins.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=${HS_REPO:-$(dirname "$here")}
# On the server the scripts run from the Nix store, which has no docs/: use the checkout.
[ -d "$repo/docs" ] || repo=/etc/nixos
. "$here/lib/ui.sh"
state=${HS_STATE_DIR:-/var/lib/hs}
out=${HS_DOCS_OUT:-$state/docs-site}
registry=${HS_REGISTRY:-$here/lib/registry.tsv}
. "$here/lib/registry-load.sh"
all_rows=$(registry_rows)   # the core list plus the commands of the extensions that are on
quiet=false

usage() { say "usage: hs docs build [--out <dir>] [--quiet]"; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --out) [ $# -ge 2 ] || usage; out=$2; shift 2 ;;
    --quiet) quiet=true; shift ;;
    *) usage ;;
  esac
done

# ---- helpers -----------------------------------------------------------------------------------
slug() {   # "Container einrichten" -> container-einrichten
  printf '%s' "$1" | sed -e 's/ä/ae/g; s/ö/oe/g; s/ü/ue/g; s/Ä/Ae/g; s/Ö/Oe/g; s/Ü/Ue/g; s/ß/ss/g' |
    tr 'A-Z' 'a-z' | sed -e 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//'
}
title_of() { sed -n 's/^# //p' "$1" | head -n1; }
header() { local f=$here/$1; case "$1" in /*) f=$1 ;; esac; { [ -f "$f" ] && sed -n "s/^# $2: //p" "$f" | head -n1; } || true; }
help_of() {   # help_of <lang> <script> <help_en> <help_de>
  local d=""
  if [ "$1" = de ]; then
    d=$4
    [ "$d" != "-" ] || d=$(header "$2" help.de)
  fi
  if [ -z "$d" ] || [ "$d" = "-" ]; then
    d=$3
    [ "$d" != "-" ] || d=$(header "$2" help)
  fi
  printf '%s' "$d"
}
md() {   # text for a table cell: a pipe would end the cell (the renderer shows <tags> as text, so nothing else is escaped)
  printf '%s' "$1" | sed -e 's/|/\\|/g'
}

# ---- the command reference ---------------------------------------------------------------------
commands_page() {   # commands_page <lang>
  local lang=$1 kind path script args hen hde flags a first n h
  local t_cmd t_what t_general t_sys  t_sys_txt t_intro
  if [ "$lang" = de ]; then
    t_cmd=Befehl; t_what="Was er tut"; t_general=Allgemein; t_sys="Systembefehle"
    t_intro="Alle Befehle des Servers. Diese Seite wird aus der Befehlsliste (\`scripts/lib/registry.tsv\`) erzeugt und ist deshalb immer aktuell. \`<so>\` ist ein Wert, den du einsetzt. \`hs help\` zeigt dasselbe im Terminal."
    t_sys_txt="Für die Oberfläche und die Zeitpläne, maschinenlesbar. Von Hand nur zum Nachsehen (mit \`HS_CALLER=hand\` entfällt die Rückfrage nicht)."
  else
    t_cmd=Command; t_what="What it does"; t_general=General; t_sys="System commands"
    t_intro="Every command of the server. This page is generated from the command list (\`scripts/lib/registry.tsv\`), so it is always up to date. \`<like-this>\` is a value you fill in. \`hs help\` shows the same in the terminal."
    t_sys_txt="For the interface and the timers, machine-readable. By hand only to look; a person at a terminal is asked first."
  fi
  echo "# $([ "$lang" = de ] && echo Befehle || echo Commands)"
  echo
  echo "$t_intro"
  # which first words have several rows (a group) and which stand alone (General)
  local -A count=()
  local -a order=()
  while IFS=$'\t' read -r kind path script args hen hde flags; do
    [ "$kind" = user ] || continue
    case ",${flags:-}," in *,nohelp,*) continue ;; esac
    first=${path%% *}
    [ -n "${count[$first]:-}" ] || order+=("$first")
    count[$first]=$(( ${count[$first]:-0} + 1 ))
  done <<<"$all_rows"
  row() {   # row <wanted group or "*general*">
    local want=$1 g
    while IFS=$'\t' read -r kind path script args hen hde flags; do
      [ "$kind" = user ] || continue
      case ",${flags:-}," in *,nohelp,*) continue ;; esac
      g=${path%% *}
      if [ "$want" = "*general*" ]; then
        { [ "${count[$g]}" = 1 ] && [ "$path" = "$g" ]; } || continue
      else
        [ "$g" = "$want" ] || continue
      fi
      a=""
      [ "$hen" != "-" ] || a=$(header "$script" args)
      [ "$a" != "(none)" ] || a=""
      h=$(help_of "$lang" "$script" "$hen" "$hde")
      printf '| `hs %s%s` | %s |\n' "$path" "$(md "${a:+ $a}")" "$(md "$h")"
    done <<<"$all_rows"
  }
  local g
  for g in "${order[@]}"; do
    { [ "${count[$g]}" -gt 1 ] || ! grep -qP "^user\t$g\t" <<<"$all_rows"; } || continue
    echo; echo "## hs $g"; echo
    echo "| $t_cmd | $t_what |"; echo "| --- | --- |"
    row "$g"
  done
  echo; echo "## $t_general"; echo
  echo "| $t_cmd | $t_what |"; echo "| --- | --- |"
  row "*general*"
  # system commands
  echo; echo "## $t_sys"; echo; echo "$t_sys_txt"; echo
  echo "| $t_cmd | $t_what |"; echo "| --- | --- |"
  while IFS=$'\t' read -r kind path script args hen hde flags; do
    [ "$kind" = sys ] || continue
    # system rows carry one help text (English): without it the script and its option are named
    h=$hen
    [ "$h" != "-" ] || h="scripts/$script $args"
    printf '| `hs %s` | %s |\n' "$path" "$(md "$h")"
  done <<<"$all_rows"
}

# ---- build -------------------------------------------------------------------------------------
say_ok() { $quiet || ok "$@"; }
rm -rf "$out.new"; mkdir -p "$out.new/en"
tmp=$out.new

# Guides and contributor documents are English. Names become plain slugs (no spaces, no "+").
# Under the title of every guide: when it was last worked through on a real server (docs/verified.tsv, `hs docs verified`); no row = never.
# One italic line, no HTML.
verified_line() {   # verified_line <file name without .md>
  local d
  d=$(awk -F'\t' -v g="$1" '$0 !~ /^#/ && $1 == g { print $2; exit }' "$repo/docs/verified.tsv" 2>/dev/null || true)
  printf '*Last worked through on a real server: %s*' "${d:-never}"
}
for f in "$repo"/docs/*.md; do
  b=$(basename "$f")
  [ "$b" = README.md ] && continue   # index of the folder on GitHub, not a page
  case "$b" in
    CLI-DESIGN.md|Entwicklungsnotizen.md|GUIDE-TEMPLATE.md|PLAN-*.md) cp "$f" "$tmp/en/$(slug "${b%.md}").md" ;;
    *) awk -v s="$(verified_line "${b%.md}")" '{ print } !done && /^# / { print ""; print s; done = 1 }' "$f" > "$tmp/en/$(slug "${b%.md}").md" ;;
  esac
done

# The guide of a package is guide.md in its folder: packages/<recipe>, capabilities/<extension>, and what `hs pkg install` put in
# <state>/packages/current. It joins the group Apps (a recipe) or Extensions under its package name; a core guide of that name wins.
cats=$tmp/_categories.tsv
cp "$repo/docs/categories.tsv" "$cats" 2>/dev/null || : > "$cats"
for d in "$repo"/packages/*/ "$repo"/capabilities/*/ "$state"/packages/current/*/; do
  [ -f "${d}guide.md" ] || continue
  n=$(basename "$d")
  [ ! -f "$tmp/en/$(slug "$n").md" ] || continue
  cp "${d}guide.md" "$tmp/en/$(slug "$n").md"
  if [ -f "${d}capability.toml" ]; then g=Extensions; else g=Apps; fi
  printf 'en\t%s\t%s\n' "$g" "$n" >> "$cats"
done
commands_page en > "$tmp/en/commands.md"

stamp="$(date +%Y-%m-%d)"
rev=$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || true)
{
  echo "# Hobnix documentation"; echo
  echo "Guides for running a Hobnix home server, and the reference of every command (\`hs help\`). Search finds text in all of them."; echo
  echo "- New here? Start with [Install](install.md)."
  echo "- Looking for a command? The [command reference](commands.md) names every one."
  echo "- Something broke? [Backup and recovery](backup-and-recovery.md) says what to do after a disk failure."
  echo "- Apps and extensions have their own guide under Apps and Extensions."; echo
  echo "Built: $stamp${rev:+, version $rev}. Build again: \`hs docs build\` (\`hs update\` does it by itself)."
} > "$tmp/en/start.md"
HS_DOCS_SRC="$repo/docs" python3 "$here/lib/docs-index.py" "$tmp" "$cats" "$stamp" "$rev"
rm -f "$cats"

# swap in the new folder; the web server's mount point (the folder itself) stays the same
if [ -d "$out" ]; then
  find "$out" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  cp -a "$tmp/." "$out/"
  rm -rf "$tmp"
else
  mv "$tmp" "$out"
fi
chmod -R a+rX "$out"
say_ok "$(t 'Documentation built in %s (%s pages)' "$out" "$(find "$out" -name '*.md' ! -name '_*' | wc -l)")"
$quiet || elapsed_line
