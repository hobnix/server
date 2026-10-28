#!/usr/bin/env bash
# help: change a user or group of the domain without asking anything: what would happen (plan), then do it as a background job (start)
# help.de: einen Benutzer oder eine Gruppe der Domäne ändern, ohne etwas zu fragen: was passieren würde (plan), dann als Hintergrundjob ausführen (start)
# args: plan|start <name> <lock|unlock|group-add|membership|flush|password|user-add|user-delete|group-delete|user-edit|group-edit> [--change <user>:<group>=add|remove ...] [--full <name>] [--mail <address>] [--description <text>] [--group <group> ...] [--access <share>=read|write|full ...] [--confirm <word>]
# System command (hs sys users plan|start): for the interface, timers and tests. It never asks and prints plain key<TAB>value lines
# like pool-change.sh, ct-change.sh and share-change.sh. The console wizards (user-guided.sh) stay the
# console front ends over the same manage-users.sh.
#   lock | unlock                  <name> is the user: the account can / cannot log in (Administrator cannot be locked)
#   group-add [--access <share>=<level> ...]   <name> is the new group; every --access then gives it read|write|full on that share
#                                  (its SID is looked up once it exists, then manage-shares.sh --set)
#   membership                     <name> is the user or group being edited (for the heading); every --change names one membership:
#                                  <user>:<group>=add|remove (several allowed, applied in order, then the file server's caches are flushed)
#   flush                          the file server asks the domain controller again (net cache flush)
#   password                       <name> is the user; `start` reads the new password from the first line of standard input (never an argument)
#   user-add [--full <name>] [--group <group> ...]   <name> is the new login; `start` reads the password from standard input; the user starts in Domain Users
#                                  and, once the account exists, joins every --group (existing groups only, never Domain Users)
#   user-delete                    <name> is the user: RED, the name is typed; his files stay, his share permissions become dead entries
#   group-delete                   <name> is the group: RED, the name is typed; its members stay
#   user-edit [--full <name>] [--mail <address>] [--description <text>]   <name> is the user; only the named fields change, the value - clears one
#   group-edit [--description <text>]                                     <name> is the group (built-in groups are refused)
#
# plan: exit 0 = allowed, 1 = refused, 2 = something is missing. Output: status ok|refused|needs, then needs<TAB><input>
#   | reason<TAB><text> | heading|step|note|warn|danger|command<TAB><line>, confirm_name<TAB><name> (only with a danger line), long<TAB>no.
#   The two deletes are red; everything else can be undone.
# start: the same checks, then the work runs as a background job (status started, unit). A danger line needs --confirm <name>. A password
#   travels from standard input into a 0600 file under /run/hs that the job reads once and deletes, then into samba-tool's standard input.
# Test knobs: HS_MANAGE_USERS (stand-in for manage-users.sh), HS_USER_ACCESS (for user-access.sh), HS_MANAGE_SHARES, HS_WBINFO, HS_RUN_DIR.
set -euo pipefail
here=$(dirname "$0")
mu=${HS_MANAGE_USERS:-$here/manage-users.sh}
access=${HS_USER_ACCESS:-$here/user-access.sh}
mshares=${HS_MANAGE_SHARES:-$here/manage-shares.sh}
wb=${HS_WBINFO:-wbinfo}

# the job: apply the memberships one by one, stop at the first that fails, then flush the caches
if [ "${1:-}" = apply ]; then
  shift
  for c in "$@"; do
    user=${c%%:*}; rest=${c#*:}; group=${rest%=*}; mode=${rest##*=}
    echo "$mode $user $([ "$mode" = add ] && echo to || echo from) $group"
    bash "$mu" --member "$group" "$user" "$mode" || { echo "failed: $c" >&2; exit 1; }
  done
  bash "$mu" --flush
  exit 0
fi

# the job for a new group with access: create it, wait for its SID, then give it its level on every share (<share>=<level>)
if [ "${1:-}" = apply-group ]; then
  shift
  group=$1; shift
  bash "$mu" --group-add "$group" || exit 1
  bash "$mu" --flush || true
  dom=$("$wb" --own-domain 2>/dev/null | awk 'NR == 1' || true)
  sid=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sid=$("$wb" -n "${dom:+$dom\\}$group" 2>/dev/null | cut -d' ' -f1 || true)
    [[ "$sid" == S-1-* ]] && break
    sid=""; sleep 2
  done
  [ -n "$sid" ] || { echo "the new group has no SID yet; give it access in the Shares tab" >&2; exit 1; }
  for a in "$@"; do
    echo "${a#*=} access to ${a%%=*} for $group"
    bash "$mshares" "${a%%=*}" --set "$sid=${a#*=}" || { echo "failed: $a" >&2; exit 1; }
  done
  exit 0
fi

# is this line in the text (case does not matter, whole line)
has_line() { awk -v w="$2" 'BEGIN { w = tolower(w) } tolower($0) == w { f = 1 } END { exit !f }' <<<"$1"; }

# the job for a password: the file holds it, read once and deleted; manage-users.sh gets it on standard input
if [ "${1:-}" = apply-secret ]; then
  shift
  what=$1; user=$2; file=$3; full=${4:-}; shift 4 || shift $#
  pw=$(cat "$file"); rm -f "$file"
  case "$what" in
    password) printf '%s\n' "$pw" | bash "$mu" --password "$user" --stdin ;;
    user-add)
      if [ -n "$full" ]; then printf '%s\n' "$pw" | bash "$mu" --add "$user" --full "$full" --stdin || exit 1
      else printf '%s\n' "$pw" | bash "$mu" --add "$user" --stdin || exit 1; fi
      for g in "$@"; do
        echo "add $user to $g"
        bash "$mu" --member "$g" "$user" add || { echo "failed: $g" >&2; exit 1; }
      done
      [ $# -eq 0 ] || bash "$mu" --flush ;;
  esac
  exit 0
fi

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

verb=${1:-}; name=${2:-}; action=${3:-}
case "$verb" in plan|start) ;; *) echo "usage: user-change.sh plan|start <name> <action> [options]" >&2; exit 1 ;; esac
case "$action" in lock|unlock|group-add|membership|flush|password|user-add|user-delete|group-delete|user-edit|group-edit) ;; *) refuse "unknown action" ;; esac
shift 3
changes=() full="" confirm="" groups=() grant=() mail="" descr="" edits=()
while [ $# -gt 0 ]; do
  case "$1" in
    --change)  changes+=("${2:-}"); shift 2 ;;
    --confirm) confirm=${2:-}; shift 2 ;;
    --full)    full=${2:-}; edits+=(--full "$full"); shift 2 ;;
    --mail)    mail=${2:-}; edits+=(--mail "$mail"); shift 2 ;;
    --description) descr=${2:-}; edits+=(--description "$descr"); shift 2 ;;
    --group)   groups+=("${2:-}"); shift 2 ;;
    --access)  grant+=("${2:-}"); shift 2 ;;
    *) refuse "unknown option $1" ;;
  esac
done
[ "$action" = flush ] || [ -n "$name" ] || refuse "no name"
[[ "$name" != *$'\t'* && "$name" != *$'\n'* ]] || refuse "invalid name"

[ ${#groups[@]} -eq 0 ] || [ "$action" = user-add ] || refuse "--group belongs to user-add"
[ ${#grant[@]} -eq 0 ] || [ "$action" = group-add ] || refuse "--access belongs to group-add"
[ -z "$mail$descr" ] || [[ "$action" == *-edit ]] || refuse "--mail and --description belong to user-edit and group-edit"
[ "$action" != group-edit ] || [ -z "$full$mail" ] || refuse "a group has only a description"
[[ "$action" != *-edit ]] || [ ${#edits[@]} -gt 0 ] || refuse "nothing to change"
if [ ${#groups[@]} -gt 0 ]; then
  known=$(bash "$mu" --groups 2>/dev/null | cut -f1 || true)
  for g in "${groups[@]}"; do
    ! has_line "$g" "domain users" || refuse "Every user is in Domain Users; that can't be chosen here."
    has_line "$known" "$g" || refuse "No group called '$g'."
  done
fi
if [ ${#grant[@]} -gt 0 ]; then
  known=$(bash "$mshares" --list 2>/dev/null | cut -f1 || true)
  for a in "${grant[@]}"; do
    [[ "$a" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*=(read|write|full)$ ]] || refuse "expected <share>=read|write|full, got '$a'"
    has_line "$known" "${a%%=*}" || refuse "No share called '${a%%=*}'."
  done
fi
if [ "$action" = membership ] && [ ${#changes[@]} -eq 0 ]; then
  echo "status	needs"
  echo "needs	change"
  exit 2
fi

export HS_PLAIN=1 HS_LANG=en HS_CALLER=${HS_CALLER:-ui}
unset HS_GUIDED_TTY

# --- the plan: manage-users.sh's own dry run where it has one
dry=""
case "$action" in
  lock|unlock)
    opt=--disable; [ "$action" = unlock ] && opt=--enable
    rc=0; dry=$(bash "$mu" "$opt" "$name" --dry-run </dev/null 2>&1) || rc=$? ;;
  group-add)
    rc=0; dry=$(bash "$mu" --group-add "$name" --dry-run </dev/null 2>&1) || rc=$? ;;
  flush)
    rc=0; dry=$(bash "$mu" --flush --dry-run </dev/null 2>&1) || rc=$? ;;
  password)
    rc=0; dry=$(bash "$mu" --password "$name" --dry-run </dev/null 2>&1) || rc=$? ;;
  user-add)
    rc=0; dry=$(bash "$mu" --add "$name" ${full:+--full "$full"} --dry-run </dev/null 2>&1) || rc=$? ;;
  user-delete)
    rc=0; dry=$(bash "$mu" --delete "$name" --dry-run </dev/null 2>&1) || rc=$? ;;
  group-delete)
    rc=0; dry=$(bash "$mu" --group-delete "$name" --dry-run </dev/null 2>&1) || rc=$? ;;
  user-edit)
    rc=0; dry=$(bash "$mu" --edit user "$name" "${edits[@]}" --dry-run </dev/null 2>&1) || rc=$? ;;
  group-edit)
    rc=0; dry=$(bash "$mu" --edit group "$name" "${edits[@]}" --dry-run </dev/null 2>&1) || rc=$? ;;
  membership)
    rc=0
    # one reading of the domain checks every change (the dry run of --member would ask the controller once per change)
    users=$(bash "$mu" --list 2>/dev/null | cut -f1 || true)
    groups=$(bash "$mu" --groups 2>/dev/null | cut -f1 || true)
    for c in "${changes[@]}"; do
      if ! [[ "$c" =~ ^[^:=]+:[^=]+=(add|remove)$ ]]; then dry="expected <user>:<group>=add|remove, got '$c'"; rc=1; break; fi
      user=${c%%:*}; rest=${c#*:}; group=${rest%=*}; mode=${rest##*=}
      if ! has_line "$users" "$user"; then dry="No user called '$user'."; rc=1; break; fi
      if ! has_line "$groups" "$group"; then dry="No group called '$group'."; rc=1; break; fi
      if has_line "$group" "domain users"; then dry="Every user is in Domain Users; that can't be changed here."; rc=1; break; fi
      if [ "$mode" = remove ] && has_line "$user" administrator && has_line "$group" "domain admins"; then dry="Not possible: Administrator must stay in Domain Admins."; rc=1; break; fi
    done ;;
esac
if [ "$rc" -ne 0 ]; then
  echo "status	refused"
  printf '%s\n' "${dry:-the check failed without a message}" | sed -e 's/^[[:space:]]*//' -e 's/^✗ *//' -e 's/^! *//' -e 's/^Not possible: //' | awk 'NF { print "reason\t" $0 }'
  exit 1
fi

# --- the job
case "$action" in
  lock)       cmd=(bash "$mu" --disable "$name") ;;
  unlock)     cmd=(bash "$mu" --enable "$name") ;;
  group-add)  if [ ${#grant[@]} -gt 0 ]; then cmd=(bash "$(cd "$here" && pwd)/user-change.sh" apply-group "$name" "${grant[@]}"); else cmd=(bash "$mu" --group-add "$name"); fi ;;
  flush)      cmd=(bash "$mu" --flush) ;;
  password)   cmd=(bash "$(cd "$here" && pwd)/user-change.sh" apply-secret password "$name") ;;
  user-add)   cmd=(bash "$(cd "$here" && pwd)/user-change.sh" apply-secret user-add "$name") ;;
  user-delete)  cmd=(bash "$mu" --delete "$name" --yes) ;;
  group-delete) cmd=(bash "$mu" --group-delete "$name" --yes) ;;
  membership) cmd=(bash "$(cd "$here" && pwd)/user-change.sh" apply "${changes[@]}") ;;
  user-edit)  cmd=(bash "$mu" --edit user "$name" "${edits[@]}") ;;
  group-edit) cmd=(bash "$mu" --edit group "$name" "${edits[@]}") ;;
esac

danger=""
case "$action" in
  user-delete)  danger="The user '$name' is deleted from the domain. His files on the shares stay, his share permissions become dead entries; a new user with the same name does not get them back." ;;
  group-delete) danger="The group '$name' is deleted. Its members stay; they lose the access the group gave them." ;;
esac

if [ "$verb" = start ]; then
  if [ -n "$danger" ] && [ "$confirm" != "$name" ]; then refuse "type the name to confirm: $name"; fi
  . "$here/lib/job.sh"
  passfile=""
  case "$action" in
    password|user-add)
      IFS= read -r pass || pass=""
      [ -n "$pass" ] || refuse "no password on standard input"
      run_dir=${HS_RUN_DIR:-/run/hs}
      mkdir -p "$run_dir"; chmod 700 "$run_dir"
      passfile=$(mktemp "$run_dir/user-pass.XXXXXX")
      printf %s "$pass" > "$passfile"
      cmd+=("$passfile")
      [ "$action" != user-add ] || cmd+=("$full" ${groups[@]+"${groups[@]}"}) ;;
  esac
  unit=$(hs_job "user-$action-${name:-all}" "hs user $action ${name:-}" -- "${cmd[@]}") || { [ -z "$passfile" ] || rm -f "$passfile"; refuse "the job could not be started"; }
  printf 'status\tstarted\nunit\t%s\n' "$unit"
  exit 0
fi

echo "status	ok"
case "$action" in
  lock)   printf "heading\tlock %s\nstep\tlock the account: it can't log in or open shares any more\nnote\tConnections that are already open stay until they are closed.\n" "$name" ;;
  unlock) printf 'heading\tunlock %s\nstep\tunlock the account: it can log in again\n' "$name" ;;
  group-add) printf 'heading\tnew group %s\nstep\tcreate the group on the domain controller\nnote\tGive it access to shares in the Shares tab, and add members.\n' "$name"
    for a in ${grant[@]+"${grant[@]}"}; do printf 'step\tgive the group %s access to %s\n' "${a#*=}" "${a%%=*}"; done ;;
  flush)  printf 'heading\tforget cached users\nstep\tthe file server asks the domain controller again from now on\n' ;;
  password) printf 'heading\tnew password for %s\nstep\tset the new password on the domain controller\nnote\tThe password is typed once in the interface, goes straight into samba-tool and is never shown or written to a log. The domain'"'"'s password rules apply (length and complexity); the job says if it is refused.\n' "$name" ;;
  user-add) printf 'heading\tcreate the user %s\nstep\tcreate the account%s\nstep\tset its password\nnote\tThe user is in the group Domain Users and has no access to any share yet; use the Shares tab (permissions) and the groups of the user.\n' "$name" "${full:+ ($full)}"
    for g in ${groups[@]+"${groups[@]}"}; do printf 'step\tadd %s to %s\n' "$name" "$g"; done ;;
  user-delete)
    printf 'heading\tdelete the user %s\nstep\tdelete the account from the domain\n' "$name"
    g=$(bash "$mu" --list 2>/dev/null | awk -F'\t' -v u="$name" '$1 == u { print $4 }' | sed 's/,/, /g' || true)
    [ -z "$g" ] || printf 'warn\tHe is in these groups: %s\n' "$g"
    s=$(bash "$access" user "$name" 2>/dev/null | cut -f1 | paste -sd, - | sed 's/,/, /g' || true)
    [ -z "$s" ] || printf 'warn\tHe reaches these shares: %s\n' "$s" ;;
  group-delete)
    printf 'heading\tdelete the group %s\nstep\tdelete the group from the domain\n' "$name"
    m=$(bash "$mu" --groups 2>/dev/null | awk -F'\t' -v g="$name" '$1 == g { print $2 }' | sed 's/,/, /g' || true)
    [ -z "$m" ] || printf 'warn\tMembers who lose what the group gave them: %s\n' "$m"
    s=$(bash "$access" group "$name" 2>/dev/null | cut -f1 | paste -sd, - | sed 's/,/, /g' || true)
    [ -z "$s" ] || printf 'warn\tShares with an entry for the group (it stops working): %s\n' "$s" ;;
  user-edit|group-edit)
    printf 'heading\tchange the details of %s\n' "$name"
    i=0
    while [ $i -lt ${#edits[@]} ]; do
      f=${edits[$i]#--}; v=${edits[$((i + 1))]}; i=$((i + 2))
      case "$f" in mail) f=email ;; full) f="full name" ;; esac
      if [ "$v" = - ]; then printf 'step\tclear the %s\n' "$f"; else printf 'step\tset the %s to %s\n' "$f" "$v"; fi
    done
    [ "$action" != user-edit ] || ! printf '%s' "${edits[*]}" | grep -q -- '--full' || printf 'note\tThe login name stays as it is; only the name shown in lists and on file shares changes.\n' ;;
  membership)
    printf 'heading\tchange the groups of %s\n' "$name"
    for c in "${changes[@]}"; do
      user=${c%%:*}; rest=${c#*:}; group=${rest%=*}; mode=${rest##*=}
      if [ "$mode" = add ]; then printf 'step\tadd %s to %s\n' "$user" "$group"; else printf 'step\ttake %s out of %s\n' "$user" "$group"; fi
    done
    printf 'note\tThe file server forgets its cached groups afterwards; open connections keep their old rights until they are closed.\n' ;;
esac
printf 'command\t%s\n' "${cmd[*]}"
if [ -n "$danger" ]; then
  printf 'danger\t%s\nconfirm_name\t%s\n' "$danger" "$name"
fi
printf 'long\tno\n'
exit 0
