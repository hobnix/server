# shellcheck shell=bash
# The text helpers of the hs commands. Sourced by lib/ui.sh, so every script has them.
#
# The hs commands print English only (ADR 0025). Translation lives in the web interface (web/src/i18n.js).
# `_tr`, `t` and `say` stay as pass-through helpers because packages call them (ADR 0008, rule 4); they are
# deprecated: write the English text with printf/echo-style helpers of ui.sh (`ok`, `note`, `warn`, `fail`, ...)
# and use `t` only to fill a format. HS_LANG is accepted and ignored. The `language` setting of machine.toml
# only sets the default language of the web interface.
#   ok "Backup finished."
#   say "Plain line, like echo"
#   warn "$(t 'Disk %s is full (%s%%)' "$name" "$pct")"
# Machine-readable output (lists the interface reads) is never translated.

[ -z "${_hs_i18n_loaded:-}" ] || return 0
_hs_i18n_loaded=1

. "${BASH_SOURCE[0]%/*}/setting.sh"   # setting_get: ui.sh and the scripts that source it rely on it being loaded
hs_lang=en   # deprecated: always en (kept so a package that reads it still works)
declare -gA _T=()   # deprecated: always empty

_i18n_read() { :; }   # deprecated no-op: a package's i18n/<lang>.tsv is no longer read

_tr() {   # _tr <text>: the text itself (deprecated pass-through)
  local s=$*
  [ -n "$s" ] || return 0
  printf '%s' "$s"
}
t() {     # t <format> [values...]: the format, filled in
  local f=$1
  shift
  if [ $# -eq 0 ]; then printf '%s' "$f"; else printf -- "$f" "$@"; fi
}
say() { printf '%s\n' "$*"; }
