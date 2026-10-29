#!/usr/bin/env bash
# help: run an app recipe without asking anything: what would happen (plan), then do it as a background job (start)
# help.de: ein Rezept ausführen, ohne etwas zu fragen: was passieren würde (plan), dann als Hintergrundjob ausführen (start)
# args: plan|start <recipe> run [--name <container>] [--set KEY=value]...
# System command (hs sys recipes plan|start): for the interface and tests. It never asks and prints plain key<TAB>value lines like
# dns-change.sh. The work is recipe.sh's. A recipe run this way has no terminal, so every preference takes the answer stored last time or
# its default, and every question the recipe declares (`# ask:` lines in its header, `hs sys recipes asks <recipe>`) must be answered:
#   --set KEY=value   an answer to a text, choice or usb (vendor:product) question (it reaches the recipe as RECIPE_<KEY> in the job's environment)
#   standard input    ONE line: the answer to the secret question that counts (never in an argument, a log or the environment: the job runner
#                     writes it as a root-only file in a folder that is removed when the job ends; the recipe reads it with `answer KEY`)
#   run   set the app up, or bring it up to date (recipes are safe to run again)
# A recipe whose header says `# input: terminal` needs a person at a terminal (domain: the Administrator password is typed into Samba): it is
# refused here and the plan names the command. A parked recipe (sunshine) is refused too.
# plan: exit 0 = allowed, 1 = refused, 2 = an answer is missing (status needs, needs<TAB><KEY>). Output: status ok|refused|needs,
#   reason<TAB><text>, heading|step|note|warn|command<TAB><line>, long<TAB>yes. The values and the secret are never printed.
# start: the same checks, then the work runs as a background job (status started, unit).
# Test knobs: HS_RECIPES_DIR (the folder with the recipes), HS_RECIPE (stand-in for recipe.sh), HS_RUN_DIR (where the secret file goes).
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/recipe-path.sh"
recipe=${HS_RECIPE:-$here/recipe.sh}

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

verb=${1:-}; name=${2:-}; action=${3:-}
case "$verb" in plan|start) ;; *) echo "usage: recipe-change.sh plan|start <recipe> run [--name <container>] [--set KEY=value]..." >&2; exit 1 ;; esac
[[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || refuse "invalid recipe name"
[ "$action" = run ] || refuse "unknown action (run)"
shift 3 || true
ct=""
declare -A given=()
while [ $# -gt 0 ]; do
  case "$1" in
    --name) [ $# -ge 2 ] || refuse "--name needs a value"; ct=$2; shift 2 ;;
    --set)  [ $# -ge 2 ] || refuse "--set needs KEY=value"
            [[ "$2" =~ ^([A-Z][A-Z0-9_]{0,30})=(.*)$ ]] || refuse "--set needs KEY=value"
            given[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}; shift 2 ;;
    *) refuse "unknown option $1" ;;
  esac
done
[ -z "$ct" ] || [[ "$ct" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || refuse "'$ct' is not a container name (lower-case letters, digits and dashes)"
file=$(recipe_script "$name" 2>/dev/null) || refuse "There is no recipe called '$name'."

input=$(sed -n 's/^# input: //p' "$file" | head -n1 || true)
if [ "$input" = terminal ]; then
  refuse "$name needs a person at a terminal (a password is typed into the setup): hs recipe $name${ct:+ --name $ct}"
fi
if [ "$name" = sunshine ]; then refuse "sunshine is parked: it does nothing unless it is forced from a terminal."; fi

# the questions of the recipe: parallel arrays
ak=() al=() at=() ad=() ap=() aw=()
while IFS='|' read -r k l t d p w _; do
  [ -n "$k" ] || continue
  ak+=("$k"); al+=("$l"); at+=("$t"); ad+=("$d"); ap+=("$p"); aw+=("$w")
done < <(sed -n 's/^# ask: //p' "$file")

value_of() {   # value_of <key>: what is given, else the default
  local i
  if [ -n "${given[$1]+x}" ]; then printf '%s' "${given[$1]}"; return; fi
  for i in "${!ak[@]}"; do [ "${ak[$i]}" = "$1" ] && { printf '%s' "${ad[$i]}"; return; }; done
}
active() {   # active <index>: does the `when` condition hold
  local w=${aw[$1]}
  [ -z "$w" ] && return 0
  [ "$(value_of "${w%%=*}")" = "${w#*=}" ]
}

# every --set names a question of the recipe
for k in "${!given[@]}"; do
  found=false
  for i in "${!ak[@]}"; do [ "${ak[$i]}" = "$k" ] && [ "${at[$i]}" != secret ] && found=true; done
  $found || refuse "$name does not ask '$k'"
done

secret_key="" secret_label=""
needs=()
for i in "${!ak[@]}"; do
  active "$i" || continue
  k=${ak[$i]}; t=${at[$i]}
  if [ "$t" = secret ]; then secret_key=$k; secret_label=${al[$i]}; continue; fi
  v=$(value_of "$k")
  if [ -z "$v" ]; then
    # a text question without a pattern may stay empty (the countries of a VPN); every other one needs an answer
    if [ "$t" = text ] && [ -z "${ap[$i]}" ]; then continue; fi
    needs+=("$k"); continue
  fi
  case "$t" in
    choice:*) [[ ",${t#choice:}," == *",$v,"* ]] || refuse "'$v' is not one of: ${t#choice:} ($k)" ;;
    usb) [[ "$v" =~ ^[0-9a-f]{4}:[0-9a-f]{4}$ ]] || refuse "the answer to $k is not a vendor:product like 04f9:0042" ;;
    *) [[ "$v" =~ ^(${ap[$i]:-.*})$ ]] || refuse "the answer to $k does not fit ($(sed 's/ (.*//' <<<"${al[$i]}"))" ;;
  esac
  [[ "$v" != *[[:cntrl:]]* ]] || refuse "the answer to $k has a control character"
done

# the secret: one line on standard input, only while a secret question counts
secret=""
if [ -n "$secret_key" ]; then
  IFS= read -r -t 3 secret || true
  [ -n "$secret" ] || needs+=("$secret_key")
  [[ "$secret" != *[[:cntrl:]]* ]] || refuse "the secret has a control character"
fi
if [ ${#needs[@]} -gt 0 ]; then
  printf 'status\tneeds\n'
  printf 'needs\t%s\n' "${needs[@]}"
  exit 2
fi

cmd=(bash "$recipe" "$name"); [ -z "$ct" ] || cmd+=(--name "$ct")
export HS_PLAIN=1 HS_LANG=en HS_CALLER=${HS_CALLER:-ui}
unset HS_GUIDED_TTY

if [ "$verb" = start ]; then
  . "$here/lib/job.sh"
  env_lines=""
  for i in "${!ak[@]}"; do
    active "$i" || continue
    [ "${at[$i]}" != secret ] || continue
    v=$(value_of "${ak[$i]}")
    [ -z "$v" ] || env_lines+="RECIPE_${ak[$i]}=$v"$'\n'
  done
  slug="recipe-$name${ct:+-$ct}"
  if [ -n "$secret_key" ]; then
    # the secret is a root-only file that the job reads (`answer`) and removes when it ends
    run=${HS_RUN_DIR:-/run/hs}
    mkdir -p "$run"; chmod 700 "$run" 2>/dev/null || true
    sdir=$(mktemp -d "$run/recipe-secret.XXXXXX")
    chmod 700 "$sdir" 2>/dev/null || true
    ( umask 077; printf '%s\n' "$secret" > "$sdir/$secret_key" )
    chmod 600 "$sdir/$secret_key" 2>/dev/null || true
    env_lines+="HS_SECRETS_DIR=$sdir"$'\n'
    export HS_JOB_ENV=$env_lines
    unit=$(hs_job "$slug" "hs recipe $name${ct:+ --name $ct}" -- bash -c 'd=$1; shift; "$@"; rc=$?; rm -rf "$d"; exit $rc' _ "$sdir" "${cmd[@]}") ||
      { rm -rf "$sdir"; refuse "the job could not be started"; }
  else
    export HS_JOB_ENV=$env_lines
    unit=$(hs_job "$slug" "hs recipe $name${ct:+ --name $ct}" -- "${cmd[@]}") || refuse "the job could not be started"
  fi
  printf 'status\tstarted\nunit\t%s\n' "$unit"
  exit 0
fi

desc=$(sed -n 's/^# recipe: //p' "$file" | head -n1 || true)
printf 'status\tok\nheading\trun the recipe %s%s\n' "$name" "${ct:+ as $ct}"
[ -z "$desc" ] || printf 'note\t%s\n' "$desc"
printf 'step\tcreate the container if it is not there, install the app and connect it to this server\n'
if [ ${#ak[@]} -gt 0 ]; then printf 'step\tuse your answers; every other preference takes the answer stored last time, or its default\n'
else printf 'step\tuse the answers stored last time, or the defaults, for every preference\n'; fi
[ -z "$secret_key" ] || printf 'note\t%s is kept secret: it goes only into the container, never into the log.\n' "$secret_label"
printf 'note\tSafe to run again: a second run repairs or updates the setup. It takes a few minutes to an hour.\n'
printf 'command\t%s\n' "hs recipe $name${ct:+ --name $ct}"
printf 'long\tyes\n'
exit 0
