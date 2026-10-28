#!/usr/bin/env bash
# help: who may use a share: pick a user or group and a level (none, read, write, full)
# help.de: wer eine Freigabe nutzen darf: Benutzer oder Gruppe und Stufe wählen (none, read, write, full)
# args: <share> [<name>=<level> ...] [--show] [--dry-run]
# Without <name>=<level> it asks (on a terminal). The work is done by manage-shares.sh (--acl, --principals,
# --set); HS_MANAGE_SHARES points tests at a stand-in.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
ms=${HS_MANAGE_SHARES:-$here/manage-shares.sh}

usage() {
  say "usage: hs share <share> perm [<name>=<level> ...] [--show] [--dry-run]"
  say "  level: none (removes the entry) | read | write | full"
  say "  name:  user or group as listed by: hs share <share> perm --show   (e.g. alice or 'Domain Admins')"
  exit 1
}

share=""; pairs=(); show=false; dry=false
for a in "$@"; do
  case "$a" in
    --show) show=true ;;
    --dry-run) dry=true ;;
    -h|--help) usage ;;
    *=*) pairs+=("$a") ;;
    -*) usage ;;
    *) [ -z "$share" ] || usage; share=$a ;;
  esac
done
[ -n "$share" ] || usage

principals=$(bash "$ms" --principals)
sid_of() {   # sid_of <name>: the SID of a user or group (domain prefix ignored)
  awk -F'\t' -v n="$1" '{ x = $2; sub(/^.*\\/, "", x); if (tolower(x) == tolower(n) || tolower($2) == tolower(n)) { print $1; exit } }' <<<"$principals"
}
show_acl() {
  local rows
  rows=$(bash "$ms" "$share" --acl | awk -F'\t' '{ printf "%s\t%s\t%s\n", $4, $3, $2 }')
  if [ -n "$rows" ]; then { thead 'Level' 'Type' 'Name'; printf '%s\n' "$rows"; } | table; else note "Nobody has access to this share."; fi
}

if $show || { [ ${#pairs[@]} -eq 0 ] && ! [ -t 0 ]; }; then show_acl; exit 0; fi

apply() {   # apply <sid=level>...
  if $dry; then bash "$ms" "$share" --set "$@" --dry-run; else bash "$ms" "$share" --set "$@"; fi
}

if [ ${#pairs[@]} -gt 0 ]; then
  sets=()
  for kv in "${pairs[@]}"; do
    name=${kv%%=*}; level=${kv#*=}
    case "$level" in none|read|write|full) ;; *) fail "$(t "Level '%s' is not none, read, write or full." "$level")" ;; esac
    sid=$(sid_of "$name")
    [ -n "$sid" ] || fail "$(t "No user or group called '%s'. See: hs share %s perm --show" "$name" "$share")"
    sets+=("$sid=$level")
  done
  apply "${sets[@]}"
  ok "$(t 'Permissions of %s changed.' "$share")"
  exit 0
fi

# guided: show, pick, set, repeat
while true; do
  step "$(t 'Who may use %s' "$share")"
  show_acl
  mapfile -t opts < <(awk -F'\t' '{ printf "%s (%s)\n", $2, $3 }' <<<"$principals")
  who=$(choose "Pick a user or group (esc to finish)" "${opts[@]}" 2>/dev/null) || break
  [ -n "$who" ] || break
  name=${who% (*}
  sid=$(awk -F'\t' -v n="$name" '$2 == n { print $1; exit }' <<<"$principals")
  level=$(choose "$(t 'Level for %s' "$name")" none read write full) || break
  apply "$sid=$level" && ok "$(t '%s: %s' "$name" "$level")"
  confirm "Change another entry?" || break
done
note "$(t 'Same again later with: hs share %s perm <name>=<level>' "$share")"
