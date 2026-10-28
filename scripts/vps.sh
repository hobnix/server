#!/usr/bin/env bash
# help: the key the web interface uses to run `vps update` and `vps watch` on the proxyserver (the VPS): create it, show its public half
# help.de: der Schlüssel, mit dem die Weboberfläche `vps update` und `vps watch` auf dem Proxyserver (dem VPS) ausführt: anlegen, den öffentlichen Teil zeigen
# args: key [--new] [--yes]
# `hs vps key` creates an SSH key pair for this and prints ONLY the public key line and the exact line for the proxyserver's machine.nix (webKey).
# The private key never leaves this server: it is the secret /var/lib/hs/vps-key (inside the vault when there is one; a closed vault says
# "run hs unlock", nothing is written). With a key already there it prints the same two lines again (the public half is derived from the
# private one); --new replaces it (the old public line must then be replaced in the VPS's machine.nix as well).
# The VPS accepts that key for update, watch and status and nothing else (proxyserver repo: modules/ssh.nix, modules/cli/vps-remote.sh).
# Set vpsHost in machine.toml to switch the buttons on; steps: docs/web-interface.md.
# Test knobs: HS_STATE_DIR, HS_RUN_DIR (where the key is made first, default /run: memory only), HS_VAULT_DIR, HS_VAULT_OPEN.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/secret.sh"
state=${HS_STATE_DIR:-/var/lib/hs}
key=$state/vps-key

usage() { say "usage: hs vps key [--new] [--yes]"; exit 1; }
[ "${1:-}" = key ] || usage
shift
new=false yes=false
for a in "$@"; do
  case "$a" in --new) new=true ;; --yes) yes=true ;; *) usage ;; esac
done
interactive() { [ -t 0 ] && [ -t 1 ] && [ -z "${HS_CALLER:-}" ] || [ -n "${HS_GUIDED_TTY:-}" ]; }

command -v ssh-keygen >/dev/null 2>&1 || fail "ssh-keygen is not installed."

st=$(secret_state "$key")
if [ "$st" = locked ]; then
  vault_locked_note >&2
  fail_fix "The key lives in the closed vault." "hs unlock"
fi

if [ "$st" = ok ] && $new; then
  if ! $yes; then
    interactive || fail "Replacing the key needs --yes when there is no terminal."
    confirm "Replace the key? The proxyserver stops accepting the old one." || fail "cancelled"
  fi
  st=missing
  rm -f "$key"
fi

if [ "$st" != ok ]; then
  secret_prepare vps-key "$state" || fail_fix "The vault is closed." "hs unlock"
  mkdir -p "$state"
  run=${HS_RUN_DIR:-/run}
  [ -d "$run" ] && [ -w "$run" ] || run=${TMPDIR:-/tmp}
  tmp=$(umask 077; mktemp -d "$run/hs-vps-key.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT
  ssh-keygen -q -t ed25519 -N '' -C hs-web -f "$tmp/k" >/dev/null
  # written through the link into the vault, root only; the temporary copy is deleted when this script ends
  ( umask 077; cat "$tmp/k" > "$key" )
  chmod 600 "$key" 2>/dev/null || true
  ok "Key created"
else
  ok "Key exists"
fi

pub=$(ssh-keygen -y -f "$key" 2>/dev/null | awk 'NF { print $1 " " $2; exit }') || true
[ -n "$pub" ] || fail "The key could not be read."
pub="$pub hs-web"

step "Public key"
say "$pub"
step "Add to the machine.nix of the proxyserver"
say "webKey = \"$pub\";"
note "Then on the proxyserver: sudo vps update (or sudo nixos-rebuild switch). Afterwards set vpsHost in machine.toml here and run hs rebuild."
