# shellcheck shell=bash
# The local back end of scripts/manage-users.sh: a server without a domain (no adDomain). A share user is a Unix account with a Samba
# password (tdbsam); a group is a Unix group. Same options and the same machine-readable lines as the AD path (see the header of
# manage-users.sh); passwords travel only on standard input of smbpasswd, never as an argument or in the environment.
#
#   users_local_main <manage-users.sh arguments without --dry-run/--plain/--yes/--stdin>
#       reads the flags the caller parsed: dry, yes, stdin_pw (true|false; unset = false)
#
# Accounts: uid 2000-2999, primary group users, no home, no shell, no Unix password. Groups: gid 2000-2999.
# Test knobs: HS_NOLOGIN (the shell path), HS_ADMIN_USER_FILE (lib/admin.sh).
. "${BASH_SOURCE[0]%/*}/admin.sh"

_ul_nologin() { echo "${HS_NOLOGIN:-/run/current-system/sw/bin/nologin}"; }

# the passdb accounts, one line name<TAB>enabled|disabled (pdbedit -L -v blocks; the flags hold D when the account is locked)
_ul_passdb() {
  pdbedit -L -v 2>/dev/null | awk '
    function emit() { if (name != "") printf "%s\t%s\n", name, (fl ~ /D/ ? "disabled" : "enabled"); name = fl = "" }
    /^Unix username:/ { sub(/^Unix username:[ \t]*/, ""); name = $0; next }
    /^Account Flags:/ { fl = $0; sub(/^[^[]*/, "", fl); next }
    /^-+$/ { emit() }
    END { emit() }'
}
# the groups this back end manages (gid 2000-2999): name<TAB>members (comma separated, may be empty)
_ul_groups() { { getent group 2>/dev/null || true; } | awk -F: '$3 >= 2000 && $3 <= 2999 { printf "%s\t%s\n", $1, $4 }' | sort -f; }
_ul_gecos() { { getent passwd "$1" 2>/dev/null || true; } | awk -F: '{ sub(/,.*/, "", $5); print $5 }'; }
# name<TAB>full name<TAB>state<TAB>groups, one line for each account of the passdb
_ul_users() {
  local grp u st full g
  grp=$(_ul_groups)
  _ul_passdb | while IFS=$'\t' read -r u st; do
    full=$(_ul_gecos "$u")
    g=$(awk -F'\t' -v u="$u" '{ n = split($2, m, ","); for (i = 1; i <= n; i++) if (m[i] == u) l = l (l == "" ? "" : ",") $1 } END { print l }' <<<"$grp")
    printf '%s\t%s\t%s\t%s\n' "$u" "$full" "$st" "$g"
  done | sort -f
}

_ul_valid_user()  { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || fail "$(t "Invalid login name '%s': lowercase letters, digits, _ and - (at most 31, starting with a letter or _)." "$1")"; }
_ul_valid_group() { [[ "$1" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || fail "$(t "Invalid group name '%s': lowercase letters, digits, _ and - (no spaces; at most 32, starting with a letter)." "$1")"; }
_ul_usage() {
  say "usage: hs user list [--plain]"
  say "       (the options used by the interface are listed at the top of scripts/manage-users.sh)"
  exit 1
}
_ul_has_user()  { cut -f1 <<<"$ulist" | grep -qxF -- "$1"; }
_ul_has_group() { cut -f1 <<<"$glist" | grep -qxF -- "$1"; }
_ul_load() { ulist=$(_ul_users); glist=$(_ul_groups); }
# the command that would run (with --dry-run), or run it
_ul_run() {
  if $dry; then local s; printf -v s ' %q' "$@"; say " $s"; else "$@"; fi
}

users_local_main() {
  local dry=${dry:-false} yes=${yes:-false} stdin_pw=${stdin_pw:-false}
  local admin ulist="" glist="" rc s
  admin=$(admin_user)

  case "${1:-}" in
    --flush)
      note "Nothing to flush: this server has no domain, its users are local."
      return 0 ;;
    "")
      _ul_load
      { thead 'Login' 'Name' 'State' 'Groups'; printf '%s\n' "$ulist"; } | table
      return 0 ;;
    --list)   _ul_users ;;
    --groups) _ul_groups ;;

    --add)
      [ $# -ge 2 ] || _ul_usage
      local user="$2" full="" pw=""
      shift 2
      while [ $# -gt 0 ]; do
        case "$1" in
          --full) [ $# -ge 2 ] || _ul_usage; full="$2"; shift 2 ;;
          *) _ul_usage ;;
        esac
      done
      _ul_valid_user "$user"
      local re_full_add="^([[:alnum:]_][[:alnum:]_ .'-]{0,63})?\$"
      [[ "$full" =~ $re_full_add ]] || fail "Invalid full name: letters, digits, spaces, dot, dash and apostrophe only."
      ! getent passwd "$user" >/dev/null 2>&1 || fail "$(t "A user called '%s' exists already." "$user")"
      local cmd=(useradd -K UID_MIN=2000 -K UID_MAX=2999 -g users -M -d /var/empty -s "$(_ul_nologin)" -c "$full" -- "$user")
      if $dry; then
        say "Create the user '$user'${full:+ ($full)}:"
        printf -v s ' %q' "${cmd[@]}"; say " $s"
        if $stdin_pw; then say "  smbpasswd -s -a $user   (the password on standard input)"
        else say "  The password is asked for next, on the terminal (typed twice, not shown)."; fi
        say "  The account can open shares and nothing else (no shell, no home). It has no access to any share yet (tab Shares)."
        return 0
      fi
      if $stdin_pw; then
        IFS= read -r pw || pw=""
        [ -n "$pw" ] || fail "No password on standard input."
      fi
      "${cmd[@]}"
      rc=0
      if $stdin_pw; then
        printf '%s\n%s\n' "$pw" "$pw" | smbpasswd -s -a "$user" >/dev/null || rc=$?
        pw=""
      else
        note "$(t "Password for the new user '%s' (typed twice, not shown):" "$user")"
        smbpasswd -a "$user" || rc=$?
      fi
      if [ "$rc" -ne 0 ]; then
        userdel -- "$user" >/dev/null 2>&1 || true
        fail "$(t "The Samba password of '%s' was not set; the account was not created." "$user")"
      fi
      ok "$(t "User '%s' created." "$user")"
      next_step "hs share <share> perm" ;;

    --password)
      [ $# -ge 2 ] || _ul_usage
      _ul_load
      # the admin gets its first Samba password here (it is no passdb account before)
      if ! _ul_has_user "$2" && ! { [ "$2" = "$admin" ] && getent passwd "$2" >/dev/null 2>&1; }; then
        fail "$(t "No user called '%s'." "$2")"
      fi
      if $dry; then say "  smbpasswd -a $2   (asks for the new password)"; return 0; fi
      if $stdin_pw; then
        local pw=""
        IFS= read -r pw || pw=""
        [ -n "$pw" ] || fail "No password on standard input."
        rc=0
        printf '%s\n%s\n' "$pw" "$pw" | smbpasswd -s -a "$2" >/dev/null || rc=$?
        pw=""
        [ "$rc" -eq 0 ] || fail "$(t "The password of '%s' was not changed." "$2")"
      else
        note "$(t "New password for '%s' (typed twice, not shown):" "$2")"
        smbpasswd -a "$2"
      fi
      ok "$(t "The password of '%s' is changed." "$2")" ;;

    --enable|--disable)
      [ $# -ge 2 ] || _ul_usage
      _ul_load
      _ul_has_user "$2" || fail "$(t "No user called '%s'." "$2")"
      if [ "$1" = --disable ]; then
        [ "$2" != "$admin" ] || fail "$(t "Not possible: '%s' is the admin account; locking it would lock you out." "$2")"
        ! $dry || say "Lock '$2': the account stays, but it can't open shares any more."
        _ul_run smbpasswd -d "$2"
      else
        ! $dry || say "Unlock '$2': it can open shares again."
        _ul_run smbpasswd -e "$2"
      fi
      $dry || ok "Done. Connections that are already open stay until they are closed." ;;

    --delete)
      [ $# -ge 2 ] || _ul_usage
      _ul_load
      _ul_has_user "$2" || fail "$(t "No user called '%s'." "$2")"
      [ "$2" != "$admin" ] || fail "$(t "Not possible: '%s' is the admin account." "$2")"
      local uid; uid=$({ getent passwd "$2" 2>/dev/null || true; } | cut -d: -f3)
      { [[ "$uid" =~ ^[0-9]+$ ]] && [ "$uid" -ge 2000 ] && [ "$uid" -le 2999 ]; } || fail "$(t "Not possible: '%s' is not a share account made here." "$2")"
      if $dry; then
        say "Delete the user '$2' and its Samba password. Files it wrote to shares stay."
        say "Its share permissions become dead entries; a new user with the same name does not get them back."
        say "  smbpasswd -x $2"
        say "  userdel -- $2"
        return 0
      fi
      warn "$(t "Delete the user '%s' and its Samba password. Files it wrote to shares stay." "$2")"
      note "Its share permissions become dead entries; a new user with the same name does not get them back."
      if ! $yes; then
        danger "$(t "'%s' is deleted for good." "$2")"
        confirm_name "$2" "the user" || fail "cancelled"
      fi
      smbpasswd -x "$2" >/dev/null
      userdel -- "$2"
      ok "$(t "User '%s' deleted." "$2")" ;;

    --group-add)
      [ $# -ge 2 ] || _ul_usage
      _ul_valid_group "$2"
      ! getent group "$2" >/dev/null 2>&1 || fail "$(t "A group called '%s' exists already." "$2")"
      ! $dry || say "Create the group '$2'. Add members with space in the group list, give it access in the tab Shares."
      _ul_run groupadd -K GID_MIN=2000 -K GID_MAX=2999 -- "$2"
      $dry || { ok "$(t "Group '%s' created." "$2")"; next_step "hs share <share> perm"; } ;;

    --group-delete)
      [ $# -ge 2 ] || _ul_usage
      _ul_load
      _ul_has_group "$2" || fail "$(t "No group called '%s'." "$2")"
      if $dry; then
        say "Delete the group '$2'. Its members stay; they lose the access the group gave them."
        say "  groupdel -- $2"
        return 0
      fi
      warn "$(t "Delete the group '%s'. Its members stay; they lose the access the group gave them." "$2")"
      if ! $yes; then
        danger "$(t "The group '%s' is deleted for good." "$2")"
        confirm_name "$2" "the group" || fail "cancelled"
      fi
      groupdel -- "$2"
      ok "$(t "Group '%s' deleted." "$2")" ;;

    --details)
      [ $# -ge 3 ] || _ul_usage
      _ul_load
      case "$2" in
        user)  _ul_has_user "$3" || fail "$(t "No user called '%s'." "$3")"
               local g; g=$(_ul_gecos "$3")
               printf 'full\t%s\nmail\t-\ndescription\t-\n' "${g:--}" ;;
        group) _ul_has_group "$3" || fail "$(t "No group called '%s'." "$3")"
               printf 'description\t-\n' ;;
        *) _ul_usage ;;
      esac ;;

    --edit)
      [ $# -ge 3 ] || _ul_usage
      local kind="$2" target="$3"; shift 3
      local full="" set_full=false set_other=false
      while [ $# -gt 0 ]; do
        [ $# -ge 2 ] || _ul_usage
        case "$1" in
          --full)        [ "$kind" = user ] || _ul_usage; set_full=true; full="$2" ;;
          --mail)        [ "$kind" = user ] || _ul_usage; set_other=true ;;
          --description) set_other=true ;;
          *) _ul_usage ;;
        esac
        shift 2
      done
      [ "$full" != - ] || full=""
      $set_full || $set_other || fail "Nothing to change."
      [ "$kind" = user ] || [ "$kind" = group ] || _ul_usage
      ! $set_other || fail "Only with a domain."
      _ul_load
      if [ "$kind" = user ]; then
        _ul_has_user "$target" || fail "$(t "No user called '%s'." "$target")"
      else
        _ul_has_group "$target" || fail "$(t "No group called '%s'." "$target")"
      fi
      local re_full="^([[:alnum:]_][[:alnum:]_ .'-]{0,63})?\$"
      [[ "$full" =~ $re_full ]] || fail "Invalid full name: letters, digits, spaces, dot, dash and apostrophe only."
      if $dry; then
        say "Change the $kind '$target' (1 attributes):"
        printf -v s ' %q' usermod -c "$full" -- "$target"; say " $s"
        return 0
      fi
      usermod -c "$full" -- "$target"
      ok "$(t "The details of '%s' are changed." "$target")" ;;

    --member)
      [ $# -ge 4 ] || _ul_usage
      local group="$2" user="$3"
      _ul_load
      _ul_has_group "$group" || fail "$(t "No group called '%s'." "$group")"
      _ul_has_user "$user" || fail "$(t "No user called '%s'." "$user")"
      case "$4" in
        add)
          if $dry; then _ul_run gpasswd -a "$user" -- "$group"; else gpasswd -a "$user" -- "$group" >/dev/null; fi
          $dry || ok "$(t "'%s' is now in '%s'." "$user" "$group")" ;;
        remove)
          if $dry; then _ul_run gpasswd -d "$user" -- "$group"; else gpasswd -d "$user" -- "$group" >/dev/null; fi
          $dry || ok "$(t "'%s' is no longer in '%s'." "$user" "$group")" ;;
        *) _ul_usage ;;
      esac ;;

    *) _ul_usage ;;
  esac
}
