#!/usr/bin/env bash
# help: which shares a user or a group can reach, and through which entry
# help.de: auf welche Freigaben ein Benutzer oder eine Gruppe zugreifen kann, und über welchen Eintrag
# args: user <name> | group <name>
# System command (hs sys users access <user> | hs sys users group-access <group>), read only, tab separated (the Users tab of the
# interface). One line per share the name reaches, in the order of manage-shares.sh --list:
#   share  level  via
#   level  read | write | full | denied (a "denied" entry wins over every grant)
#   via    the ACL entries that apply, comma separated: the user itself, one of his groups, or Everyone
# A user reaches a share through an entry for the user, for any group he is in (manage-users.sh --list) or for Everyone;
# a group through the entries made for the group itself (members of a group inside it are not followed).
# It reads the ACL of every share (`manage-shares.sh <share> --acl`, root, one sharesec each): read it when a user is opened,
# not for a whole list. Test knobs: HS_MANAGE_USERS, HS_MANAGE_SHARES.
set -euo pipefail
here=$(dirname "$0")
what=${1:-}; name=${2:-}
case "$what" in user|group) ;; *) echo "usage: user-access.sh user|group <name>" >&2; exit 1 ;; esac
[ -n "$name" ] || { echo "usage: user-access.sh user|group <name>" >&2; exit 1; }
mu=${HS_MANAGE_USERS:-$here/manage-users.sh}
ms=${HS_MANAGE_SHARES:-$here/manage-shares.sh}

# the names an ACL entry may carry for this user or group (lower case, without the domain)
names="$name"
if [ "$what" = user ]; then
  row=$(bash "$mu" --list 2>/dev/null | awk -F'\t' -v u="$name" '$1 == u { print; exit }' || true)
  [ -n "$row" ] || { echo "No user called '$name'." >&2; exit 1; }
  groups=$(awk -F'\t' '{ print $4 }' <<<"$row" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$' || true)
  names=$(printf '%s\n%s\nEveryone\n' "$name" "$groups" | grep -v '^$' | paste -sd, -)
fi

while IFS=$'\t' read -r share _; do
  [ -n "$share" ] || continue
  bash "$ms" "$share" --acl 2>/dev/null |
    awk -F'\t' -v share="$share" -v names="$names" '
      BEGIN { n = split(tolower(names), a, ","); for (i = 1; i <= n; i++) if (a[i] != "") want[a[i]] = 1
              rank["read"] = 1; rank["write"] = 2; rank["full"] = 3 }
      { who = $2; sub(/^.*\\/, "", who); w = tolower(who)
        if (!(w in want)) next
        level = $4
        via = via (via == "" ? "" : ",") who
        if (level == "denied") { denied = 1; next }
        if (rank[level] > best) { best = rank[level]; top = level } }
      END { if (denied) print share "\tdenied\t" via
            else if (top != "") print share "\t" top "\t" via }'
done < <(bash "$ms" --list 2>/dev/null | awk -F'\t' '$2 != "other"')
