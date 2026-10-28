#!/usr/bin/env bash
# help: guided dialogues for users and groups: add a user, lock/unlock, group memberships, add a group
# help.de: geführte Dialoge für Benutzer und Gruppen: Benutzer anlegen, sperren/entsperren, Gruppen, Gruppe anlegen
# args: add | lock <user> | groups <user> | group-add
# Runs bare and asks for what is missing; every answer can also be an option (tests, scripts). Passwords are
# never asked here: manage-users.sh asks for them on the terminal, straight into samba-tool.
# HS_MANAGE_USERS points tests at a stand-in.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
mu=${HS_MANAGE_USERS:-$here/manage-users.sh}

usage() {
  say "usage: hs user add [--name <login>] [--full \"<name>\"] [--groups a,b] [--yes]"
  say "       hs user <user> lock [--yes]               (locks an unlocked account, unlocks a locked one)"
  say "       hs user <user> groups [--set a,b] [--yes] (the groups the user should be in)"
  say "       hs group add [<name>]"
  exit 1
}
interactive() { [ -t 0 ] && [ -t 1 ] && [ -z "${HS_CALLER:-}" ] || [ -n "${HS_GUIDED_TTY:-}" ]; }
need() { interactive || fail "$(t 'Missing: %s (give it as an option)' "$1")"; }
ok_confirm() { [ "$1" = true ] || { interactive || fail "Nothing is changed without --yes when there is no terminal."; confirm "$2" || fail "cancelled"; }; }

# multi-select: the options, with the ticked ones first on the command line
pick_many() {   # pick_many <header> <ticked,comma> <option>... -> the chosen, one per line
  local header=$1 ticked=$2; shift 2
  if command -v gum >/dev/null 2>&1 && [ "${ui:-plain}" = gum ]; then
    gum choose --no-limit --header "$(_tr "$header")" ${ticked:+--selected "$ticked"} "$@"
  else
    local i=0 o mark answer
    echo "$(_tr "$header")" >&2
    for o in "$@"; do
      i=$((i + 1)); mark=" "; case ",$ticked," in *,"$o",*) mark="x" ;; esac
      printf '  %d) [%s] %s\n' "$i" "$mark" "$o" >&2
    done
    read -r -p "$(t 'Numbers of all that should apply, separated by spaces (empty = keep the [x] ones):') " answer
    if [ -z "$answer" ]; then
      for o in "$@"; do case ",$ticked," in *,"$o",*) echo "$o" ;; esac; done
    else
      for n in $answer; do [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $# ] && echo "${!n}"; done
    fi
  fi
}

verb=${1:-}; [ $# -eq 0 ] || shift
case "$verb" in
add)
  name=""; full=""; groups=""; yes=false; given_groups=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name=$2; shift 2 ;; --full) full=$2; shift 2 ;; --groups) groups=$2; given_groups=true; shift 2 ;; --yes) yes=true; shift ;; -*) usage ;; *) name=$1; shift ;;
    esac
  done
  if [ -z "$name" ]; then need "--name"; name=$(ask "Login name:" ""); fi
  [[ "$name" =~ ^[a-z][a-z0-9._-]*$ ]] || fail "$(t "'%s' is not a good login name: lowercase letters, digits, dots, dashes." "$name")"
  if bash "$mu" --list | cut -f1 | grep -qx "$name"; then fail "$(t "'%s' exists already." "$name")"; fi
  if [ -z "$full" ] && interactive; then full=$(ask "Full name (empty = none):" ""); fi
  if ! $given_groups && interactive; then
    mapfile -t all < <(bash "$mu" --groups | cut -f1)
    if [ ${#all[@]} -gt 0 ]; then groups=$(pick_many "Groups for the new user" "" "${all[@]}" | paste -sd, - || true); fi
  fi
  note "$(t 'Create the user %s%s%s' "$name" "${full:+ ($full)}" "${groups:+, groups: $groups}")"
  ok_confirm "$yes" "Create it? (you are asked for the password next)"
  args=(--add "$name"); [ -z "$full" ] || args+=(--full "$full")
  bash "$mu" "${args[@]}"
  if [ -n "$groups" ]; then
    IFS=, read -ra gl <<<"$groups"
    for g in "${gl[@]}"; do bash "$mu" --member "$g" "$name" add; done
  fi ;;

lock)
  [ $# -ge 1 ] || usage
  user=$1; shift; yes=false
  [ "${1:-}" != --yes ] || yes=true
  state=$(bash "$mu" --list | awk -F'\t' -v u="$user" '$1 == u { print $3; exit }')
  [ -n "$state" ] || fail "$(t "No user called '%s'." "$user")"
  if [ "$state" = enabled ]; then
    note "$(t '%s is unlocked. It will be locked: no login, files stay.' "$user")"; ok_confirm "$yes" "Lock the account?"; bash "$mu" --disable "$user"
  else
    note "$(t '%s is locked. It will be unlocked.' "$user")"; ok_confirm "$yes" "Unlock the account?"; bash "$mu" --enable "$user"
  fi ;;

groups)
  [ $# -ge 1 ] || usage
  user=$1; shift; want=""; yes=false; given=false
  while [ $# -gt 0 ]; do case "$1" in --set) want=$2; given=true; shift 2 ;; --yes) yes=true; shift ;; *) usage ;; esac; done
  bash "$mu" --list | cut -f1 | grep -qx "$user" || fail "$(t "No user called '%s'." "$user")"
  have=$(bash "$mu" --groups | awk -F'\t' -v u="$user" '{ n = split($2, m, ","); for (i = 1; i <= n; i++) if (m[i] == u) print $1 }' | paste -sd, -)
  mapfile -t all < <(bash "$mu" --groups | cut -f1)
  if ! $given; then
    need "--set a,b"
    want=$(pick_many "$(t 'Groups of %s' "$user")" "$have" "${all[@]}" | paste -sd, - || true)
  fi
  add=(); del=()
  for g in "${all[@]}"; do
    inh=false; inw=false
    case ",$have," in *,"$g",*) inh=true ;; esac
    case ",$want," in *,"$g",*) inw=true ;; esac
    if $inw && ! $inh; then add+=("$g"); fi
    if $inh && ! $inw; then del+=("$g"); fi
  done
  if [ ${#add[@]} -eq 0 ] && [ ${#del[@]} -eq 0 ]; then note "Nothing to change."; exit 0; fi
  [ ${#add[@]} -eq 0 ] || note "$(t 'Add to: %s' "$(IFS=,; echo "${add[*]}")")"
  [ ${#del[@]} -eq 0 ] || note "$(t 'Remove from: %s' "$(IFS=,; echo "${del[*]}")")"
  ok_confirm "$yes" "Apply?"
  for g in ${add[@]+"${add[@]}"}; do bash "$mu" --member "$g" "$user" add; done
  for g in ${del[@]+"${del[@]}"}; do bash "$mu" --member "$g" "$user" remove; done ;;

group-add)
  name=${1:-}
  if [ -z "$name" ]; then need "a group name"; name=$(ask "Group name:" ""); fi
  re='^[A-Za-z][A-Za-z0-9._ -]*$'
  [[ "$name" =~ $re ]] || fail "$(t "'%s' is not a good group name." "$name")"
  bash "$mu" --group-add "$name" ;;

*) usage ;;
esac
