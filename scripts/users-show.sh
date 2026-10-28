#!/usr/bin/env bash
# help: users and groups of the domain as a readable list
# help.de: Benutzer und Gruppen der Domäne als lesbare Liste
# args: [users | groups] [<name>]
# The reading is done by manage-users.sh (--list, --groups); HS_MANAGE_USERS points tests at a stand-in.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
mu=${HS_MANAGE_USERS:-$here/manage-users.sh}

what=${1:-users}
filter=${2:-}
case "$what" in
  users)
    rows=$(bash "$mu" --list | awk -F'\t' -v f="$filter" 'f == "" || $1 == f { printf "%s\t%s\t%s\t%s\n", $1, $2, $3, $4 }')
    [ -n "$rows" ] || { [ -z "$filter" ] && note "No users found." || fail "$(t "No user called '%s'." "$filter")"; exit 0; }
    { thead 'USER' 'NAME' 'STATE' 'GROUPS'; printf '%s\n' "$rows"; } | table ;;
  groups)
    rows=$(bash "$mu" --groups | awk -F'\t' -v f="$filter" 'f == "" || $1 == f { printf "%s\t%s\n", $1, $2 }')
    [ -n "$rows" ] || { [ -z "$filter" ] && note "No groups found." || fail "$(t "No group called '%s'." "$filter")"; exit 0; }
    { thead 'GROUP' 'MEMBERS'; printf '%s\n' "$rows"; } | table ;;
  *) say "usage: hs user list | hs user <user> show | hs group list | hs group <group> show"; exit 1 ;;
esac
