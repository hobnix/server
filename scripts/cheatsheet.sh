#!/usr/bin/env bash
# help: one-page German cheat sheet of the most useful commands (Markdown, to print)
# help.de: Spickzettel auf einer Seite mit den wichtigsten Befehlen (Markdown, zum Ausdrucken)
# args: [--out <file>]
# Reads only the command list (scripts/lib/registry.tsv and the commands.tsv of the extensions that are on): the rows with a `cheat:<group>` flag in the flags column, grouped by task
# (server, disks, shares, users, backup, update, trouble) in the order of the file. The text is the row's German
# help (the script header's `# help.de:` when the row has none). The page is always German (the cousin's guide
# language). The docs site is English only, so it has no page for it. HS_REGISTRY: tests.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
registry=${HS_REGISTRY:-$here/lib/registry.tsv}
. "$here/lib/registry-load.sh"
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) [ $# -ge 2 ] || { echo "usage: hs cheatsheet [--out <file>]" >&2; exit 1; }; out=$2; shift 2 ;;
    *) echo "usage: hs cheatsheet [--out <file>]" >&2; exit 1 ;;
  esac
done

header() { local f=$here/$1; case "$1" in /*) f=$1 ;; esac; { [ -f "$f" ] && sed -n "s/^# $2: //p" "$f" | head -n1; } || true; }
md() { printf '%s' "$1" | sed -e 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/|/\\|/g'; }

page() {
  local g title kind path script args hen hde flags f grp h
  echo "# Spickzettel"
  echo
  echo "Die wichtigsten Befehle des Servers auf einer Seite. Alles Weitere: \`hs help\` (oder die Taste \`?\` in der Oberfläche \`hs\`). Werte in <spitzen Klammern> setzt du selbst ein."
  for g in server:"Den Server ansehen" disks:"Platten und Speicher" shares:"Freigaben" users:"Benutzer" backup:"Sicherung" update:"Aktualisieren" trouble:"Wenn etwas klemmt"; do
    grp=${g%%:*}; title=${g#*:}
    echo; echo "## $title"; echo
    echo "| Befehl | Was er tut |"; echo "| --- | --- |"
    while IFS=$'\t' read -r kind path script args hen hde flags; do
      [ "$kind" = user ] || continue
      case ",${flags:-}," in *,cheat:"$grp",*) ;; *) continue ;; esac
      h=$hde
      [ "$h" != "-" ] || h=$(header "$script" help.de)
      [ "$h" != "-" ] && [ -n "$h" ] || h=$hen
      [ "$h" != "-" ] && [ -n "$h" ] || h=$(header "$script" help)
      printf '| `hs %s` | %s |\n' "$path" "$(md "$h")"
    done < <(registry_rows)
  done
  echo
  echo "<small>Erzeugt aus der Befehlsliste (\`hs cheatsheet\`), deshalb immer aktuell. Als Datei: \`hs cheatsheet --out spickzettel.md\`.</small>"
}

if [ -n "$out" ]; then page > "$out"; else page; fi
