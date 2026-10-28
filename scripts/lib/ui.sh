# shellcheck shell=bash
# How the hs commands talk on a terminal; sourced, not run (it lives in lib/
# so `hs` does not offer it as a command):
#   . "$(dirname "$0")/lib/ui.sh"
#
# On a terminal with `gum` (https://github.com/charmbracelet/gum) a long step
# is one line with a spinner, and its output is only shown when it fails.
# Without gum, or when the output is piped (timers, the interface reading a
# script), the same lines are printed plainly, without colours or spinners.
# HS_PLAIN=1 forces the plain form.
#
#   steps N                       the command has N headings: they become ├ ... └ (optional, before the first step)
#   step "Title"                  a heading
#   ok / note / warn "text"       one line: done, remark, attention
#   fail "text"                   the same in red, then exit 1
#   spin "Title" cmd args...      run cmd behind one line; output in $spin_out,
#                                 printed only on failure. SPIN_SOFT=1 spin ...:
#                                 a failure is expected and only noted.
#   box <<TEXT                    closing text in a frame
#   ask "Question" [default]      one line of input, shown as "Question (default): ";
#                                 enter alone gives the default      -> stdout
#   ask_secret "Question"         the same, not shown    -> stdout
#   confirm "Question"            yes/no, returns 0 for yes
#   table                         tab separated lines on stdin, first is the header
#   choose "Header" option...     pick one line                        -> stdout
#   choose_multi "Header" line... pick several lines (space selects)   -> stdout, one per line
#   menu "Header" key "text"...   pick one entry of a list of keys with a description -> the key
#   kv "Label" "value"            one fact, label dimmed and aligned
#   trail                         stdin as trailing output: indent 6, dimmed (a journal, a log)
#   next_step "hs cmd"            a dim "Next: ..." line under a result
#   fail_fix "text" "hs cmd"      the failure line plus "Fix: hs cmd", then exit 1
#   elapsed_line                  "Finished in 2:05" (only when the command ran 5 s or more)
#   danger "text"               the line before something is erased (bold red)
#   confirm_name <name> "text"    type the name of what is changed; returns 0 only when it matches
#   Design rules for all of it: docs/CLI-DESIGN.md

. "$(dirname "${BASH_SOURCE[0]}")/i18n.sh"

ui=plain
if [ -t 1 ] && [ -z "${HS_PLAIN:-}" ] && command -v gum >/dev/null 2>&1; then ui=gum; fi
# Catppuccin Mocha, like the interface
c_blue='#89b4fa'; c_green='#a6e3a1'; c_yellow='#f9e2af'; c_red='#f38ba8'; c_dim='#6c7086'; c_text='#cdd6f4'
export GUM_SPIN_SPINNER_FOREGROUND=$c_blue GUM_SPIN_TITLE_FOREGROUND=$c_text
export GUM_INPUT_PROMPT_FOREGROUND=$c_blue GUM_INPUT_CURSOR_FOREGROUND=$c_green
export GUM_CONFIRM_SELECTED_BACKGROUND=$c_green GUM_CONFIRM_SELECTED_FOREGROUND='#1e1e2e'

paint() {   # paint <colour> <text>
  if [ "$ui" = gum ]; then gum style --foreground "$1" "$2"; else echo "$2"; fi
}
# `steps N` says how many headings the command prints (also across `exec`: the counter is exported). With it the
# headings are drawn as a tree, ├ for the first and the steps in between, └ for the last; without it (a script that
# does not know) the heading keeps the plain ▸. The plain form without gum stays ── Title ──.
steps() { export HS_STEP_TOTAL=$1 HS_STEP_N=0; }
step() {
  local glyph='▸' n
  if [ "${HS_STEP_TOTAL:-0}" -gt 0 ]; then
    n=$(( ${HS_STEP_N:-0} + 1 ))
    export HS_STEP_N=$n
    if [ "$n" -ge "$HS_STEP_TOTAL" ]; then glyph='└'; else glyph='├'; fi
  fi
  echo
  if [ "$ui" = gum ]; then gum style --bold --foreground "$c_blue" "$glyph $(_tr "$*")"; else echo "── $(_tr "$*") ──"; fi
}
ok()   { paint "$c_green"  "  ✓ $(_tr "$*")"; }
line() { echo "  $(_tr "$*")"; }   # a plain sentence, indent 2, normal colour: for text that is neither a result nor a detail
# status_line <label> <value> [ok|warn|bad]: "  Problems: None ✓" - the summary on top of a status command; the value takes the
# colour and the glyph of the severity (ok green ✓, warn yellow !, bad red ✗)
status_line() {
  local g=✓ c=$c_green
  case "${3:-ok}" in warn) g='!'; c=$c_yellow ;; bad) g=✗; c=$c_red ;; esac
  if [ "$ui" = gum ]; then
    printf '  %s %s
' "$(_ansi "$(_fg "$c_dim")" "$(_tr "$1"):")" "$(_ansi "$(_fg "$c")" "$(_tr "$2") $g")"
  else printf '  %s: %s %s
' "$(_tr "$1")" "$(_tr "$2")" "$g"; fi
}
note() { paint "$c_dim"    "    $(_tr "$*")"; }
warn() { paint "$c_yellow" "  ! $(_tr "$*")"; }
fail() { paint "$c_red"    "  ✗ $(_tr "$*")"; exit 1; }
# next_step <command or text>: where to go from here, a dim line under a result ("    Next: hs rebuild")
next_step() { paint "$c_dim" "    $(t 'Next: %s' "$*")"; }
# fail_fix <text> <fix command>: the red failure line, the command that fixes it underneath, then exit 1
fail_fix() { paint "$c_red" "  ✗ $(_tr "$1")" >&2; paint "$c_dim" "    $(t 'Fix: %s' "$2")" >&2; exit 1; }
# elapsed_line: "  ✓ Finished in 2:05" - how long the command ran (counted from the first time ui.sh was sourced,
# kept across `exec`). Prints nothing under 5 seconds, so quick runs look as they did.
HS_T0=${HS_T0:-$(date +%s)}; export HS_T0
elapsed_line() {
  local el=$(( $(date +%s) - HS_T0 ))
  [ "$el" -ge 5 ] || return 0
  ok "$(t 'Finished in %s' "$(printf '%d:%02d' $((el / 60)) $((el % 60)))")"
}

# ── Help text (hs help, hs help <command>) ──
# The texts arrive translated already. Without gum every function prints exactly the text the help always had; with gum the
# same structure gets the look of the other components: a blue heading, the command in blue with its arguments dimmed, the
# description underneath. A tool that wants the same look (homeserver-cli on Windows) copies these four lines of layout.
_ansi() { printf '\033[%sm%s\033[0m' "$1" "$2"; }   # _ansi <sgr> <text>
_fg() { printf '38;2;%s' "$(rgb "$1")"; }
help_usage() {   # help_usage "usage: hs <command> [args]"
  if [ "$ui" = gum ]; then
    local label=${1%%: *} rest=${1#*: }
    echo
    case "$1" in
      *": "*) gum style --bold --foreground "$c_blue" "▸ ${label^}"; echo "  $rest" ;;
      *) echo "  $1" ;;
    esac
  else echo "$1"; fi
}
help_section() {   # help_section "commands:": a blank line, then the heading
  local t=${1%:}
  echo
  if [ "$ui" = gum ]; then gum style --bold --foreground "$c_blue" "▸ ${t^}"; else echo "$1"; fi
}
# Long lines (a command with many arguments, a long description) wrap at the terminal width and keep their indent, so
# nothing runs off the screen and the columns stay readable.
_cols() { local c=${COLUMNS:-$(tput cols 2>/dev/null || echo 100)}; [ "$c" -ge 40 ] 2>/dev/null || c=100; echo "$c"; }
_wrap() {   # _wrap <indent> <colour> <text>: the text folded at word borders, every line indented and coloured
  local pad; printf -v pad '%*s' "$1" ''
  printf '%s\n' "$3" | fold -s -w "$(( $(_cols) - $1 - 1 ))" | sed 's/[[:space:]]*$//' | while IFS= read -r l; do
    printf '%s%s\n' "$pad" "$(_ansi "$(_fg "$2")" "$l")"
  done
}
_head() {   # _head <indent> <bold> <command> <arguments>: "command arguments" - the command in blue, the arguments dimmed, wrapped
  local pad lines first
  printf -v pad '%*s' "$1" ''
  lines=$(printf '%s\n' "$3${4:+ $4}" | fold -s -w "$(( $(_cols) - $1 - 5 ))" | sed 's/[[:space:]]*$//')
  first=${lines%%$'\n'*}
  printf '%s%s%s\n' "$pad" "$(_ansi "${2:+1;}$(_fg "$c_blue")" "$3")" "$(_ansi "$(_fg "$c_dim")" "${first#"$3"}")"
  [ "$lines" != "$first" ] || return 0
  printf '%s\n' "${lines#*$'\n'}" | while IFS= read -r l; do printf '%s    %s\n' "$pad" "$(_ansi "$(_fg "$c_dim")" "$l")"; done
}
help_item() {   # help_item <command> <description> [<arguments>]: a list entry, the description indented underneath
  if [ "$ui" = gum ]; then
    _head 2 "" "$1" "${3:-}"
    _wrap 6 "$c_text" "$2"
  elif [ $# -ge 3 ]; then printf '  %s %s\n      %s\n' "$1" "$3" "$2"
  else printf '  %s\n      %s\n' "$1" "$2"; fi
}
help_cmd() {   # help_cmd <command> <arguments> <description>: the head of `hs help <command>`
  if [ "$ui" = gum ]; then
    _head 0 bold "$1" "$2"
    _wrap 4 "$c_text" "$3"
  else printf '%s%s\n    %s\n' "$1" "${2:+ $2}" "$3"; fi
}
help_note() {   # help_note <text>: lines under a command, already indented
  if [ "$ui" = gum ]; then printf '%s\n' "$(_ansi "$(_fg "$c_dim")" "$1")"; else printf '%s\n' "$1"; fi
}

# The spinner of gum's "dot" kind, drawn here instead of by `gum spin` so the last
# lines of what the step prints can trail underneath (SPIN_LINES, default 3): on a
# long step you can see that something is happening and what. Colour codes and
# progress-bar redraws are stripped from those lines; the time shows after 3 s.
spin_frames=(⣾ ⣽ ⣻ ⢿ ⡿ ⣟ ⣯ ⣷)
rgb() { local h=${1#\#}; printf '%d;%d;%d' "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}"; }
live_spin() {   # live_spin <title> <logfile> <command> [args...]
  local title=$1 log=$2; shift 2
  local n=${SPIN_LINES:-3} cols i=0 t0=$SECONDS el rc=0 pid blue dim text first=1 out line
  blue=$(rgb "$c_blue"); dim=$(rgb "$c_dim"); text=$(rgb "$c_text")
  "$@" >"$log" 2>&1 </dev/null &
  pid=$!
  trap 'kill "$pid" 2>/dev/null; printf "\033[?25h"; exit 130' INT TERM
  printf '\033[?25l'
  # The dot turns every 0.1 s, but the time and the trailing lines only change once a
  # second. On a tick the lines are read again and a line is painted only when its text
  # changed; between ticks only the dot is overwritten. Lines are never cleared first
  # (text, then erase-to-end-of-line), so there is no empty flash.
  local last_el=-1 prev=() tail_lines=() k
  while :; do
    el=$((SECONDS - t0))
    out=""
    [ "$first" = 1 ] || out=$(printf '\033[%dA' $((n + 1)))
    if [ "$first" = 1 ] || [ "$el" != "$last_el" ]; then
      last_el=$el
      cols=$(tput cols 2>/dev/null || echo 80)
      mapfile -t tail_lines < <(tail -c 4096 "$log" 2>/dev/null | tr '\r' '\n' | sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g' | grep -v '^[[:space:]]*$' | tail -n "$n" || true)
      out+=$(printf '\r  \033[38;2;%sm%s\033[0m \033[38;2;%sm%s\033[0m' "$blue" "${spin_frames[i % 8]}" "$text" "$title")
      [ "$el" -lt 3 ] || out+=$(printf ' \033[38;2;%sm(%d:%02d)\033[0m' "$dim" $((el / 60)) $((el % 60)))
      out+=$'\033[K\n'
      for ((k = 0; k < n; k++)); do
        line=${tail_lines[k]:-}
        if [ "$first" = 1 ] || [ "$line" != "${prev[k]:-}" ]; then
          out+=$(printf '\r    \033[38;2;%sm%s\033[0m\033[K' "$dim" "${line:0:$((cols - 6))}")
        fi
        out+=$'\n'
        prev[k]=$line
      done
    else
      out+=$(printf '\r\033[2C\033[38;2;%sm%s\033[0m\033[%dB\r' "$blue" "${spin_frames[i % 8]}" $((n + 1)))
    fi
    first=0
    printf '%s' "$out"
    kill -0 "$pid" 2>/dev/null || break
    i=$((i + 1))
    sleep 0.1
  done
  wait "$pid" || rc=$?
  trap - INT TERM
  printf '\033[%dA\033[J\033[?25h' $((n + 1))      # take the block away; the caller prints the result line
  return $rc
}

spin() {   # spin <title> <command> [args...]
  local title log rc=0
  title=$(_tr "$1")
  shift
  log=$(mktemp)
  if [ "$ui" = gum ]; then
    live_spin "$title" "$log" "$@" || rc=$?
  elif [ -n "${SPIN_STREAM:-}" ]; then
    # a long step in a job or a log: its newest progress line every SPIN_EVERY seconds (default 60)
    echo "    $title ..."
    local pid next=$((SECONDS + ${SPIN_EVERY:-60})) last
    "$@" >"$log" 2>&1 </dev/null &
    pid=$!
    trap 'kill "$pid" 2>/dev/null; exit 130' INT TERM
    while kill -0 "$pid" 2>/dev/null; do
      sleep 1
      if [ "$SECONDS" -ge "$next" ]; then
        next=$((SECONDS + ${SPIN_EVERY:-60}))
        last=$(tail -c 4096 "$log" 2>/dev/null | tr '\r' '\n' | sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g' | grep -v '^[[:space:]]*$' | tail -n1 || true)
        [ -z "$last" ] || echo "    $last"
      fi
    done
    wait "$pid" || rc=$?
    trap - INT TERM
  else
    echo "    $title ..."
    "$@" >"$log" 2>&1 </dev/null || rc=$?
  fi
  spin_out=$(cat "$log"); rm -f "$log"
  if [ $rc -ne 0 ] && [ -n "${SPIN_SOFT:-}" ]; then
    warn "$(t '%s: not yet' "$title")"       # the caller tries something else
    return $rc
  fi
  if [ $rc -ne 0 ]; then
    paint "$c_red" "  ✗ $title"
    tail -n "${SPIN_TAIL:-25}" <<<"$spin_out" | sed 's/^/      /'
    return $rc
  fi
  ok "$title"
}

box() {   # long lines wrap inside the box: at most 100 columns wide, and never wider than the terminal (border excluded from --width)
  local w
  echo
  if [ "$ui" = gum ]; then
    w=$(( $(_cols) - 2 )); [ "$w" -le 100 ] || w=100
    gum style --border rounded --border-foreground "$c_green" --padding "0 1" --width "$w" "$(cat)"
  else
    cat
  fi
}

ask() {   # ask <question> [default]
  local answer q
  q=$(_tr "${1%:}")
  if [ "$ui" = gum ]; then
    answer=$(gum input --prompt "$q${2:+ ($2)}: " --placeholder "${2:+$(t 'enter keeps %s' "$2")}") || exit 130
  else
    read -r -p "$q${2:+ ($2)}: " answer
  fi
  echo "${answer:-${2:-}}"
}

ask_secret() {   # ask_secret <question>
  local answer
  if [ "$ui" = gum ]; then
    gum input --password --prompt "$(_tr "$1") "
  else
    read -r -s -p "$(_tr "$1") " answer; echo >&2
    echo "$answer"
  fi
}

choose() {   # choose <header> <option>...: the chosen option on stdout, nothing on stdin needed
  local header answer i
  header=$(_tr "$1")
  shift
  [ $# -gt 0 ] || return 1
  if [ "$ui" = gum ]; then
    gum choose --header "$header" "$@"
    return
  fi
  echo "$header" >&2
  for i in $(seq 1 $#); do printf '  %d) %s\n' "$i" "${!i}" >&2; done
  read -r -p "$(t 'Number:') " answer
  [[ "$answer" =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ] && [ "$answer" -le $# ] || return 1
  echo "${!answer}"
}

confirm() {   # confirm <question>
  local answer
  if [ "$ui" = gum ]; then
    gum confirm "$(_tr "$1")"
  else
    read -r -p "$(_tr "$1") $(t '[y/N]') " answer
    [[ "$answer" =~ ^[yYjJ] ]]
  fi
}

choose_multi() {   # choose_multi <header> <line>...: the chosen lines on stdout, one per line
  local header answer i n pick
  header=$(_tr "$1")
  shift
  [ $# -gt 0 ] || return 1
  if [ "$ui" = gum ]; then
    gum choose --no-limit --header "$header  ($(t 'space selects, enter confirms'))" "$@"
    return
  fi
  echo "$header" >&2
  for i in $(seq 1 $#); do printf '  %d) %s\n' "$i" "${!i}" >&2; done
  read -r -p "$(t 'Numbers, separated by commas:') " answer
  for n in $(tr ',' ' ' <<<"$answer"); do
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $# ] || return 1
    pick=${!n}
    echo "$pick"
  done
}

menu() {   # menu <header> <key> <text> [<key> <text>...]: the chosen key
  local header=$1 args lines=() w=0 i answer
  shift
  args=("$@")
  for ((i = 0; i < ${#args[@]}; i += 2)); do [ ${#args[i]} -le "$w" ] || w=${#args[i]}; done
  for ((i = 0; i < ${#args[@]}; i += 2)); do lines+=("$(printf '%-*s  %s' "$w" "${args[i]}" "${args[i + 1]}")"); done
  answer=$(choose "$header" "${lines[@]}") || return 1
  echo "${answer%% *}"
}

kv() {   # kv <label> <value>; KV_WIDTH=N kv ... when the labels are longer than the default 16
  if [ "$ui" = gum ]; then
    printf '    \033[38;2;%sm%-*s\033[0m %s\n' "$(rgb "$c_dim")" "${KV_WIDTH:-16}" "$(_tr "$1")" "$2"
  else
    printf '    %-*s %s\n' "${KV_WIDTH:-16}" "$(_tr "$1")" "$2"
  fi
}

# trail: lines of another program's output from stdin as trailing output - indent 6, dimmed (a journal, a log)
trail() { local l; while IFS= read -r l; do paint "$c_dim" "      $l"; done; }

danger() { if [ "$ui" = gum ]; then gum style --bold --foreground "$c_red" "  ! $(_tr "$*")"; else echo "$(_tr "$*")"; fi; }

confirm_name() {   # confirm_name <name> <what>: type the name of what is changed
  local name=$1 what=$2 answer
  if [ "$ui" = gum ]; then
    answer=$(gum input --prompt "  $(t 'Type %s (%s) to continue:' "$what" "$name") " --placeholder "$name") || return 1
  else
    read -r -p "$(t 'Type %s (%s) to continue:' "$what" "$name") " answer
  fi
  [ "$answer" = "$name" ]
}

thead() {   # thead <cell>...: the header line of a table for people, every cell translated (tab separated)
  local c first=1
  for c in "$@"; do
    [ "$first" = 1 ] || printf '	'
    first=0
    _tr "$c"
  done
  printf '
'
}

table() {   # tab separated lines on stdin, the first line is the header
  if [ "$ui" = gum ]; then
    # Same look as the other components: indent 2, a dim bold header with a thin rule, the first column in blue,
    # the last one coloured when it is a status (ok, failed, never ...). Alignment first, colours after, so wide
    # characters do not shift anything; the cells are cut at the header's column starts.
    column -t -s $'\t' -o '  ' | sed 's/[[:space:]]*$//' | awk \
      -v blue="$(rgb "$c_blue")" -v dim="$(rgb "$c_dim")" -v text="$(rgb "$c_text")" \
      -v green="$(rgb "$c_green")" -v red="$(rgb "$c_red")" -v yellow="$(rgb "$c_yellow")" -v cols="$(_cols)" '
      function col(c, t) { return sprintf("\033[38;2;%sm%s\033[0m", c, t) }
      function status(t,   u) {
        u = t
        if (u ~ /^(ok|running|active|ONLINE|on|yes|done|erledigt|läuft|aktiv|an|ja)$/) return green
        if (u ~ /^(failed|fail|error|BAD|DEGRADED|FAULTED|UNAVAIL|MISSING|WRONG|fehlgeschlagen|FEHLER|FALSCH)$/) return red
        if (u ~ /^(WATCH|warn|stale|open|offen)$/) return yellow
        if (u ~ /^(never|-|off|none|no|nie|aus|nein|keine)$/) return dim
        return text
      }
      function row(line,   out, c, cell, t) {
        out = ""
        for (c = 1; c <= n; c++) {
          cell = substr(line, start[c], start[c + 1] - start[c])
          if (c == 1) cell = col(blue, cell)
          else if (c == n) { t = cell; gsub(/ +$/, "", t); cell = col(status(t), cell) }
          else cell = col(text, cell)
          out = out cell
        }
        return "  " out
      }
      NR == 1 {
        n = 0; rest = $0; pos = 1
        while (match(rest, /[^ ]+( [^ ]+)*/)) {   # words with single spaces are one header cell
          start[++n] = pos + RSTART - 1
          pos += RSTART + RLENGTH - 1; rest = substr(rest, RSTART + RLENGTH)
        }
        start[n + 1] = 100000
        hdr = $0; maxw = length($0)
        next
      }
      { body[++nb] = $0; if (length($0) > maxw) maxw = length($0) }
      END {
        # the rule is as wide as the widest line (but not wider than the terminal), so it spans the table
        w = maxw; if (w > cols - 4) w = cols - 4
        printf "  \033[1m%s\033[0m\n", col(dim, hdr)
        rule = ""; for (k = 0; k < w; k++) rule = rule "─"
        printf "  %s\n", col(dim, rule)
        for (r = 1; r <= nb; r++) print row(body[r])
      }'
  else
    column -t -s $'\t'
  fi
}
