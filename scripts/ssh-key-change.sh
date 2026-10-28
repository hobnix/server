#!/usr/bin/env bash
# help: add or remove an SSH key of adminuser without asking anything: what would happen (plan), then do it (start)
# help.de: einen SSH-Schlüssel von adminuser hinzufügen oder entfernen, ohne etwas zu fragen: was passieren würde (plan), dann ausführen (start)
# args: plan|start <add <public key line>|remove <id>> [--confirm remove]
# System command (hs sys ssh-key plan|start): for the interface and tests. It never asks and prints plain key<TAB>value lines like jobs-change.sh and
# backup-change.sh (docs/PLAN-web-backend.md). The work is done by ssh-key.sh (the one place that edits `sshKeys` in machine.toml, through machine.sh).
#   add <key>     the public key as ONE argument (type, base64 body, optional comment; at most 800 characters, one line). Refused for a shape that is not a
#                 public key line, for a key that is in the list already. Written to machine.toml at once; it takes effect with: hs rebuild
#   remove <id>   the id column of `hs sys ssh-key list` (fingerprint). Refused for the LAST key (nobody could log in over SSH again) and for the key of the
#                 current SSH session. RED: the word `remove` must be typed. Written to machine.toml at once; takes effect with: hs rebuild
#
# plan: exit 0 = allowed, 1 = refused. Output: status ok|refused, reason<TAB><text> | heading|step|note|warn|danger|command<TAB><line>,
#   confirm_name<TAB>remove (only with a danger line), long<TAB>no.
# start: the same checks; status done (and a note: hs rebuild) or refused with the reason. A danger line needs --confirm remove.
# Test knobs: HS_SSH_KEY (stand-in for ssh-key.sh), HS_MACHINE_FILE, HS_STATE_DIR.
set -euo pipefail
here=$(dirname "$0")
sshkey=${HS_SSH_KEY:-$here/ssh-key.sh}
. "$here/lib/machine.sh"
export HS_PLAIN=1

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

verb=${1:-}; action=${2:-}
case "$verb" in plan|start) ;; *) echo "usage: ssh-key-change.sh plan|start <add <key>|remove <id>> [--confirm remove]" >&2; exit 1 ;; esac
case "$action" in add|remove) ;; *) refuse "unknown action (add or remove)" ;; esac
[ $# -ge 3 ] || refuse "give the public key or the id of the key as one argument"
arg=$3
shift 3
confirm=""
while [ $# -gt 0 ]; do
  case "$1" in
    --confirm) confirm=${2:-}; shift 2 ;;
    *) refuse "unknown option" ;;
  esac
done

# one line without control characters (newline, tab, ...) and not too long, for both actions
[ "${#arg}" -le 800 ] || refuse "that is too long"
case "$arg" in *[[:cntrl:]]*) refuse "it must be one line without control characters" ;; esac

lastline() { sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' | awk 'NF { l = $0 } END { sub(/^[^A-Za-z0-9]+/, "", l); print l }'; }
list=$(bash "$sshkey" --list 2>/dev/null || true)
count=$(awk 'NF { n++ } END { print n + 0 }' <<<"$list")

danger=""
case "$action" in
  add)
    re='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/]{16,}={0,3}( [A-Za-z0-9@._:+=, -]{1,100})?$'
    [[ "$arg" =~ $re ]] || refuse "that is not a public key line (ssh-ed25519 AAAA... comment): use the .pub file, never the private key"
    type=${arg%% *}; body=$(cut -d' ' -f2 <<<"$arg"); comment=$(cut -d' ' -f3- <<<"$arg"); comment=${comment:-no comment}
    fp="?"
    if command -v ssh-keygen >/dev/null 2>&1; then
      tmp=$(mktemp); printf '%s\n' "$arg" > "$tmp"
      fp=$(ssh-keygen -lf "$tmp" 2>/dev/null | awk '{ print $2; exit }' || true); rm -f "$tmp"
      [ -n "$fp" ] || refuse "that is not a valid public key"
    fi
    while IFS= read -r k; do
      [ -n "$k" ] || continue
      [ "$(cut -d' ' -f2 <<<"$k")" != "$body" ] || refuse "this key is in the list already"
    done < <(machine_get sshKeys 2>/dev/null || true) ;;
  remove)
    line=$(awk -F'\t' -v id="$arg" '$1 == id { print; exit }' <<<"$list")
    [ -n "$line" ] || refuse "there is no key with this id"
    [ "$count" -gt 1 ] || refuse "that is the last key: without a key nobody could log in over SSH again. Add the new one first."
    [ "$(cut -f4 <<<"$line")" != yes ] || refuse "that is the key your current SSH session used. Log in with another key first, then remove this one."
    comment=$(cut -f3 <<<"$line"); type=$(cut -f2 <<<"$line")
    danger="Whoever has the private key of '$comment' ($type) can no longer log in as adminuser once the server is rebuilt. Make sure you can still get in with another key." ;;
esac

if [ "$verb" = start ]; then
  if [ -n "$danger" ] && [ "$confirm" != remove ]; then refuse "type the word to confirm: remove"; fi
  if ! out=$(HS_CALLER=${HS_CALLER:-ui} bash "$sshkey" "$action" "$arg" --yes 2>&1); then refuse "$(lastline <<<"$out")"; fi
  printf 'status\tdone\nnote\tIt is in machine.toml; it takes effect with: hs rebuild\n'
  exit 0
fi

echo "status	ok"
case "$action" in
  add)
    printf 'heading\tallow the SSH key %s\n' "$comment"
    printf 'step\tadd the key (%s, %s) to sshKeys in machine.toml; the old file is kept in /var/lib/hs/machine.toml.before-ssh-key\n' "${type#ssh-}" "$fp" ;;
  remove)
    printf 'heading\tremove the SSH key %s\n' "$comment"
    printf 'step\ttake the key (%s, %s) out of sshKeys in machine.toml; the old file is kept in /var/lib/hs/machine.toml.before-ssh-key\n' "$type" "$arg" ;;
esac
printf 'note\tThis only changes machine.toml. The change takes effect with: hs rebuild\n'
printf 'command\ths ssh-key %s\n' "$action"
if [ -n "$danger" ]; then printf 'danger\t%s\nconfirm_name\tremove\n' "$danger"; fi
printf 'long\tno\n'
exit 0
