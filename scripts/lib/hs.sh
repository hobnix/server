#!/usr/bin/env bash
# The `hs` dispatcher: looks the words up in the command list (scripts/lib/registry.tsv plus the commands.tsv of every enabled
# extension package, scripts/lib/registry-load.sh) and runs the script.
# The Nix wrapper only opens the interface and escalates to root; everything else is here.
#   hs help [--all]              grouped list (--all adds the system commands)
#   hs help <words...>           what one command (or every command under those words) does, with the
#                                explanation from the script's header; works without the docs site
#   hs help --search <words>     full text search in the commands and the guides (docs/*.md), offline
#   hs sys registry              the registry as text
#   hs sys complete <words...>   candidates for the next word (shell completion)
#   hs sys <area> <verb>         system commands: machine-readable, for the interface and timers
# A person who runs a `hs sys ...` command by hand gets a short warning first; the interface,
# timers and tests set HS_CALLER (ui, timer, job, test, cli) and are not asked.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
dir=$(dirname "$here")
. "$here/setting.sh"
. "$here/capability.sh"
. "$here/registry-load.sh"
lang=${HS_LANG:-$(setting_get language 2>/dev/null || echo en)}

rows() { registry_rows; }

# a script of the registry: a path under scripts/, or an absolute one (a file of an extension package, written as @/file there)
script_file() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s' "$dir/$1" ;; esac; }

# header text of a script: "# help:" / "# help.<lang>:" and "# args:"
header() {   # header <script> <key>
  sed -n "s/^# $2: //p" "$(script_file "$1")" | head -n1
}
help_of() {   # help_of <script> <help_en> <help_de>
  local d=""
  if [ "$lang" != en ]; then
    d=$3
    [ "$d" != "-" ] || d=$(header "$1" "help.$lang")
  fi
  if [ -z "$d" ] || [ "$d" = "-" ]; then
    d=$2
    [ "$d" != "-" ] || d=$(header "$1" help)
  fi
  printf '%s' "$d"
}

tr_txt() {   # the few sentences of the dispatcher itself
  if [ "$lang" = de ]; then
    case "$1" in
      usage) echo "Aufruf: hs <Befehl> [Argumente]" ;;
      cmds) echo "Befehle:" ;;
      sys) echo "Systembefehle (für die Oberfläche und Zeitpläne, mit: hs help --all):" ;;
      list) echo "zeigt diese Liste" ;;
      unknown) echo "hs: unbekannter Befehl" ;;
      warn) echo "Das ist ein Systembefehl: er ist für die Oberfläche und Zeitpläne gedacht, nicht für die Hand." ;;
      ask) echo "Trotzdem ausführen?" ;;
      long) echo "Das kann lange dauern (Minuten bis Stunden) und belastet die Platten." ;;
      bg) echo "Im Hintergrund als Auftrag ausführen? (Nein = hier warten)" ;;
      nocmd) echo "Dazu gibt es keinen Befehl" ;;
      s_cmds) echo "Befehle:" ;;
      s_docs) echo "Anleitungen:" ;;
      s_more) echo "... weitere Treffer, suche genauer" ;;
      s_none) echo "Nichts gefunden für" ;;
      s_usage) echo "Aufruf: hs help --search <Wort>" ;;
    esac
  else
    case "$1" in
      usage) echo "usage: hs <command> [args]" ;;
      cmds) echo "commands:" ;;
      sys) echo "system commands (for the interface and timers):" ;;
      list) echo "show this list" ;;
      unknown) echo "hs: unknown command" ;;
      warn) echo "This is a system command: it is meant for the interface and timers, not for the hand." ;;
      ask) echo "Run it anyway?" ;;
      long) echo "This can take long (minutes to hours) and puts load on the disks." ;;
      bg) echo "Run it in the background as a job? (No = wait here)" ;;
      nocmd) echo "No such command" ;;
      s_cmds) echo "commands:" ;;
      s_docs) echo "guides:" ;;
      s_more) echo "... more matches, search more precisely" ;;
      s_none) echo "Nothing found for" ;;
      s_usage) echo "usage: hs help --search <word>" ;;
    esac
  fi
}

# A command of a capability that is off (flag capability:<name>, docs/PLAN-modular-core.md step 3) is left out of `hs help`;
# `hs help --all` and `hs help <command>` still show it, and it can be run: `hs vps key` is how the vps capability is set up.
cap_hidden() {   # cap_hidden <flags>: true for a row of a capability that is off
  local c
  case ",${1:-}," in *,capability:*) ;; *) return 1 ;; esac
  c=${1#*capability:}; c=${c%%,*}
  ! capability_on "$c"
}

usage() {   # usage [--all]
  [ -n "${ui:-}" ] || . "$here/ui.sh"
  local kind path script args hen hde a
  help_usage "$(tr_txt usage)"; help_section "$(tr_txt cmds)"
  while IFS=$'\t' read -r kind path script args hen hde flags; do
    [ "$kind" = user ] || continue
    case ",${flags:-}," in *,nohelp,*) continue ;; esac
    [ "${1:-}" = --all ] || ! cap_hidden "${flags:-}" || continue
    # a blank line between the groups (disk, share, ct, ...)
    [ "${path%% *}" = "${prev:-}" ] || { [ -z "${prev:-}" ] || echo; prev=${path%% *}; }
    a=""
    [ "$hen" != "-" ] || a=$(header "$script" args)
    help_item "$path" "$(help_of "$script" "$hen" "$hde")" "$a"
  done < <(rows)
  help_item "help [--all]" "$(tr_txt list)"
  if [ "${1:-}" = --all ]; then
    help_section "$(tr_txt sys)"
    while IFS=$'\t' read -r kind path script args hen hde; do
      [ "$kind" = sys ] || continue
      help_item "$path" "$(help_of "$script" "$hen" "$hde")"
    done < <(rows)
  fi
}

# What one command does: every user row whose path starts with the words (a <value> in the path
# matches any word), with the text from the script's header comment below its "# args:" line.
help_for() {   # help_for <words...>
  [ -n "${ui:-}" ] || . "$here/ui.sh"
  local kind path script args hen hde flags words i ok w a n=0 t took detail pass
  local -a typed=("$@")
  # pass 1: the words are all command words (hs help share rename); pass 2: a word may be a value (hs help share docs)
  for pass in 1 2; do
    while IFS=$'\t' read -r kind path script args hen hde flags; do
      [ "$kind" = user ] || continue
      read -ra words <<<"$path"
      ok=1; t=0; took=0
      for ((i = 0; i < ${#words[@]} && t < ${#typed[@]}; i++)); do
        w=${words[$i]}
        case "$w" in
          "<"*)
            if [ -n "${words[$((i + 1))]:-}" ] && [ "${words[$((i + 1))]}" = "${typed[$t]}" ]; then :
            elif [ "$pass" = 2 ]; then t=$((t + 1)); took=1
            else ok=0; break; fi ;;
          *) if [ "$w" = "${typed[$t]}" ]; then t=$((t + 1)); else ok=0; break; fi ;;
        esac
      done
      [ "$ok" = 1 ] && [ "$t" -ge "${#typed[@]}" ] || continue
      [ "$pass" = 1 ] || [ "$took" = 1 ] || continue
      case ",${flags:-}," in *,nohelp,*) continue ;; esac
      n=$((n + 1))
      a=""
      [ "$hen" != "-" ] || a=$(header "$script" args)
      [ "$a" != "(none)" ] || a=""
      help_cmd "hs $path" "$a" "$(help_of "$script" "$hen" "$hde")"
      # the comment block under "# args:" explains how it works
      detail=$(awk '/^# args:/ { on = 1; next } on && /^# / { sub(/^# /, ""); print "    " $0; n++; if (n >= 14) exit } on && !/^#/ { exit }' "$(script_file "$script")" 2>/dev/null || true)
      [ -z "$detail" ] || help_note "$detail"
      echo
    done < <(rows)
    [ "$n" = 0 ] || return 0
  done
  warn "$(tr_txt nocmd): hs ${typed[*]}" >&2
  next_step "hs help" >&2
  return 1
}

# hs help --search <words>: offline full text search in the commands (path and help text in the
# language in use) and in the guides (docs/*.md). Plain text, case-insensitive, changes nothing.
search() {   # search <words...>
  local q=$* kind path script args hen hde flags h n=0 d=0 docs f line no txt hay max=30
  local lq=${q,,}
  [ -n "${ui:-}" ] || . "$here/ui.sh"
  docs=$(dirname "$dir")/docs
  while IFS=$'\t' read -r kind path script args hen hde flags; do
    [ "$kind" = user ] || continue
    case ",${flags:-}," in *,nohelp,*) continue ;; esac
    h=$(help_of "$script" "$hen" "$hde")
    hay="hs ${path,,}${h,,}"
    case "$hay" in *"$lq"*) ;; *) continue ;; esac
    [ "$n" -gt 0 ] || help_section "$(tr_txt s_cmds)"
    n=$((n + 1))
    help_item "hs $path" "$h"
  done < <(rows)
  if [ -d "$docs" ]; then
    while IFS= read -r line; do
      if [ "$d" -eq 0 ]; then help_section "$(tr_txt s_docs)"; fi
      d=$((d + 1))
      [ "$d" -le "$max" ] || continue
      f=${line%%:*}; line=${line#*:}
      no=${line%%:*}; txt=${line#*:}
      txt=$(printf '%s' "$txt" | sed -E 's/^[[:space:]#>*|-]+//; s/[[:space:]]+/ /g')
      [ "${#txt}" -le 110 ] || txt="${txt:0:107}..."
      line "docs/$(basename "$f"):$no: $txt"
    done < <(grep -n -i -e "$(printf '%s' "$q" | sed 's/[][\.*^$/]/\\&/g')" "$docs"/*.md 2>/dev/null || true)
    [ "$d" -le "$max" ] || line "$(tr_txt s_more)"
  fi
  if [ "$n" -eq 0 ] && [ "$d" -eq 0 ]; then
    warn "$(tr_txt s_none): $q"
    return 1
  fi
  return 0
}

# --- completion ---------------------------------------------------------------------
cache_dir=${HS_COMPLETE_DIR:-/run/hs/complete}
cached() {   # cached <name> <command...>: output of an unprivileged lookup, kept 30 s
  local f=$cache_dir/$1 age
  shift
  if [ -f "$f" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$f") ))
    if [ "$age" -lt 30 ]; then cat "$f"; return; fi
  fi
  mkdir -p "$cache_dir" 2>/dev/null || { "$@" 2>/dev/null; return; }
  "$@" 2>/dev/null | tee "$f.tmp.$$" >/dev/null
  mv -f "$f.tmp.$$" "$f" 2>/dev/null; cat "$f" 2>/dev/null
}
values_of() {   # values_of <placeholder>
  case "$1" in
    "<share>") cached shares sh -c 'ls "${HS_BULK:-/bulk}/shares" "${HS_BULK:-/bulk}/sensitive" 2>/dev/null | grep -v "^$\|:$"' | sort -u ;;
    "<pool>")  cached pools sh -c '{ zpool list -H -o name 2>/dev/null; printf "bulk\nfast\n"; } | sort -u' ;;
    "<ct>")    cached cts sh -c 'incus list -f csv -c n 2>/dev/null' ;;
    "<user>")  cached users sh -c 'wbinfo -u 2>/dev/null | sed "s/^.*\\\\//"' ;;
    "<group>") cached groups sh -c 'wbinfo -g 2>/dev/null | sed "s/^.*\\\\//"' ;;
    "<disk>")  cached disks sh -c 'ls /dev/disk/by-id 2>/dev/null | grep -v -- "-part[0-9]*$\|^wwn-"' ;;
    "<package>") ext_package_names ;;
  esac
}
complete_words() {   # complete_words <typed words...>: what can come next
  local typed=("$@") n=$# kind path script i ok w words lit
  local -a seen=() seen_ph=()
  while IFS=$'\t' read -r kind path script _; do
    read -ra words <<<"$path"
    [ "${#words[@]}" -gt "$n" ] || continue
    ok=1; lit=1
    for ((i = 0; i < n; i++)); do
      w=${words[$i]}
      case "$w" in "<"*) lit=0 ;; *) [ "$w" = "${typed[$i]}" ] || { ok=0; break; } ;; esac
    done
    [ "$ok" = 1 ] || continue
    # system commands only show once `sys` was typed
    if [ "$kind" = sys ] && [ "${typed[0]:-}" != sys ]; then continue; fi
    # a word typed as a value (a disk, a share) must not hide what the literal paths offer
    if [ "$lit" = 1 ]; then seen+=("${words[$n]}"); else seen_ph+=("${words[$n]}"); fi
  done < <(rows)
  [ ${#seen[@]} -gt 0 ] || [ ${#seen_ph[@]} -eq 0 ] || seen=("${seen_ph[@]}")
  # but values and literals can both follow: `hs share <TAB>` = add, repair and the shares
  [ "$n" -ne 1 ] || [ ${#seen_ph[@]} -eq 0 ] || seen+=("${seen_ph[@]}")
  [ "$n" -gt 0 ] || seen+=(help sys)
  local c
  [ ${#seen[@]} -gt 0 ] || return 0
  for c in $(printf '%s\n' "${seen[@]}" | sort -u); do
    case "$c" in "<"*) values_of "$c" ;; *) echo "$c" ;; esac
  done
}

# --- lookup -------------------------------------------------------------------------
# Longest registry path that matches the start of the arguments; <values> match any word and
# are passed on to the script in order.
find_row() {   # find_row <args...> -> sets row_* and consumed
  local best=0 kind path script args hen hde flags words i ok w
  local -a all=("$@") vals=()
  row_script=""; row_vals=()
  while IFS=$'\t' read -r kind path script args hen hde flags; do
    read -ra words <<<"$path"
    [ "${#words[@]}" -le "$#" ] || continue
    [ "${#words[@]}" -gt "$best" ] || continue
    ok=1; vals=()
    for ((i = 0; i < ${#words[@]}; i++)); do
      w=${words[$i]}
      case "$w" in
        "<"*) vals+=("${all[$i]}") ;;
        *) [ "$w" = "${all[$i]}" ] || { ok=0; break; } ;;
      esac
    done
    [ "$ok" = 1 ] || continue
    best=${#words[@]}; row_kind=$kind; row_path=$path; row_script=$script; row_args=$args; row_flags=${flags:-}
    row_vals=("${vals[@]+"${vals[@]}"}")
  done < <(rows)
  consumed=$best
}

# The arguments for the script: the values first, then the fixed arguments, then what the person
# typed after the words. A fixed-arguments field with {1} {2} ... {rest} is a template instead:
# `--test {rest} {1}` for `hs disk sda test short` -> `--test short sda`.
build_args() {
  cmd_args=()
  local fixed=() t
  [ "$row_args" = "-" ] || read -ra fixed <<<"$row_args"
  case "$row_args" in
    *"{"*)
      for t in ${fixed[@]+"${fixed[@]}"}; do
        case "$t" in
          "{rest}") cmd_args+=(${rest[@]+"${rest[@]}"}) ;;
          "{"[1-9]"}") t=${t#\{}; t=${t%\}}; cmd_args+=("${row_vals[$((t - 1))]}") ;;
          *"{"*"}"*)   # a token with a value inside: ip={rest} -> ip=10.10.95.5
            local i2
            for i2 in 1 2 3 4 5 6 7 8 9; do t=${t//\{$i2\}/${row_vals[$((i2 - 1))]:-}}; done
            t=${t//\{rest\}/${rest[*]:-}}
            cmd_args+=("$t") ;;
          *) cmd_args+=("$t") ;;
        esac
      done ;;
    *) cmd_args=(${row_vals[@]+"${row_vals[@]}"} ${fixed[@]+"${fixed[@]}"} ${rest[@]+"${rest[@]}"}) ;;
  esac
}

# A long command says so first and, when confirmed on a terminal, runs as a job
long_guard() {   # long_guard <args...>
  case ",$row_flags," in *,long,*) ;; *) return 0 ;; esac
  [ -z "${HS_CALLER:-}" ] || return 0
  { [ -t 1 ] || [ -n "${HS_FORCE_TTY:-}" ]; } || return 0
  local a=() x fg=0
  for x in "$@"; do if [ "$x" = --foreground ]; then fg=1; else a+=("$x"); fi; done
  set -- ${a[@]+"${a[@]}"}
  [ "$fg" = 0 ] || { rest=("$@"); return 0; }
  . "$here/ui.sh"; . "$here/job.sh"
  warn "$(tr_txt long)"
  if confirm "$(tr_txt bg)"; then
    local unit
    rest=("$@"); build_args
    local shown=$row_path v   # the command as typed: the values instead of <pool>, <share>, ...
    for v in ${row_vals[@]+"${row_vals[@]}"}; do
      [[ $shown =~ ^([^<]*)\<[^\>]*\>(.*)$ ]] && shown="${BASH_REMATCH[1]}$v${BASH_REMATCH[2]}"
    done
    unit=$(hs_job "${shown// /-}" "hs $shown" -- bash "$(script_file "$row_script")" ${cmd_args[@]+"${cmd_args[@]}"}) || exit 1
    ok "$(t 'Started as job %s. Follow it: hs job follow %s' "$unit" "$unit")"
    exit 0
  fi
  rest=("$@")
}

sys_guard() {
  [ "$row_kind" = sys ] || return 0
  [ -z "${HS_CALLER:-}" ] || return 0
  { [ -t 1 ] || [ -n "${HS_FORCE_TTY:-}" ]; } || return 0
  . "$here/ui.sh"
  warn "$(tr_txt warn)"
  confirm "$(tr_txt ask)" || exit 1
}

cmd=${1:-help}
case "$cmd" in
  help|-h|--help)
    case "${2:-}" in
      ""|--all) usage "${2:-}"; exit 0 ;;
      --search) [ $# -ge 3 ] || { . "$here/ui.sh"; say "$(tr_txt s_usage)" >&2; exit 1; }
                search "${@:3}"; exit $? ;;
      *) help_for "${@:2}"; exit $? ;;
    esac ;;
esac

# An extension package that is off: say how to switch it on instead of "unknown command"
ext_off_guard() {   # ext_off_guard <args...>
  [ "${1:-}" = ext ] && [ -n "${2:-}" ] || return 0
  ext_package_dir "$2" >/dev/null || return 0
  ext_package_on "$2" && return 0
  . "$here/ui.sh"
  warn "$(t "The extension '%s' is off." "$2")" >&2
  next_step "hs ext enable $2" >&2
  exit 1
}

# A row with the flag legacy:<new words> is an old command word that moved into an extension: it says so (stderr) and still runs for one
# release when the extension is on; when it is off it only says how to switch it on.
legacy_guard() {
  local new name
  case ",$row_flags," in *,legacy:*) ;; *) return 0 ;; esac
  new=${row_flags#*legacy:}; new=${new%%,*}
  name=${new#ext }; name=${name%% *}
  . "$here/ui.sh"
  warn "$(t "'hs %s' has moved to the extension %s: hs %s" "$row_path" "$name" "$new")" >&2
  if ! ext_package_on "$name"; then
    next_step "hs ext enable $name" >&2
    exit 1
  fi
  # the old words run the script of the new row (a package script, as an absolute path); the script column of a legacy row is only a placeholder
  local s
  s=$(rows | awk -F'	' -v p="$new" '$2 == p { print $3; exit }')
  [ -n "$s" ] || { warn "$(t "The extension '%s' has no command 'hs %s'." "$name" "$new")" >&2; exit 1; }
  row_script=$s
}

if [ "$cmd" = sys ] && [ "${2:-}" = registry ]; then
  printf '%s\n' "kind	path	script	args"
  while IFS=$'\t' read -r kind path script args _; do printf '%s\t%s\t%s\t%s\n' "$kind" "$path" "$script" "$args"; done < <(rows)
  exit 0
fi
if [ "$cmd" = sys ] && [ "${2:-}" = complete ]; then
  shift 2
  complete_words "$@"
  exit 0
fi

find_row "$@"
if [ -z "$row_script" ] || [ "$row_script" = "-" ]; then
  ext_off_guard "$@"
  . "$here/ui.sh"
  warn "$(tr_txt unknown) '$*'" >&2
  usage >&2
  exit 1
fi
shift "$consumed"
legacy_guard
sys_guard
# system commands (hs sys ...) are for programs and timers: never the styled form, even on a terminal
[ "$row_kind" != sys ] || export HS_PLAIN=1
rest=("$@")
long_guard "$@"
build_args
# package scripts find the core helpers through HS_SCRIPTS (the scripts folder this dispatcher belongs to)
export HS_SCRIPTS="$dir"
exec bash "$(script_file "$row_script")" ${cmd_args[@]+"${cmd_args[@]}"}
