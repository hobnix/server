#!/usr/bin/env bash
# help: extension packages (optional parts such as Games and Posters): list them, switch them on or off, show their commands
# help.de: Erweiterungspakete (optionale Teile wie Spiele und Poster): auflisten, an- oder ausschalten, ihre Befehle zeigen
# args: list | enable <package> | disable <package> | <package> | --list
# An extension is a package folder capabilities/<name>/ with a capability.toml (`extension = true`) and a commands.tsv; its commands are
# `hs ext <name> <command>` and the machine-readable `hs sys ext <name> <command>` (docs/PLAN-extensions.md). The folder name is the
# namespace. A package is off until it is named in machine.toml (`capabilities = [...]`); its commands do not exist while it is off.
#   list              the packages, whether each is on, and how many commands it brings
#   --list            the same as data (hs sys ext list): name, on|off, commands, nix (yes = a rebuild is needed to switch it), title
#   enable <name>     machine.toml gets the name in `capabilities`. A package without a Nix module is on at once (the file
#                     $HS_STATE_DIR/capabilities-on says so until the next rebuild); one with a module needs `hs rebuild`, and is told so
#   disable <name>    the reverse (capabilities-off wins over everything until the next rebuild; a package that something else keeps on says so)
#   <name>            the commands of the package (also while it is off, marked as such); a word after it that is no command is named
# Test knobs: HS_MACHINE_FILE, HS_STATE_DIR, HS_PACKAGES_DIR, HS_CAPABILITIES_FILE, HS_LANG.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/ui.sh"
. "$here/lib/machine.sh"
. "$here/lib/registry-load.sh"
state=${HS_STATE_DIR:-/var/lib/hs}
lang=${HS_LANG:-$(setting_get language 2>/dev/null || echo en)}

usage() {
  say "usage: hs ext list"
  say "       hs ext enable <package>"
  say "       hs ext disable <package>"
  say "       hs ext <package>"
  exit 1
}

script_file() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s' "$here/$1" ;; esac; }
manifest() {   # manifest <dir> <key>: a plain string of capability.toml (package.toml for a recipe)
  local f=$1/capability.toml
  [ -f "$f" ] || f=$1/package.toml
  sed -n "s/^$2[[:space:]]*=[[:space:]]*\"\(.*\)\"[[:space:]]*$/\1/p" "$f" | head -n1
}
title_of() {   # title_of <dir>
  local t=""
  [ "$lang" = en ] || t=$(manifest "$1" "title_$lang")
  [ -n "$t" ] || t=$(manifest "$1" title)
  printf '%s' "$t"
}
has_nix() { [ -f "$1/module.nix" ]; }
n_commands() {   # n_commands <name>: user commands of the package
  registry_rows_of "$1" | awk -F'\t' '$1 == "user" { n++ } END { print n + 0 }'
}
exists() {   # exists <name>: a package of this server
  [[ "${1:-}" =~ ^[a-z][a-z0-9-]{0,30}$ ]] || return 1
  ext_package_names | grep -qxF -- "$1"
}
is_recipe() {   # is_recipe <name>: a recipe package (it is applied with hs recipe, not switched with hs ext enable)
  local d; d=$(ext_package_dir "$1") || return 1
  [ ! -f "$d/capability.toml" ]
}
need_package() {
  exists "${1:-}" || fail_fix "$(t "No extension called '%s'" "${1:-}")" "hs ext list"
}

overlay_add() { mkdir -p "$state"; grep -qxF -- "$2" "$state/capabilities-$1" 2>/dev/null || printf '%s\n' "$2" >> "$state/capabilities-$1"; }
overlay_del() {
  [ -f "$state/capabilities-$1" ] || return 0
  grep -vxF -- "$2" "$state/capabilities-$1" > "$state/capabilities-$1.tmp" || true
  mv "$state/capabilities-$1.tmp" "$state/capabilities-$1"
}

caps_list() {   # the names in machine.toml `capabilities`, one per line
  machine_has capabilities || return 0
  machine_get capabilities 2>/dev/null || true
}
caps_write() {   # caps_write <name>...: the list back as a TOML array
  local v="" n
  for n in "$@"; do v+="${v:+, }\"$n\""; done
  machine_set capabilities "[$v]" ext
}

cmd_list() {   # people list
  local n d st rows=""
  while IFS= read -r n; do
    d=$(ext_package_dir "$n") || continue
    [ -f "$d/capability.toml" ] || continue
    if ext_package_on "$n"; then st=on; else st=off; fi
    rows+="$n"$'\t'"$st"$'\t'"$(n_commands "$n")"$'\t'"$(title_of "$d")"$'\n'
  done < <(ext_package_names)
  if [ -z "$rows" ]; then note "No extension packages on this server."; return 0; fi
  { thead 'Package' 'State' 'Commands' 'What it is'; printf '%s' "$rows"; } | table
  next_step "hs ext enable <package>"
}

cmd_data() {   # hs sys ext list
  local n d st
  while IFS= read -r n; do
    d=$(ext_package_dir "$n") || continue
    [ -f "$d/capability.toml" ] || continue
    if ext_package_on "$n"; then st=on; else st=off; fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$st" "$(n_commands "$n")" "$(has_nix "$d" && echo yes || echo no)" "$(manifest "$d" title)"
  done < <(ext_package_names)
}

cmd_enable() {
  local n=${1:-} d cur=() x found=0
  [ -n "$n" ] || usage
  need_package "$n"
  d=$(ext_package_dir "$n")
  if is_recipe "$n"; then fail_fix "$(t "'%s' is a recipe: it is applied, not switched on." "$n")" "hs recipe $n"; fi
  if ext_package_on "$n"; then note "$(t "The extension '%s' is on already." "$n")"; return 0; fi
  mapfile -t cur < <(caps_list)
  for x in ${cur[@]+"${cur[@]}"}; do [ "$x" != "$n" ] || found=1; done
  if [ "$found" = 0 ]; then caps_write ${cur[@]+"${cur[@]}"} "$n"; fi
  if has_nix "$d"; then
    ok "$(t "Extension '%s' is in machine.toml." "$n")"
    warn "$(t "It brings a NixOS module: it is on after a rebuild.")"
    next_step "hs rebuild"
  else
    overlay_del off "$n"; overlay_add on "$n"
    ok "$(t "Extension '%s' is on." "$n")"
    next_step "hs ext $n"
  fi
}

cmd_disable() {
  local n=${1:-} d cur=() keep=() x
  [ -n "$n" ] || usage
  need_package "$n"
  d=$(ext_package_dir "$n")
  if is_recipe "$n"; then fail_fix "$(t "'%s' is a recipe: its container is managed with hs ct." "$n")" "hs ct"; fi
  mapfile -t cur < <(caps_list)
  for x in ${cur[@]+"${cur[@]}"}; do [ "$x" = "$n" ] || keep+=("$x"); done
  if [ ${#keep[@]} -ne ${#cur[@]} ]; then caps_write ${keep[@]+"${keep[@]}"}; fi
  if has_nix "$d"; then
    ok "$(t "Extension '%s' is out of machine.toml." "$n")"
    warn "$(t "It brings a NixOS module: it is off after a rebuild.")"
    next_step "hs rebuild"
  else
    overlay_del on "$n"; overlay_add off "$n"
    ok "$(t "Extension '%s' is off." "$n")"
  fi
}

help_of() {   # help_of <script> <help_en> <help_de>
  local d="" f
  f=$(script_file "$1")
  if [ "$lang" != en ]; then
    d=$3
    [ "$d" != "-" ] || d=$(sed -n "s/^# help\.$lang: //p" "$f" 2>/dev/null | head -n1)
  fi
  if [ -z "$d" ] || [ "$d" = "-" ]; then
    d=$2
    [ "$d" != "-" ] || d=$(sed -n 's/^# help: //p' "$f" 2>/dev/null | head -n1)
  fi
  printf '%s' "$d"
}

cmd_show() {   # cmd_show <name> [<word that is no command>...]
  local n=${1:-} d kind path script args hen hde flags a
  shift || true
  case "$n" in ""|enable|disable) usage ;; esac
  need_package "$n"
  d=$(ext_package_dir "$n")
  if [ $# -gt 0 ] && ! ext_package_on "$n"; then
    if is_recipe "$n"; then warn "$(t "The recipe '%s' has not been applied yet." "$n")"; next_step "hs recipe $n"; exit 1; fi
    warn "$(t "The extension '%s' is off." "$n")"; next_step "hs ext enable $n"; exit 1
  fi
  if [ $# -gt 0 ]; then warn "$(t "No command '%s' in the extension '%s'." "$*" "$n")"; fi
  help_usage "$(t 'usage: hs ext %s <command>' "$n")"
  if ext_package_on "$n"; then status_line "$n" "$(title_of "$d")" ok
  elif is_recipe "$n"; then status_line "$n" "$(title_of "$d") ($(t 'not applied yet'))" warn
  else status_line "$n" "$(title_of "$d") ($(t 'off'))" warn; fi
  help_section "$(t 'commands:')"
  while IFS=$'\t' read -r kind path script args hen hde flags; do
    [ "$kind" = user ] || continue
    a=""
    [ "$hen" != "-" ] || a=$(sed -n 's/^# args: //p' "$(script_file "$script")" 2>/dev/null | head -n1)
    help_item "$path" "$(help_of "$script" "$hen" "$hde")" "$a"
  done < <(registry_rows_of "$n")
  if is_recipe "$n"; then ext_package_on "$n" || next_step "hs recipe $n"
  elif ! ext_package_on "$n"; then next_step "hs ext enable $n"; fi
  [ $# -eq 0 ]
}

verb=${1:-}
[ $# -eq 0 ] || shift
case "$verb" in
  list) cmd_list ;;
  --list) cmd_data ;;
  enable) cmd_enable "$@" ;;
  disable) cmd_disable "$@" ;;
  show) cmd_show "$@" ;;
  *) usage ;;
esac
