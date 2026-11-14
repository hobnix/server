# shellcheck shell=bash
# Where a share lives: on a data pool (legacy name bulk) or on an apps pool (legacy name fast). ONE place, sourced, no output of its own.
# A tier is a pool name (scripts/lib/pools.sh); without a `pools` line the pools are bulk and fast.
# Sourced:   . "$(dirname "$0")/lib/sharepath.sh"
#
#   share_tiers                the data pools, then the apps pools that exist (dataset <pool> or a folder <root>/shares|sensitive; bulk always)
#   share_root <tier>          /bulk | /fast (knobs HS_BULK, HS_FAST) | pool_root <pool>
#   share_pool_role <pool>     data | apps
#   share_pool_kind <pool>     zfs | snapraid (an apps pool is always zfs; legacy bulk: the file /etc/hs/bulk-type)
#   share_dir <share>          the folder: the first of <pool>/shares, <pool>/sensitive over the tiers that holds <share> (exit 1: none)
#   share_kind <share>         shares | sensitive
#   share_tier <share>         the pool name (legacy: bulk | fast)
#   share_dataset <share>      zfs dataset <pool>/<kind>/<share> (exit 1 on a snapraid pool)
#   share_kind_of_path <path>  shares | sensitive | other
#   share_name_taken <share>   exit 0 when a folder of that name exists in any tier (case-insensitive) or Samba has the share
# A share on an apps pool is a plain ZFS dataset <pool>/<kind>/<name> mounted at /<pool>/<kind>/<name>.
# Test knobs: HS_BULK, HS_FAST, HS_POOLS_ROOT, HS_MACHINE_FILE, HS_ZFS, HS_NET, HS_BULK_TYPE_FILE.

# shellcheck source=scripts/lib/pools.sh
. "${BASH_SOURCE[0]%/*}/pools.sh"

share_root() {
  case "$1" in bulk|fast) ;; *) _pools_load ;; esac
  case "$1" in
    bulk) printf '%s\n' "${HS_BULK:-/bulk}" ;;
    fast) printf '%s\n' "${HS_FAST:-/fast}" ;;
    *) pool_root "$1" ;;
  esac
}

_share_legacy() { _pools_load; [ "$_HS_POOLS_SOURCE" = legacy ]; }

share_pool_role() { pool_role "$1"; }

share_pool_kind() {   # share_pool_kind <pool>
  if [ "$(pool_role "$1" 2>/dev/null || true)" = apps ]; then printf 'zfs\n'; return 0; fi
  if _share_legacy && [ "$1" = bulk ]; then
    if [ "$(cat "${HS_BULK_TYPE_FILE:-/etc/hs/bulk-type}" 2>/dev/null || echo zfs)" = snapraid ]; then printf 'snapraid\n'; else printf 'zfs\n'; fi
    return 0
  fi
  pool_kind "$1"
}

_share_pools() { _pools_load; pool_names data; pool_names apps; }

share_tiers() {
  local p f
  _pools_load
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ "$(pool_role "$p")" = data ]; then printf '%s\n'  "$p"; continue; fi
    f=$(share_root "$p")
    if "${HS_ZFS:-zfs}" list -H -o name "$p" >/dev/null 2>&1 || [ -d "$f/shares" ] || [ -d "$f/sensitive" ]; then printf '%s\n' "$p"; fi
  done < <(_share_pools)
}

share_dir() {   # share_dir <share>
  local tier parent d
  _pools_load
  while IFS= read -r tier; do
    [ -n "$tier" ] || continue
    for parent in shares sensitive; do
      d="$(share_root "$tier")/$parent/$1"
      if [ -d "$d" ]; then printf '%s\n' "$d"; return 0; fi
    done
  done < <(_share_pools)
  return 1
}

share_kind_of_path() {   # share_kind_of_path <path>
  local tier r
  _pools_load
  while IFS= read -r tier; do
    [ -n "$tier" ] || continue
    r=$(share_root "$tier")
    case "$1" in
      "$r"/shares/*) printf 'shares\n'; return 0 ;;
      "$r"/sensitive/*) printf 'sensitive\n'; return 0 ;;
    esac
  done < <(_share_pools)
  printf 'other\n'
}

share_kind() {   # share_kind <share>
  local d
  d=$(share_dir "$1") || return 1
  share_kind_of_path "$d"
}

share_tier() {   # share_tier <share>
  local d tier
  _pools_load
  d=$(share_dir "$1") || return 1
  while IFS= read -r tier; do
    [ -n "$tier" ] || continue
    case "$d" in "$(share_root "$tier")"/*) printf '%s\n' "$tier"; return 0 ;; esac
  done < <(_share_pools)
  return 1
}

share_dataset() {   # share_dataset <share>
  local tier kind
  tier=$(share_tier "$1") || return 1
  kind=$(share_kind "$1") || return 1
  if [ "$(share_pool_kind "$tier")" = snapraid ]; then return 1; fi
  printf '%s/%s/%s\n' "$tier" "$kind" "$1"
}

share_name_taken() {   # share_name_taken <share>
  local tier parent d f n lc=${1,,}
  _pools_load
  while IFS= read -r tier; do
    [ -n "$tier" ] || continue
    for parent in shares sensitive; do
      d="$(share_root "$tier")/$parent"
      [ -d "$d" ] || continue
      for f in "$d"/*; do
        [ -e "$f" ] || continue
        n=${f##*/}
        [ "${n,,}" = "$lc" ] && return 0
      done
    done
  done < <(_share_pools)
  # read once: grep -q on a pipe would end the producer early (pipefail)
  local listed
  listed=$("${HS_NET:-net}" conf listshares 2>/dev/null || true)
  awk -v n="$1" 'tolower($0) == tolower(n) { f = 1 } END { exit !f }' <<<"$listed"
}
