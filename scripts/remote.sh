#!/usr/bin/env bash
# help: share a folder with another homeserver, or mount one of theirs read-only (e.g. their films for Jellyfin)
# help.de: einen Ordner mit einem anderen Homeserver teilen oder einen von dessen Ordnern nur lesend einbinden (z. B. dessen Filme für Jellyfin)
# args: list | offer <share> --peer <name> [--new-password] [--yes] | revoke <peer> [<share>] [--yes]
#       add <peer> <host> <share> --user <login> [--domain <DOMAIN>] [--stdin] [--yes] | remove <peer> [<share>] [--yes]
#       attach <peer> <instance> [--path <inside>] | detach <peer> <instance> | mount-all
# Two sides, both with this tool. The side that GIVES access runs `offer`: a domain user `remote-<peer>` is made (or
# reused) and gets READ on the one share; the command prints host, user, domain and the password (shown once). The side
# that USES it runs `add`: the password goes into a credentials file (in the vault, like the other secrets), and the
# share is mounted read-only at /mnt/remote/<peer>/<share> (SMB 3, by `mount-all`, which the timer hs-remote-mount
# repeats every 2 minutes, so a peer that is off never blocks anything). `attach` hands the folder
# /mnt/remote/<peer> to an instance as a disk device with rslave propagation. recursive=true is needed (a plain bind carries only the empty folder, a container started after the mount saw nothing) and Incus refuses it together with readonly=true, so the read-only part is the SMB mount itself (mount option ro); a mount that comes later
# shows up inside without a restart. The mounts are NOT part of /bulk, SnapRAID, the backup or the share list.
# State: /var/lib/hs/remote-offers (peer, share, login, date), /var/lib/hs/remote-mounts (peer, host, share, login, domain),
# /var/lib/hs/remote-<peer>.cred (secret). Test knobs: HS_STATE_DIR, HS_REMOTE_ROOT, HS_MANAGE_USERS, HS_SHARE_PERM,
# HS_MOUNT_CMD, HS_UMOUNT, HS_MOUNTPOINT, HS_INCUS, HS_DOMAIN_SHORT, HS_HOST_NAME.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/secret.sh"
state=${HS_STATE_DIR:-/var/lib/hs}
root=${HS_REMOTE_ROOT:-/mnt/remote}
mu=${HS_MANAGE_USERS:-$here/manage-users.sh}
sp=${HS_SHARE_PERM:-$here/share-perm.sh}
incus_bin=${HS_INCUS:-incus}
OFFERS=$state/remote-offers
MOUNTS=$state/remote-mounts

usage() {
  say "usage: hs remote list"
  say "       hs remote offer <share> --peer <name> [--new-password] [--yes]   (this server gives access)"
  say "       hs remote revoke <peer> [<share>] [--yes]"
  say "       hs remote add <peer> <host> <share> --user <login> [--domain <DOMAIN>] [--stdin] [--yes]   (this server uses theirs)"
  say "       hs remote remove <peer> [<share>] [--yes]"
  say "       hs remote attach <peer> <instance> [--path <inside>]     |  hs remote detach <peer> <instance>"
  exit 1
}
interactive() { [ -t 0 ] && [ -t 1 ] && [ -z "${HS_CALLER:-}" ] || [ -n "${HS_GUIDED_TTY:-}" ]; }
sure() {   # sure <yes> <question>: the question unless --yes; no terminal without --yes = refuse
  [ "$1" = true ] && return 0
  interactive || fail "Nothing is changed without --yes when there is no terminal."
  confirm "$2" || fail "cancelled"
}
valid() {   # valid <what> <value> <regex>
  [[ "$2" =~ $3 ]] || fail "$(t "Invalid %s '%s'." "$1" "$2")"
}
v_peer()  { valid "peer name (lowercase letters, digits, -; at most 20)" "$1" '^[a-z0-9][a-z0-9-]{0,19}$'; }
v_share() { valid "share name" "$1" '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'; }
v_host()  { valid "host" "$1" '^[A-Za-z0-9][A-Za-z0-9._:-]{0,252}$'; }
v_login() { valid "login" "$1" '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'; }
v_ct()    { valid "instance name" "$1" '^[A-Za-z0-9][A-Za-z0-9-]{0,62}$'; }
today() { date +%F; }
need_root() { [ "$(id -u)" -eq 0 ] || [ "${HS_CALLER:-}" = test ] || fail "Run this with sudo (hs does that for you)."; }
cred_file() { echo "$state/remote-$1.cred"; }
user_of() { echo "remote-$1"; }
mnt_of() { echo "$root/$1/$2"; }
is_mounted() { timeout 10 ${HS_MOUNTPOINT:-mountpoint} -q "$1" 2>/dev/null; }
rows() { [ -f "$1" ] && grep -v '^[[:space:]]*#' "$1" || true; }   # rows <file>: the records
drop() {   # drop <file> <field=value>... : delete the records whose first N fields match
  local f=$1; shift
  [ -f "$f" ] || return 0
  awk -F'\t' -v OFS='\t' -v want="$(IFS=$'\x01'; echo "$*")" '
    BEGIN { n = split(want, w, "\001") }
    { keep = 0; for (i = 1; i <= n; i++) if ($i != w[i]) keep = 1; if (keep) print }' "$f" > "$f.new"
  mv "$f.new" "$f"
}
gen_password() { local p; p=$(head -c 24 /dev/urandom | base64 | tr -d '/+=\n'); echo "${p}-Aa1"; }

write_cred() {   # write_cred <peer> <login> <domain>; password on stdin (one line)
  local f pw; f=$(cred_file "$1")
  IFS= read -r pw || pw=""
  [ -n "$pw" ] || fail "No password."
  secret_prepare "remote-$1.cred" "$state" || fail_fix "The vault is closed." "hs unlock"
  ( umask 077
    { printf 'username=%s\n' "$2"; printf 'password=%s\n' "$pw"; [ -z "$3" ] || printf 'domain=%s\n' "$3"; } > "$f" )
  chmod 600 "$f"
}

domain_short() {
  if [ -n "${HS_DOMAIN_SHORT:-}" ]; then echo "$HS_DOMAIN_SHORT"; return; fi
  wbinfo --own-domain 2>/dev/null || true
}
has_user() { bash "$mu" --list 2>/dev/null | awk -F'	' -v n="$1" 'tolower($1) == tolower(n) { f = 1 } END { exit !f }'; }   # awk reads all input: no SIGPIPE under pipefail (as grep -q would)

# ---------------------------------------------------------------- mounting
mount_one() {   # mount_one <peer> <host> <share> <login> <domain>: 0 mounted (now or before), 1 not
  local peer=$1 host=$2 share=$3 m cred
  m=$(mnt_of "$peer" "$share"); cred=$(cred_file "$peer")
  is_mounted "$m" && return 0
  case "$(secret_state "$cred")" in ok) ;; locked) note "$(t '%s/%s: the vault is closed, not mounted.' "$peer" "$share")"; return 1 ;; *) warn "$(t '%s/%s: no credentials file.' "$peer" "$share")"; return 1 ;; esac
  mkdir -p "$m"
  # soft + short echo interval: a peer that goes away gives errors after a while instead of hanging every reader
  # shellcheck disable=SC2086
  if timeout 25 ${HS_MOUNT_CMD:-mount -t cifs} "//$host/$share" "$m" \
       -o "credentials=$cred,vers=3,ro,nosuid,nodev,noexec,soft,echo_interval=10,actimeo=30,uid=0,gid=0,file_mode=0444,dir_mode=0555" >/dev/null 2>&1; then
    ok "$(t 'Mounted %s/%s' "$peer" "$share")"
  else
    warn "$(t '%s/%s: %s is not reachable or refused the login; it is tried again.' "$peer" "$share" "$host")"
    return 1
  fi
}

# ---------------------------------------------------------------- commands
cmd=${1:-}
[ -n "$cmd" ] || usage
shift

yes=false; stdin_pw=false; newpw=false; plain=false
peer=""; login=""; domain=""; path=""; pos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) yes=true ;;
    --plain) plain=true ;;
    --stdin) stdin_pw=true ;;
    --new-password) newpw=true ;;
    --peer)   [ $# -ge 2 ] || usage; peer=$2; shift ;;
    --user)   [ $# -ge 2 ] || usage; login=$2; shift ;;
    --domain) [ $# -ge 2 ] || usage; domain=$2; shift ;;
    --path)   [ $# -ge 2 ] || usage; path=$2; shift ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) pos+=("$1") ;;
  esac
  shift
done
set -- "${pos[@]+"${pos[@]}"}"

case "$cmd" in
  list)
    if [ -t 1 ] && [ -z "${HS_CALLER:-}" ]; then
      step "Access given"
      if [ -n "$(rows "$OFFERS")" ]; then { thead 'Peer' 'Share' 'Login' 'Since'; rows "$OFFERS"; } | table; else note "Nothing is shared with another server."; fi
      step "Mounted from other servers"
      if [ -n "$(rows "$MOUNTS")" ]; then
        { thead 'Peer' 'Share' 'Host' 'State'
          while IFS=$'\t' read -r p h s _; do
            printf '%s\t%s\t%s\t%s\n' "$p" "$s" "$h" "$(if is_mounted "$(mnt_of "$p" "$s")"; then _tr mounted; else _tr 'not mounted'; fi)"
          done < <(rows "$MOUNTS"); } | table
      else note "Nothing is mounted from another server."; fi
    else
      # machine-readable: kind, peer, share, host-or-login, state
      while IFS=$'\t' read -r p s l _; do printf 'offer\t%s\t%s\t%s\tgiven\n' "$p" "$s" "$l"; done < <(rows "$OFFERS")
      while IFS=$'\t' read -r p h s _; do
        printf 'mount\t%s\t%s\t%s\t%s\n' "$p" "$s" "$h" "$(if is_mounted "$(mnt_of "$p" "$s")"; then echo mounted; else echo down; fi)"
      done < <(rows "$MOUNTS")
    fi ;;

  offer)
    [ $# -eq 1 ] && [ -n "$peer" ] || usage
    share=$1; v_share "$share"; v_peer "$peer"
    need_root
    login=$(user_of "$peer")
    dsh=$(domain_short)
    exists=false; has_user "$login" && exists=true
    pw=""
    if ! $exists || $newpw; then pw=$(gen_password); fi
    step "$(t 'Give %s read access to %s' "$peer" "$share")"
    kv "Login" "${dsh:+$dsh\\}$login"
    if $exists && ! $newpw; then note "The login exists already; its password stays as it is (--new-password makes a new one)."; fi
    note "$(t 'The login can only read the share %s, nothing else.' "$share")"
    sure "$yes" "Go ahead?"
    if [ -n "$pw" ]; then
      if $exists; then printf '%s\n' "$pw" | bash "$mu" --password "$login" --stdin
      else printf '%s\n' "$pw" | bash "$mu" --add "$login" --full "Remote $peer" --stdin; fi
      bash "$mu" --flush >/dev/null 2>&1 || true
    fi
    bash "$sp" "$share" "$login=read" >/dev/null
    mkdir -p "$state"; touch "$OFFERS"
    drop "$OFFERS" "$peer" "$share"
    printf '%s\t%s\t%s\t%s\n' "$peer" "$share" "$login" "$(today)" >> "$OFFERS"
    ok "$(t '%s can read %s.' "$peer" "$share")"
    hostn=${HS_HOST_NAME:-$(hostname)}; hostn=${hostn,,}
    if $plain; then   # for the web interface (peer-change.sh): tagged lines, the password only when a new one was made
      printf 'offer-result\tlogin\t%s\n' "$login"
      [ -z "$dsh" ] || printf 'offer-result\tdomain\t%s\n' "$dsh"
      printf 'offer-result\thost\t%s\n' "$hostn.local"
      [ -z "$pw" ] || printf 'offer-result\tpassword\t%s\n' "$pw"
      exit 0
    fi
    pwline=""
    if [ -n "$pw" ]; then pwline="$(say 'Password (shown once, they type it when asked):')  $pw"; fi
    box <<EOF
$(say "Tell the other person (on their server):")

  hs remote add $hostn $hostn.local $share --user $login${dsh:+ --domain $dsh}

$pwline
$(say "Revoke later with:")  hs remote revoke $peer $share
EOF
    ;;

  revoke)
    [ $# -ge 1 ] || usage
    p=$1; s=${2:-}; v_peer "$p"; [ -z "$s" ] || v_share "$s"
    need_root
    login=$(user_of "$p")
    shares=$(rows "$OFFERS" | awk -F'\t' -v p="$p" -v s="$s" '$1 == p && (s == "" || $2 == s) { print $2 }')
    [ -n "$shares" ] || fail_fix "$(t "Nothing is shared with '%s'." "$p")" "hs remote list"
    step "$(t 'Take access away from %s' "$p")"
    while read -r sh; do kv "Share" "$sh"; done <<<"$shares"
    note "$(t "Their login '%s' is deleted when no share is left." "$login")"
    sure "$yes" "Go ahead?"
    while read -r sh; do
      bash "$sp" "$sh" "$login=none" >/dev/null || warn "$(t 'Could not change the permissions of %s.' "$sh")"
      drop "$OFFERS" "$p" "$sh"
    done <<<"$shares"
    if [ -z "$(rows "$OFFERS" | awk -F'\t' -v p="$p" '$1 == p')" ] && has_user "$login"; then
      bash "$mu" --delete "$login" --yes
    fi
    ok "$(t 'Access of %s revoked. Open connections end when they are closed.' "$p")" ;;

  add)
    [ $# -eq 3 ] && [ -n "$login" ] || usage
    p=$1; h=$2; s=$3; v_peer "$p"; v_host "$h"; v_share "$s"; v_login "$login"
    [ -z "$domain" ] || v_login "$domain"
    need_root
    ! rows "$MOUNTS" | awk -F'\t' -v p="$p" -v s="$s" '$1 == p && $3 == s { f = 1 } END { exit !f }' || fail_fix "$(t "'%s' / '%s' is set up already." "$p" "$s")" "hs remote remove $p $s"
    step "$(t 'Mount %s from %s' "$s" "$p")"
    kv "Address" "//$h/$s"
    kv "Login" "${domain:+$domain\\}$login"
    kv "Where" "$(mnt_of "$p" "$s")"
    note "Read only. Not part of /bulk, the parity or the backup."
    sure "$yes" "Go ahead?"
    if $stdin_pw; then IFS= read -r pw || pw=""
    else
      interactive || fail "Missing: the password (give it on standard input with --stdin)."
      pw=$(ask_secret "$(t 'Password of %s' "$login")")
    fi
    printf '%s\n' "$pw" | write_cred "$p" "$login" "$domain"
    mkdir -p "$state"; touch "$MOUNTS"
    printf '%s\t%s\t%s\t%s\t%s\n' "$p" "$h" "$s" "$login" "$domain" >> "$MOUNTS"
    if mount_one "$p" "$h" "$s" "$login" "$domain"; then
      next_step "hs remote attach $p <instance>"
    else
      warn "The login or the address may be wrong. It stays set up and is tried every 2 minutes (hs remote list)."
    fi ;;

  remove)
    [ $# -ge 1 ] || usage
    p=$1; s=${2:-}; v_peer "$p"; [ -z "$s" ] || v_share "$s"
    need_root
    list=$(rows "$MOUNTS" | awk -F'\t' -v p="$p" -v s="$s" '$1 == p && (s == "" || $3 == s) { print $3 }')
    [ -n "$list" ] || fail_fix "$(t "Nothing is mounted from '%s'." "$p")" "hs remote list"
    step "$(t 'Stop using %s' "$p")"
    while read -r sh; do kv "Share" "$sh"; done <<<"$list"
    note "Instances that got the folder with 'attach' keep an empty folder."
    sure "$yes" "Go ahead?"
    while read -r sh; do
      m=$(mnt_of "$p" "$sh")
      if is_mounted "$m"; then ${HS_UMOUNT:-umount} "$m" || fail "$(t '%s is in use: stop what reads it first.' "$m")"; fi
      rmdir "$m" 2>/dev/null || true
      awk -F'\t' -v p="$p" -v s="$sh" '!($1 == p && $3 == s)' "$MOUNTS" > "$MOUNTS.new" || true
      mv "$MOUNTS.new" "$MOUNTS"
    done <<<"$list"
    if [ -z "$(rows "$MOUNTS" | awk -F'\t' -v p="$p" '$1 == p')" ]; then
      rm -f "$(cred_file "$p")"; rmdir "$root/$p" 2>/dev/null || true
    fi
    ok "$(t 'Removed. Files on the other server are untouched.')" ;;

  attach)
    [ $# -eq 2 ] || usage
    p=$1; c=$2; v_peer "$p"; v_ct "$c"
    need_root
    [ -n "$(rows "$MOUNTS" | awk -F'\t' -v p="$p" '$1 == p')" ] || fail_fix "$(t "Nothing is mounted from '%s'." "$p")" "hs remote list"
    [ -n "$path" ] || path=/media-$p
    case "$path" in /*) ;; *) fail "The path inside the instance starts with /." ;; esac
    mkdir -p "$root/$p"
    dev=remote-$p
    "$incus_bin" info "$c" >/dev/null 2>&1 || fail_fix "$(t "No instance called '%s'." "$c")" "hs ct list"
    if "$incus_bin" config device get "$c" "$dev" source >/dev/null 2>&1; then fail_fix "$(t "'%s' has the device %s already." "$c" "$dev")" "hs remote detach $p $c"; fi
    "$incus_bin" config device add "$c" "$dev" disk source="$root/$p" path="$path" recursive=true propagation=rslave >/dev/null
    ok "$(t '%s sees the shares of %s under %s (read only).' "$c" "$p" "$path")" ;;

  detach)
    [ $# -eq 2 ] || usage
    p=$1; c=$2; v_peer "$p"; v_ct "$c"
    need_root
    "$incus_bin" config device remove "$c" "remote-$p" >/dev/null 2>&1 || fail "$(t "'%s' has no device remote-%s." "$c" "$p")"
    ok "$(t 'Removed from %s.' "$c")" ;;

  mount-all)   # the timer: mount what is configured and not mounted; never fails the unit because a peer is off
    [ -n "$(rows "$MOUNTS")" ] || exit 0
    while IFS=$'\t' read -r p h s l d; do mount_one "$p" "$h" "$s" "$l" "$d" || true; done < <(rows "$MOUNTS")
    exit 0 ;;

  *) usage ;;
esac
