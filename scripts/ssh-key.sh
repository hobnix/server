#!/usr/bin/env bash
# help: the SSH keys that may log in as adminuser (sshKeys in machine.toml): list, add, remove
# help.de: die SSH-Schlüssel, die sich als adminuser anmelden dürfen (sshKeys in machine.toml): anzeigen, hinzufügen, entfernen
# args: list | --list | add [<public key line> | --file <file.pub>] [--yes] | remove [<comment or fingerprint>] [--yes]
# Edits the list `sshKeys = [ ... ]` in machine.toml. Run bare (add / remove without a value) it asks. add checks the
# line (ssh-keygen when there is one, else the shape), remove refuses to take out the last key and the key of the SSH
# session you are in (found from the sshd log), so nobody locks themselves out. The file is copied to
# /var/lib/hs/machine.toml.before-ssh-key first and not replaced when the result does not parse. It takes effect
# with: hs rebuild
# --list (hs sys ssh-key list) is the plain form for the interface: one key per line, tab separated, never the key body:
#   id (SHA256:... fingerprint; the comment when there is no ssh-keygen), type (ed25519, rsa, ecdsa-nistp256, ...), comment ("-" = none), session (yes = the
#   key this SSH session logged in with, no = another or unknown). No keys: no lines. `hs ssh-key remove <id>` takes the id.
# HS_MACHINE_FILE, HS_STATE_DIR point tests at other files; HS_SSH_CURRENT_FP stands in for the detected session key, HS_PROC_ROOT for /proc (tests: no real session is found).
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/machine.sh"
machine=$(machine_file)
state=${HS_STATE_DIR:-/var/lib/hs}

usage() {
  say "usage: hs ssh-key list"
  say "       hs ssh-key add [<public key line> | --file <file.pub>] [--yes]"
  say "       hs ssh-key remove [<comment or fingerprint>] [--yes]"
  exit 1
}
interactive() { [ -t 0 ] && [ -t 1 ] && [ -z "${HS_CALLER:-}" ] || [ -n "${HS_GUIDED_TTY:-}" ]; }
need() { interactive || fail "$(t 'Missing: %s (give it as an option)' "$1")"; }
ok_confirm() { [ "$1" = true ] || { interactive || fail "Nothing is changed without --yes when there is no terminal."; confirm "$2" || fail "cancelled"; }; }

[ -f "$machine" ] || fail "$(t 'No %s.' "$machine")"

machine_has sshKeys || fail "$(t 'There is no sshKeys list in %s.' "$machine")"

keys() {   # the key lines, one per line
  machine_get sshKeys || true
}
fp_of() {   # fp_of <key line>: SHA256:..., or "?"
  local f out
  if command -v ssh-keygen >/dev/null 2>&1; then
    f=$(mktemp); printf '%s\n' "$1" > "$f"
    out=$(ssh-keygen -lf "$f" 2>/dev/null | awk '{ print $2; exit }' || true)
    rm -f "$f"
  fi
  echo "${out:-?}"
}
comment_of() { local c; c=$(cut -d' ' -f3- <<<"$1"); echo "${c:-(no comment)}"; }
type_of() { cut -d' ' -f1 <<<"$1" | sed 's/^ssh-//; s/^ecdsa-sha2-/ecdsa-/'; }
body_of() { cut -d' ' -f2 <<<"$1"; }

# is this one plain public key line?
valid_key() {   # valid_key <line>
  local line=$1 re
  re='^(ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/]+=*( [^"\\$]*)?$'
  [[ "$line" =~ $re ]] || return 1
  case "$line" in *'${'*|*'"'*|*'\'*) return 1 ;; esac
  if command -v ssh-keygen >/dev/null 2>&1; then [ "$(fp_of "$line")" != "?" ] || return 1; fi
}

# the fingerprint of the key the current SSH session logged in with (empty = unknown)
session_fp() {
  if [ -n "${HS_SSH_CURRENT_FP:-}" ]; then echo "$HS_SSH_CURRENT_FP"; return; fi
  local conn="${SSH_CONNECTION:-}" pid=$$ env
  # sudo drops the variable: look at the parent processes (root can read their environment)
  while [ -z "$conn" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
    env=$(tr '\0' '\n' < "${HS_PROC_ROOT:-/proc}/$pid/environ" 2>/dev/null | sed -n 's/^SSH_CONNECTION=//p' | head -n1 || true)
    [ -z "$env" ] || { conn=$env; break; }
    pid=$(awk '{ print $4 }' "${HS_PROC_ROOT:-/proc}/$pid/stat" 2>/dev/null || echo 0)
  done
  [ -n "$conn" ] || return 0
  command -v journalctl >/dev/null 2>&1 || return 0
  local ip port
  read -r ip port _ <<<"$conn"
  journalctl -u sshd.service -u ssh.service --no-pager -o cat -n 5000 2>/dev/null \
    | grep -F "Accepted publickey" | grep -F "from $ip port $port " | tail -n1 \
    | sed -n 's/.* \(SHA256:[^ ]*\).*/\1/p' || true
}

write_keys() {   # write_keys <keys...>: replaces the list, keeps the rest of the file
  local lit="" k
  for k in "$@"; do lit+="${lit:+, }\"$k\""; done   # the keys have no quote or backslash (valid_key)
  machine_set sshKeys "[$lit]" ssh-key || fail "The result would not parse: nothing changed."
  note "$(t 'The old file: %s' "$state/machine.toml.before-ssh-key")"
}

cmd=${1:-}; [ $# -eq 0 ] || shift
case "$cmd" in
--list)
  cur=$(session_fp)
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    f=$(fp_of "$k"); c=$(comment_of "$k"); [ "$c" != "(no comment)" ] || c="-"
    [ "$f" != "?" ] || f=$c
    printf '%s	%s	%s	%s
' "$f" "$(type_of "$k")" "$c" "$([ -n "$cur" ] && [ "$f" = "$cur" ] && echo yes || echo no)"
  done < <(keys) ;;

list)
  mapfile -t all < <(keys)
  if [ ${#all[@]} -eq 0 ]; then warn "No SSH keys in machine.toml. Nobody can log in over SSH."; next_step "hs ssh-key add"; exit 0; fi
  cur=$(session_fp)
  status_line "SSH keys" "$(t '%s may log in' "${#all[@]}")" ok
  { thead 'Comment' 'Type' 'Fingerprint'
    for k in "${all[@]}"; do
      f=$(fp_of "$k")
      printf '%s\t%s\t%s%s\n' "$(comment_of "$k")" "$(type_of "$k")" "$f" "$([ -n "$cur" ] && [ "$f" = "$cur" ] && printf '  %s' "$(_tr '<- this session')" || true)"
    done; } | table ;;

add)
  line=""; yes=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes) yes=true; shift ;;
      --file) [ $# -ge 2 ] || usage; [ -r "$2" ] || fail "$(t "Can't read %s." "$2")"; line=$(head -n1 "$2"); shift 2 ;;
      -*) usage ;;
      *) line="${line:+$line }$1"; shift ;;
    esac
  done
  if [ -z "$line" ]; then
    need "the public key"
    note "The public key is the line in ~/.ssh/id_ed25519.pub (or another .pub file) on the PC that should get access."
    line=$(ask "Public key (one line):" "")
  fi
  line=$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g' <<<"$line")
  valid_key "$line" || fail "That is not a public key line (it starts with ssh-ed25519, ssh-rsa or ecdsa-sha2-..., and it is the .pub file, not the private key)."
  mapfile -t all < <(keys)
  for k in ${all[@]+"${all[@]}"}; do
    if [ "$(body_of "$k")" = "$(body_of "$line")" ]; then note "This key is in the list already: nothing to do."; exit 0; fi
  done
  note "$(t 'Add the key %s (%s, %s)' "$(comment_of "$line")" "$(type_of "$line")" "$(fp_of "$line")")"
  ok_confirm "$yes" "$(t 'Add it to machine.toml?')"
  write_keys ${all[@]+"${all[@]}"} "$line"
  ok "$(t 'The key is in machine.toml. It takes effect with: hs rebuild')" ;;

remove)
  want=""; yes=false
  while [ $# -gt 0 ]; do
    case "$1" in --yes) yes=true; shift ;; -*) usage ;; *) want="${want:+$want }$1"; shift ;; esac
  done
  mapfile -t all < <(keys)
  [ ${#all[@]} -gt 0 ] || fail "There are no keys to remove."
  if [ -z "$want" ]; then
    need "the comment or fingerprint of the key"
    opts=()
    for k in "${all[@]}"; do opts+=("$(comment_of "$k")  $(fp_of "$k")"); done
    pick=$(choose "Which key should be removed?" "${opts[@]}") || fail "Nothing chosen."
    want=$(awk '{ print $NF }' <<<"$pick")
  fi
  hits=(); rest=()
  for k in "${all[@]}"; do
    f=$(fp_of "$k")
    if [ "$(comment_of "$k")" = "$want" ] || [ "$f" = "$want" ] || [ "${f#SHA256:}" = "$want" ]; then hits+=("$k"); else rest+=("$k"); fi
  done
  [ ${#hits[@]} -gt 0 ] || fail_fix "$(t "No key with the comment or fingerprint '%s'." "$want")" "hs ssh-key list"
  [ ${#hits[@]} -eq 1 ] || fail_fix "$(t "Several keys match '%s'. Use the fingerprint." "$want")" "hs ssh-key list"
  hit=${hits[0]}
  [ ${#rest[@]} -gt 0 ] || fail_fix "That is the last key. Without a key nobody could log in over SSH again: add the new one first." "hs ssh-key add"
  cur=$(session_fp)
  if [ -n "$cur" ] && [ "$(fp_of "$hit")" = "$cur" ]; then
    fail "This is the key your current SSH session used to log in. Log in with another key first, then remove this one from there."
  fi
  [ -n "$cur" ] || note "Could not tell which key this session uses. Make sure you can still log in with one of the others."
  note "$(t 'Remove the key %s (%s, %s)' "$(comment_of "$hit")" "$(type_of "$hit")" "$(fp_of "$hit")")"
  ok_confirm "$yes" "$(t 'Remove it from machine.toml?')"
  write_keys "${rest[@]}"
  ok "$(t 'The key is removed from machine.toml. It takes effect with: hs rebuild')" ;;

*) usage ;;
esac
