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
