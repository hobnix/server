# shellcheck shell=bash
# How the scripts treat a secret that may live in the vault. Sourced after ui.sh:
#   . "$(dirname "$0")/lib/secret.sh"
# The old paths (/var/lib/hs/<name>) stay what the scripts read; with the vault closed they are links that dangle.
# A dangling link is "locked", never "missing": nothing may say "not set up" because the vault is closed.
#
#   secret_state <path>        ok | locked | missing          (never reads the content)
#   secret_in_vault <path>     0 when the path is a link into the vault (open or closed)
#   secret_batch               0 for a timer or a job (HS_CALLER=timer|job, or a systemd unit without a terminal)
#   secret_locked_exit         prints the note on stderr; exit 0 in a timer/job (skip, logged), else exit 1
#   secret_prepare <name>      before a script WRITES a new secret at $state/<name>: with a vault it is created
#                              inside it and linked; returns 1 (note printed) when the vault is closed
. "$(dirname "${BASH_SOURCE[0]}")/vault.sh"

secret_state() {
  local p=$1
  if [ -e "$p" ]; then echo ok
  elif [ -L "$p" ] && vault_configured && ! vault_is_open; then echo locked
  else echo missing; fi
}
secret_in_vault() {
  local t
  [ -L "$1" ] || return 1
  t=$(readlink "$1")
  case "$t" in "${HS_VAULT_DIR:-/var/lib/hs-vault}"/*) return 0 ;; *) return 1 ;; esac
}
secret_batch() {
  case "${HS_CALLER:-}" in timer|job) return 0 ;; esac
  [ -n "${INVOCATION_ID:-}" ] && [ ! -t 0 ]
}
secret_locked_exit() {
  vault_locked_note >&2
  if secret_batch; then exit 0; fi
  exit 1
}
secret_prepare() {   # secret_prepare <name> [<state dir>]
  local name=$1 st=${2:-${HS_STATE_DIR:-/var/lib/hs}} v=${HS_VAULT_DIR:-/var/lib/hs-vault}
  vault_configured || return 0
  [ -e "$st/$name" ] && return 0
  if ! vault_is_open; then vault_locked_note >&2; return 1; fi
  [ -L "$st/$name" ] && return 0
  mkdir -p "$st" "$v/secrets" && chmod 700 "$v/secrets" 2>/dev/null
  ln -s "$v/secrets/$name" "$st/$name"
}
