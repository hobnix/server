#!/usr/bin/env bash
# help: users and groups of the domain (create, password, lock, group membership), in a full-screen interface
# help.de: Benutzer und Gruppen der Domäne (anlegen, Passwort, sperren, Gruppen), in einer Vollbild-Oberfläche
# args: [--plain]
set -euo pipefail

# The users live on the domain controller (the instance dc1); this script
# runs samba-tool there. Passwords are typed on the terminal, straight into
# samba-tool on the controller: they never pass through this script.
#
# Used by the web interface (Users):
#   --list                              users: name, full name, enabled|disabled, groups (comma separated)
#   --groups                            groups: name, members (comma separated)
#   --add <user> [--full "<name>"]      create a user; asks for the password
#   --password <user>                   set a new password; asks for it
#                                       (with --stdin the password is the first line of standard input: used by the interface
#                                       through user-change.sh; samba-tool reads it without a terminal, it is never an argument)
#   --enable <user> | --disable <user>  unlock / lock an account
#   --delete <user>                     asks to type the name first (--yes: the interface checked it)
#   --group-add <group> | --group-delete <group>
#   --member <group> <user> add|remove
#   --details user|group <name>         the editable fields, one line each: key<TAB>value, an empty value is written -
#                                       (user: full, mail, description; group: description)
#   --edit user <user> [--full <name>] [--mail <address>] [--description <text>]
#   --edit group <group> [--description <text>]
#                                       change the fields that are named; the value - clears a field, a field that is not named stays
#   --flush                             make this file server forget cached users and groups
# Add --dry-run to a change to see what would happen; --yes skips the typed name of --delete and --group-delete (jobs).

. "$(dirname "$0")/lib/ui.sh"
. "$(dirname "$0")/lib/dc.sh"
dc=$(dc_name)        # the instance that is the domain controller (dc1, dc2, HS_DC, dcName: lib/dc.sh)
db=/var/lib/samba/private/sam.ldb

usage() {
  say "usage: hs user list [--plain]"
  say "       (the options used by the interface are listed at the top of scripts/manage-users.sh)"
  exit 1
}

dry=false
plain=false
yes=false
stdin_pw=false
args=()
for a in "$@"; do
  case "$a" in
    --dry-run) dry=true ;;
    --plain)   plain=true ;;
    --yes)     yes=true ;;
    --stdin)   stdin_pw=true ;;
    *)         args+=("$a") ;;
  esac
done
set -- "${args[@]}"

if [ "${1:-}" = --flush ]; then
  # winbind keeps names, groups and memberships for a while; after this the
  # next login or `hs share <share> perm` asks the controller again
  if $dry; then echo "  net cache flush"; exit 0; fi
  net cache flush
  ok "Done: this file server asks the domain controller again from now on."
  exit 0
fi

state=$(incus list "^$dc\$" -c s -f csv 2>/dev/null || true)
[ -n "$state" ] || fail "$(t "No domain controller: this server has no instance '%s' (guide: Benutzer und Freigaben)." "$dc")"
[ "$state" = RUNNING ] || fail_fix "$(t "The domain controller '%s' is not running." "$dc")" "hs ct $dc start"

# on the controller, without a terminal (lists) or with one (password prompts)
on_dc()  { incus exec "$dc" -- "$@" </dev/null; }
on_dc_t() { incus exec "$dc" -t -- "$@"; }
# with the password on standard input (no terminal): samba-tool's getpass falls back to reading stdin
on_dc_in() { incus exec "$dc" -- "$@"; }
# read the password once and give it to samba-tool for both of its prompts ("New Password", "Retype Password")
with_password() {
  local pw
  IFS= read -r pw || pw=""
  [ -n "$pw" ] || fail "No password on standard input."
  printf '%s\n%s\n' "$pw" "$pw" | on_dc_in "$@"
}

# run a change, or only print it with --dry-run
run() {
  if $dry; then
    printf '  on %s:' "$dc"; printf ' %q' "$@"; echo
  else
    on_dc "$@"
  fi
}

# Everything about users and groups in two searches. LDIF wraps long lines
# (continuation lines start with a space) and encodes non-ASCII values in
# base64 ("attr:: ..."); both are undone here.
directory() {
  {
    on_dc ldbsearch -H "$db" '(&(objectCategory=person)(objectClass=user))' sAMAccountName displayName userAccountControl primaryGroupID 2>/dev/null
    echo "# groups"
    on_dc ldbsearch -H "$db" '(objectClass=group)' sAMAccountName member 2>/dev/null
  } | sed -e ':a' -e '$!N' -e 's/\n //' -e 'ta' -e 'P' -e 'D' | awk -v want="$1" '
    function dec(v,   cmd, out) { cmd = "printf %s \"" v "\" | base64 -d"; out = ""; cmd | getline out; close(cmd); return out }
    function val(line,   i) {
      i = index(line, ":")
      if (substr(line, i + 1, 1) == ":") return dec(substr(line, i + 3))
      return substr(line, i + 2)
    }
    function flush_record() {
      if (name == "") { dn = ""; return }
      if (!ingroups) {
        nu++; uname[nu] = name; ufull[nu] = full; uuac[nu] = uac; uprim[nu] = prim; bydn[tolower(dn)] = name
      } else {
        ng++; gname[ng] = name; gdn[ng] = dn; gmembers[ng] = members
      }
      dn = name = full = uac = prim = members = ""
    }
    /^# groups$/      { flush_record(); ingroups = 1; next }
    /^dn::? /         { flush_record(); dn = val($0); next }
    /^sAMAccountName/ { name = val($0); next }
    /^displayName/    { full = val($0); next }
    /^userAccountControl/ { uac = val($0); next }
    /^primaryGroupID/ { prim = val($0); next }
    /^member::? /     { members = members "\n" tolower(val($0)); next }
    END {
      flush_record()
      # accounts and groups nobody manages by hand
      skipuser = "^(krbtgt|guest|dns-.*)$"
      skipgroup = "rodc|read-only domain|cert publishers|ras and ias|dnsadmins|dnsupdateproxy|schema admins|enterprise|group policy|domain controllers|domain computers|domain guests|protected users"
      for (g = 1; g <= ng; g++) {
        if (tolower(gdn[g]) ~ /cn=builtin/ || tolower(gname[g]) ~ skipgroup) continue
        list = ""
        n = split(gmembers[g], m, "\n")
        for (i = 1; i <= n; i++) if (m[i] in bydn) {
          list = list (list == "" ? "" : ",") bydn[m[i]]
          ugroups[bydn[m[i]]] = ugroups[bydn[m[i]]] (ugroups[bydn[m[i]]] == "" ? "" : ",") gname[g]
        }
        # everybody is in Domain Users through the "primary group", which is not a member entry
        if (gname[g] == "Domain Users") for (u = 1; u <= nu; u++) if (uprim[u] == 513 && tolower(uname[u]) !~ skipuser) {
          list = list (list == "" ? "" : ",") uname[u]
          ugroups[uname[u]] = ugroups[uname[u]] (ugroups[uname[u]] == "" ? "" : ",") gname[g]
        }
        if (want == "groups") printf "%s\t%s\n", gname[g], list
      }
      if (want == "users") for (u = 1; u <= nu; u++) {
        if (tolower(uname[u]) ~ skipuser) continue
        # bit 2 of userAccountControl: the account is disabled
        printf "%s\t%s\t%s\t%s\n", uname[u], ufull[u], (int(uuac[u] / 2) % 2 ? "disabled" : "enabled"), ugroups[uname[u]]
      }
    }' | sort -f
}

# LDIF of one search with wrapped lines joined; "attr:: ..." values decoded
ldb_search() {
  on_dc ldbsearch -H "$db" "$@" 2>/dev/null | sed -e ':a' -e '$!N' -e 's/\n //' -e 'ta' -e 'P' -e 'D'
}
ldb_val() {   # the value of an LDIF line "attr: v" or "attr:: base64"
  local v=${1#*:}
  if [ "${v:0:1}" = : ]; then printf %s "${v:2}" | base64 -d; else printf %s "${v# }"; fi
}
ldb_dn() { local l; l=$(ldb_search "$1" dn | grep -m1 '^dn:') || true; [ -n "$l" ] || return 0; ldb_val "$l"; }
# <filter> <attribute>...: one line attribute<TAB>value for each attribute, an empty value stays empty
ldb_fields() {
  local filter=$1 a l; shift
  local out; out=$(ldb_search "$filter" "$@")
  for a in "$@"; do
    l=$(grep -m1 -i "^$a::\? " <<<"$out") || true
    printf '%s\t%s\n' "$a" "$([ -z "$l" ] || ldb_val "$l")"
  done
}

valid_user()  { [[ "$1" =~ ^[a-z][a-z0-9._-]{0,19}$ ]] || fail "$(t "Invalid login name '%s': lowercase letters, digits, . _ - (at most 20, starting with a letter)." "$1")"; }
valid_group() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9\ ._-]{0,62}$ ]] || fail "$(t "Invalid group name '%s': letters, digits, space, . _ -" "$1")"; }
has_user()    { directory users  | cut -f1 | grep -qixF -- "$1"; }
has_group()   { directory groups | cut -f1 | grep -qixF -- "$1"; }
# accounts and groups the domain itself needs
builtin_user()  { grep -qixE 'administrator|krbtgt|guest' <<<"$1"; }
builtin_group() { grep -qiE '^(domain |enterprise |schema |dns|cert |ras |group policy|allowed |denied |read-only |protected )' <<<"$1"; }

case "${1:-}" in
  "")
    { thead 'Login' 'Name' 'State' 'Groups'; directory users; } | table
    exit 0 ;;

  --list)   directory users ;;
  --groups) directory groups ;;

  --add)
    [ $# -ge 2 ] || usage
    user="$2"; full=""
    shift 2
    while [ $# -gt 0 ]; do
      case "$1" in
        --full) [ $# -ge 2 ] || usage; full="$2"; shift 2 ;;
        *) usage ;;
      esac
    done
    valid_user "$user"
    ! has_user "$user" || fail "$(t "A user called '%s' exists already." "$user")"
    cmd=(samba-tool user create "$user")
    if [ -n "$full" ]; then
      # "Anna Maria Beispiel" -> given name "Anna Maria", surname "Beispiel"
      if [[ "$full" == *" "* ]]; then cmd+=(--given-name="${full% *}" --surname="${full##* }")
      else cmd+=(--given-name="$full"); fi
    fi
    if $dry; then
      echo "Create the user '$user'${full:+ ($full)}:"
      printf '  on %s:' "$dc"; printf ' %q' "${cmd[@]}"; echo
      echo "  The password is asked for next, on the terminal (typed twice, not shown)."
      echo "  The user is in the group Domain Users and has no access to any share yet (tab Shares)."
      exit 0
    fi
    if $stdin_pw; then with_password "${cmd[@]}"; else
      note "$(t "Password for the new user '%s' (typed twice, not shown):" "$user")"
      on_dc_t "${cmd[@]}"
    fi
    ok "$(t "User '%s' created." "$user")"
    next_step "hs share <share> perm" ;;

  --password)
    [ $# -ge 2 ] || usage
    has_user "$2" || fail "$(t "No user called '%s'." "$2")"
    if $dry; then echo "  on $dc: samba-tool user setpassword $2   (asks for the new password)"; exit 0; fi
    if $stdin_pw; then with_password samba-tool user setpassword "$2"; else
      note "$(t "New password for '%s' (typed twice, not shown):" "$2")"
      on_dc_t samba-tool user setpassword "$2"
    fi
    $dry || ok "$(t "The password of '%s' is changed." "$2")" ;;

  --enable|--disable)
    [ $# -ge 2 ] || usage
    has_user "$2" || fail "$(t "No user called '%s'." "$2")"
    if [ "$1" = --disable ]; then
      ! grep -qix administrator <<<"$2" || fail "Not possible: locking Administrator would lock you out of the domain."
      $dry && echo "Lock '$2': the account stays, but it can't log in or open shares any more."
      run samba-tool user disable "$2"
    else
      $dry && echo "Unlock '$2': it can log in again."
      run samba-tool user enable "$2"
    fi
    $dry || ok "Done. Connections that are already open stay until they are closed." ;;

  --delete)
    [ $# -ge 2 ] || usage
    has_user "$2" || fail "$(t "No user called '%s'." "$2")"
    ! builtin_user "$2" || fail "$(t "Not possible: '%s' is an account the domain needs." "$2")"
    if $dry; then
      echo "Delete the user '$2' from the domain. Files it wrote to shares stay."
      echo "Its share permissions become dead entries; a new user with the same name does not get them back."
      echo "  on $dc: samba-tool user delete $2"; exit 0
    fi
    warn "$(t "Delete the user '%s' from the domain. Files it wrote to shares stay." "$2")"
    note "Its share permissions become dead entries; a new user with the same name does not get them back."
    if ! $yes; then
      danger "$(t "'%s' is deleted from the domain for good." "$2")"
      confirm_name "$2" "the user" || fail "cancelled"
    fi
    on_dc samba-tool user delete "$2"
    ok "$(t "User '%s' deleted." "$2")" ;;

  --group-add)
    [ $# -ge 2 ] || usage
    valid_group "$2"
    ! has_group "$2" || fail "$(t "A group called '%s' exists already." "$2")"
    $dry && echo "Create the group '$2'. Add members with space in the group list, give it access in the tab Shares."
    run samba-tool group add "$2"
    $dry || { ok "$(t "Group '%s' created." "$2")"; next_step "hs share <share> perm"; } ;;

  --group-delete)
    [ $# -ge 2 ] || usage
    has_group "$2" || fail "$(t "No group called '%s'." "$2")"
    ! builtin_group "$2" || fail "$(t "Not possible: '%s' is a group the domain needs." "$2")"
    if $dry; then
      echo "Delete the group '$2'. Its members stay; they lose the access the group gave them."
      echo "  on $dc: samba-tool group delete $2"; exit 0
    fi
    warn "$(t "Delete the group '%s'. Its members stay; they lose the access the group gave them." "$2")"
    if ! $yes; then
      danger "$(t "The group '%s' is deleted from the domain for good." "$2")"
      confirm_name "$2" "the group" || fail "cancelled"
    fi
    on_dc samba-tool group delete "$2"
    ok "$(t "Group '%s' deleted." "$2")" ;;

  --details)
    [ $# -ge 3 ] || usage
    case "$2" in
      user)  has_user "$3" || fail "$(t "No user called '%s'." "$3")"
             ldb_fields "(&(objectCategory=person)(objectClass=user)(sAMAccountName=$3))" displayName mail description ;;
      group) has_group "$3" || fail "$(t "No group called '%s'." "$3")"
             ldb_fields "(&(objectClass=group)(sAMAccountName=$3))" description ;;
      *) usage ;;
    esac | awk -F'\t' '{ k = $1; sub(/^displayName$/, "full", k); printf "%s\t%s\n", k, ($2 == "" ? "-" : $2) }' ;;

  --edit)
    [ $# -ge 3 ] || usage
    kind="$2"; target="$3"; shift 3
    full=""; mail=""; descr=""; set_full=false; set_mail=false; set_descr=false
    while [ $# -gt 0 ]; do
      [ $# -ge 2 ] || usage
      case "$1" in
        --full)        [ "$kind" = user ] || usage; set_full=true; full="$2" ;;
        --mail)        [ "$kind" = user ] || usage; set_mail=true; mail="$2" ;;
        --description) set_descr=true; descr="$2" ;;
        *) usage ;;
      esac
      shift 2
    done
    [ "$full" != - ] || full=""; [ "$mail" != - ] || mail=""; [ "$descr" != - ] || descr=""
    $set_full || $set_mail || $set_descr || fail "Nothing to change."
    if [ "$kind" = user ]; then
      has_user "$target" || fail "$(t "No user called '%s'." "$target")"
      filter="(&(objectCategory=person)(objectClass=user)(sAMAccountName=$target))"
    else
      [ "$kind" = group ] || usage
      has_group "$target" || fail "$(t "No group called '%s'." "$target")"
      ! builtin_group "$target" || fail "$(t "Not possible: '%s' is a group the domain needs." "$target")"
      filter="(&(objectClass=group)(sAMAccountName=$target))"
    fi
    re_full="^([[:alnum:]_][[:alnum:]_ .'-]{0,63})?\$"
    re_mail="^([A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,190})?\$"
    [[ "$full" =~ $re_full ]] || fail "Invalid full name: letters, digits, spaces, dot, dash and apostrophe only."
    [[ "$mail" =~ $re_mail ]] || fail "Invalid email address."
    [[ "$descr" =~ ^[^[:cntrl:]]{0,255}$ ]] || fail "Invalid description: one line, up to 255 characters."
    # the change as LDIF: every value is base64, so no text can end a line or start a new attribute
    ldif=""
    ldif_attr() { # <attribute> <value>: an empty value removes the attribute
      ldif+="replace: $1"$'\n'
      [ -z "$2" ] || ldif+="$1:: $(printf %s "$2" | base64 -w0)"$'\n'
      ldif+="-"$'\n'
    }
    if $set_full; then
      given=""; sur=""
      if [[ "$full" == *" "* ]]; then given=${full% *}; sur=${full##* }; else given=$full; fi
      ldif_attr displayName "$full"; ldif_attr givenName "$given"; ldif_attr sn "$sur"
    fi
    ! $set_mail  || ldif_attr mail "$mail"
    ! $set_descr || ldif_attr description "$descr"
    if $dry; then
      echo "Change the $kind '$target' ($(($(grep -c '^replace:' <<<"$ldif"))) attributes):"
      echo "  on $dc: ldbmodify -H $db   (the change as LDIF on standard input)"
      exit 0
    fi
    dn=$(ldb_dn "$filter")
    [ -n "$dn" ] || fail "$(t "No %s called '%s'." "$kind" "$target")"
    printf 'dn:: %s\nchangetype: modify\n%s' "$(printf %s "$dn" | base64 -w0)" "$ldif" | on_dc_in ldbmodify -H "$db" >/dev/null
    ok "$(t "The details of '%s' are changed." "$target")" ;;

  --member)
    [ $# -ge 4 ] || usage
    group="$2"; user="$3"
    has_group "$group" || fail "$(t "No group called '%s'." "$group")"
    has_user "$user" || fail "$(t "No user called '%s'." "$user")"
    ! grep -qix 'domain users' <<<"$group" || fail "Every user is in Domain Users; that can't be changed here."
    case "$4" in
      add)    run samba-tool group addmembers "$group" "$user" >/dev/null
              $dry || ok "$(t "'%s' is now in '%s'." "$user" "$group")" ;;
      remove)
        if grep -qix administrator <<<"$user" && grep -qix 'domain admins' <<<"$group"; then
          fail "Not possible: Administrator must stay in Domain Admins."
        fi
        run samba-tool group removemembers "$group" "$user" >/dev/null
        $dry || ok "$(t "'%s' is no longer in '%s'." "$user" "$group")" ;;
      *) usage ;;
    esac ;;

  *) usage ;;
esac
