# shellcheck shell=bash
# Language of what the hs commands print. Sourced by lib/ui.sh, so every script has it.
#
# The language comes from machine.toml (`language = "de"` -> /etc/hs/language), or from the
# environment for one call:  HS_LANG=de hs rebuild.   English is the default and the fallback.
# Commands, options and file names are never translated, only the sentences around them.
#
# How a text is translated: English is the key. scripts/lib/i18n/<lang>.tsv has one line per text,
# English <TAB> translation; \n stands for a line break; %s and %d keep their order. A text without
# a line prints in English. In a script:
#   ok "Backup finished."                       (ui.sh functions look the text up by themselves)
#   say "Plain line, like echo"
#   die "Not set up yet."
#   warn "$(t 'Disk %s is full (%s%%)' "$name" "$pct")"      (a text with values: write it as a
#                                                             format in single quotes, then t fills it)
# Machine-readable output (lists the interface reads) is never translated.

hs_lang=${HS_LANG:-}
. "$(dirname "${BASH_SOURCE[0]}")/setting.sh"
[ -n "$hs_lang" ] || hs_lang=$(setting_get language 2>/dev/null || true)
hs_lang=${hs_lang:-en}
declare -gA _T=()

_i18n_read() {   # _i18n_read <file>: the lines of one translation file
  local k v
  [ -r "$1" ] || return 0
  while IFS=$'\t' read -r k v; do
    [ -n "$k" ] && [ "${k:0:1}" != "#" ] || continue
    _T[$k]=${v//\\n/$'\n'}
  done < "$1"
}
_i18n_load() {
  local d n
  [ "$hs_lang" != en ] || return 0
  d=$(dirname "${BASH_SOURCE[0]}")
  _i18n_read "$d/i18n/$hs_lang.tsv"
  # the translations of the extension packages that are on (capabilities/<name>/i18n/<lang>.tsv, docs/PLAN-extensions.md)
  [ -f "$d/registry-load.sh" ] || return 0
  . "$d/registry-load.sh"
  while IFS= read -r n; do
    ext_package_on "$n" || continue
    _i18n_read "$(ext_package_dir "$n")/i18n/$hs_lang.tsv"
  done < <(ext_package_names)
}
_i18n_load

_tr() {   # _tr <text>: the translation, or the text itself
  local s=$*
  [ -n "$s" ] || return 0
  printf '%s' "${_T[$s]:-$s}"
}
t() {     # t <format> [values...]: translated format, filled in
  local f=$1
  shift
  [ -z "$f" ] || f=${_T[$f]:-$f}
  if [ $# -eq 0 ]; then printf '%s' "$f"; else printf -- "$f" "$@"; fi
}
say() { printf '%s\n' "$(_tr "$*")"; }
