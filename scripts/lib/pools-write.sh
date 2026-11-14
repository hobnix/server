# shellcheck shell=bash
# The one writer of the `pools` line of machine.toml (the readers are in lib/pools.sh). Sourced by the scripts that change pools.
#   pools_add_row <name> <role> <kind>   add or overwrite one row (one line, sorted by name); exit 1 without a pools line
# The caller says when it takes effect (effect_say rebuild, lib/effect.sh).

# shellcheck source=scripts/lib/pools.sh
. "${BASH_SOURCE[0]%/*}/pools.sh"
# shellcheck source=scripts/lib/effect.sh
. "${BASH_SOURCE[0]%/*}/effect.sh"

pools_add_row() {   # pools_add_row <name> <role> <kind>; the cache is cleared
  local rows
  case "$2" in data|apps) ;; *) return 1 ;; esac
  case "$3" in zfs|snapraid) ;; *) return 1 ;; esac
  pool_name_ok "$1" || return 1
  _pools_load
  [ "$_HS_POOLS_SOURCE" = config ] || return 1
  rows=$({ pools_rows | awk -F'\t' -v n="$1" '$1 != n'; printf '%s\t%s\t%s\n' "$1" "$2" "$3"; } | sort)
  machine_set pools "$(pools_format_rows <<<"$rows")" pool-create >/dev/null || return 1
  _HS_POOLS_LOADED=
}
