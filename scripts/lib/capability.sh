# shellcheck shell=bash
# Which capabilities are switched on (docs/PLAN-modular-core.md, step 3). A capability is on when
#   - its name is in /etc/hs/capabilities, one name per line, which Nix writes from machine.toml (`capabilities`, plus the old
#     switches such as `metrics = true`), or
#   - one of the runtime settings it is implied by is set (`implied_by` in capabilities/<name>/capability.toml, copied to
#     scripts/lib/capabilities.tsv by scripts/schema-gen.py): vpsHost or proxyStatusUrl switch "vps" on, no rebuild, or
#   - its name is in $HS_STATE_DIR/capabilities-on (/var/lib/hs/capabilities-on): `hs ext enable <package>` writes it for a package
#     without a Nix module, so it works at once; `hs ext disable` writes capabilities-off, which wins over everything above.
#     machine.toml gets the same change, so after the next `hs rebuild` the overlay says nothing new (docs/PLAN-extensions.md).
#
#   capability_on <name>     true when the capability is on
#   capability_list          the names that are on, one per line
#
# Test knobs: HS_CAPABILITIES_FILE, HS_CAPABILITIES_TSV (and the knobs of setting.sh).
. "$(dirname "${BASH_SOURCE[0]}")/setting.sh"

capability_file() { echo "${HS_CAPABILITIES_FILE:-/etc/hs/capabilities}"; }
_capability_tsv() { echo "${HS_CAPABILITIES_TSV:-$(dirname "${BASH_SOURCE[0]}")/capabilities.tsv}"; }

_capability_overlay() { echo "${HS_STATE_DIR:-/var/lib/hs}/capabilities-$1"; }

capability_on() {
  local tsv s v tab=$'\t'
  if grep -qxF -- "$1" "$(_capability_overlay off)" 2>/dev/null; then return 1; fi
  grep -qxF -- "$1" "$(capability_file)" 2>/dev/null && return 0
  grep -qxF -- "$1" "$(_capability_overlay on)" 2>/dev/null && return 0
  tsv=$(_capability_tsv)
  [ -r "$tsv" ] || return 1
  for s in $(awk -F"$tab" -v n="$1" '$1 == n { gsub(",", " ", $2); print $2 }' "$tsv"); do
    v=$(setting_get "$s" 2>/dev/null) || continue
    case "$v" in ""|false|0) ;; *) return 0 ;; esac
  done
  return 1
}

capability_list() {
  local n tab=$'\t'
  { cat "$(capability_file)" "$(_capability_overlay on)" 2>/dev/null || true
    [ ! -r "$(_capability_tsv)" ] || awk -F"$tab" '!/^#/ && $1 != "" { print $1 }' "$(_capability_tsv)"; } | sort -u | while read -r n; do
    ! capability_on "$n" || echo "$n"
  done
}
