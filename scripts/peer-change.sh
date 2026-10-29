#!/usr/bin/env bash
# help: change the shares between two homeservers without asking anything: what would happen (plan), then do it (start)
# help.de: die Freigaben zwischen zwei Homeservern ändern, ohne etwas zu fragen: was passieren würde (plan), dann ausführen (start)
# args: plan|start offer <peer> <share> [--new-password] | add <peer> <host> <share> --user <login> [--domain <D>] | remove <peer> [<share>] | revoke <peer> [<share>] | attach <peer> <instance> [--path <inside>] | detach <peer> <instance>
# System command (hs sys peers plan|start): for the interface and tests. It never asks and prints plain key<TAB>value lines like backup-change.sh.
# The work is remote.sh's (no logic is repeated here). The reads are `hs sys remote list`.
#   offer    give another homeserver read access to a share (the login remote-<peer>). It is answered in the start answer itself, never as a
#            background job, so no job log keeps the new password: the lines `secret<TAB>login|domain|host|password<TAB>value` hold what the
#            other side types (the password only when a new one was made).
#   add      mount a share of another homeserver read only; the password of the login is ONE LINE ON STANDARD INPUT of start (never in the arguments)
#   remove   stop using a peer's share: unmount it and forget the login (red: confirm_name = the peer)
#   revoke   take the access away that this server gave a peer; the login is deleted when it has no share left (red: confirm_name = the peer)
#   attach   give an instance the mounted shares of a peer, read only
#   detach   take them away from the instance again
# plan: exit 0 = allowed, 1 = refused, 2 = something is missing (needs<TAB>password is not asked by plan). Output: status ok|refused,
#   reason<TAB><text>, heading|step|note|warn|danger|command<TAB><line>, confirm_name<TAB><peer>, long<TAB>no.
# start: the same checks (and the typed peer for a red plan), then the work; status done, or refused with the reason.
# Test knobs: HS_REMOTE (stand-in for remote.sh), HS_STATE_DIR.
set -euo pipefail
here=$(dirname "$0")
remote=${HS_REMOTE:-$here/remote.sh}

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

verb=${1:-}; action=${2:-}
case "$verb" in plan|start) ;; *) echo "usage: peer-change.sh plan|start add|remove|revoke|attach|detach ..." >&2; exit 1 ;; esac
case "$action" in offer|add|remove|revoke|attach|detach) ;; *) refuse "unknown action (offer, add, remove, revoke, attach or detach)" ;; esac
shift 2 || true

valid() { [[ "$2" =~ $3 ]] || refuse "that is not a valid $1"; }
peer=${1:-}; valid "peer name (lower-case letters, digits and dashes, at most 20)" "$peer" '^[a-z0-9][a-z0-9-]{0,19}$'
shift
a="" b="" login="" domain="" path="" confirm="" newpw=false
case "$action" in
  offer) a=${1:-}; shift || true; valid "share name" "$a" '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' ;;
  add) a=${1:-}; b=${2:-}; shift 2 || refuse "add needs <host> and <share>"
       valid "host" "$a" '^[A-Za-z0-9][A-Za-z0-9._:-]{0,252}$'; valid "share name" "$b" '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' ;;
  remove|revoke) if [ $# -gt 0 ] && [[ "$1" != -* ]]; then a=$1; shift; valid "share name" "$a" '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'; fi ;;
  attach|detach) a=${1:-}; shift || true; valid "instance name" "$a" '^[A-Za-z0-9][A-Za-z0-9-]{0,62}$' ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --user)    [ $# -ge 2 ] || refuse "--user needs a value"; login=$2; shift 2 ;;
    --domain)  [ $# -ge 2 ] || refuse "--domain needs a value"; domain=$2; shift 2 ;;
    --path)    [ $# -ge 2 ] || refuse "--path needs a value"; path=$2; shift 2 ;;
    --new-password) newpw=true; shift ;;
    --confirm) [ $# -ge 2 ] || refuse "--confirm needs a value"; confirm=$2; shift 2 ;;
    *) refuse "unknown option $1" ;;
  esac
done
if [ "$action" = add ]; then
  [ -n "$login" ] || refuse "add needs --user <login>"
  valid "login" "$login" '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
  [ -z "$domain" ] || valid "domain" "$domain" '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
fi
if [ "$action" = attach ] && [ -n "$path" ]; then valid "path" "$path" '^/[A-Za-z0-9._/-]{1,200}$'; fi

export HS_PLAIN=1 HS_LANG=en HS_CALLER=${HS_CALLER:-ui}
unset HS_GUIDED_TTY

list=$(bash "$remote" list </dev/null 2>/dev/null || true)   # kind peer share host-or-login state
has_row() { awk -F'\t' -v k="$1" -v p="$2" -v s="${3:-}" '$1 == k && $2 == p && (s == "" || $3 == s) { f = 1 } END { exit !f }' <<<"$list"; }
case "$action" in
  offer)  if has_row offer "$peer" "$a" && ! $newpw; then refuse "'$a' is offered to '$peer' already (tick the new password to change it)."; fi ;;
  add)    if has_row mount "$peer" "$b"; then refuse "'$peer' / '$b' is set up already."; fi ;;
  remove) has_row mount "$peer" "$a" || refuse "Nothing is mounted from '$peer'${a:+ / '$a'}." ;;
  revoke) has_row offer "$peer" "$a" || refuse "Nothing is shared with '$peer'${a:+ / '$a'}." ;;
  attach|detach) has_row mount "$peer" || refuse "Nothing is mounted from '$peer'." ;;
esac

red=""
case "$action" in remove|revoke) red=$peer ;; esac

args=("$action")
case "$action" in
  offer)  args=(offer "$a" --peer "$peer"); ! $newpw || args+=(--new-password); args+=(--plain --yes) ;;
  add)    args+=("$peer" "$a" "$b" --user "$login"); [ -z "$domain" ] || args+=(--domain "$domain"); args+=(--stdin --yes) ;;
  remove|revoke) args+=("$peer"); [ -z "$a" ] || args+=("$a"); args+=(--yes) ;;
  attach) args+=("$peer" "$a"); [ -z "$path" ] || args+=(--path "$path") ;;
  detach) args+=("$peer" "$a") ;;
esac

if [ "$verb" = start ]; then
  if [ -n "$red" ] && [ "$confirm" != "$red" ]; then refuse "type the peer name to confirm: $red"; fi
  rc=0
  if [ "$action" = offer ]; then
    out=$(bash "$remote" "${args[@]}" </dev/null 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
      refuse "$(printf '%s' "$out" | sed -e 's/^[[:space:]]*//' -e 's/^[✗!] *//' | awk 'NF' | tail -n 1)"
    fi
    printf 'status\tdone\n'
    awk -F'\t' '$1 == "offer-result" { printf "secret\t%s\t%s\n", $2, $3 }' <<<"$out"
    exit 0
  fi
  if [ "$action" = add ]; then out=$(bash "$remote" "${args[@]}" 2>&1) || rc=$?
  else out=$(bash "$remote" "${args[@]}" </dev/null 2>&1) || rc=$?; fi
  if [ "$rc" -ne 0 ]; then
    refuse "$(printf '%s' "$out" | sed -e 's/^[[:space:]]*//' -e 's/^[✗!] *//' | awk 'NF' | tail -n 1)"
  fi
  printf 'status\tdone\n'
  exit 0
fi

printf 'status\tok\n'
case "$action" in
  offer)
    printf 'heading\tgive %s read access to %s\n' "$peer" "$a"
    printf 'step\tmake the login remote-%s, which can read this share and nothing else\n' "$peer"
    if $newpw; then printf 'warn\tA new password is made; the old one stops working.\n'; fi
    printf 'note\tThe password is shown once, on the next screen. It is not kept in any log.\n' ;;
  add)
    printf 'heading\tmount %s of %s read only\n' "$b" "$peer"
    printf 'step\tsave the login %s%s (the password goes into the vault)\n' "${domain:+$domain\\}" "$login"
    printf 'step\tmount //%s/%s at /mnt/remote/%s/%s\n' "$a" "$b" "$peer" "$b"
    printf 'note\tRead only. Not part of /bulk, the parity or the backup. A peer that is off is tried again every 2 minutes.\n' ;;
  remove)
    printf 'heading\tstop using %s%s\n' "$peer" "${a:+ / $a}"
    printf 'step\tunmount it and forget the saved login\n'
    printf 'warn\tTo use it again you need a new password from the other server.\n' ;;
  revoke)
    printf 'heading\ttake the access away from %s%s\n' "$peer" "${a:+ / $a}"
    printf 'step\tthe login of %s can no longer read it\n' "$peer"
    printf 'warn\tThe login is deleted when it has no other share left. Giving access again makes a new password.\n' ;;
  attach)
    printf 'heading\tgive %s the shares of %s\n' "$a" "$peer"
    printf 'step\tadd them to %s as a read-only folder%s\n' "$a" "${path:+ at $path}" ;;
  detach)
    printf 'heading\ttake the shares of %s away from %s\n' "$peer" "$a"
    printf 'step\tremove the folder from %s\n' "$a" ;;
esac
printf 'command\ths remote %s ...\n' "$action"
[ -z "$red" ] || printf 'confirm_name\t%s\n' "$red"
printf 'long\tno\n'
exit 0
