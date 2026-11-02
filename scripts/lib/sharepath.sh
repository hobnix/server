# shellcheck shell=bash
# Where a share lives: on the disks (bulk) or on the SSD pool (fast). ONE place, sourced, no output of its own.
# Sourced:   . "$(dirname "$0")/lib/sharepath.sh"
#
#   share_tiers                prints "bulk" and, when the dataset fast exists or /fast/shares|/fast/sensitive is a folder, "fast"
#   share_root <tier>          /bulk | /fast
#   share_dir <share>          the folder: the first of bulk/shares, bulk/sensitive, fast/shares, fast/sensitive that holds <share> (exit 1: none)
#   share_kind <share>         shares | sensitive
#   share_tier <share>         bulk | fast
#   share_dataset <share>      zfs dataset bulk/<kind>/<share> or fast/<kind>/<share> (exit 1 on a snapraid bulk)
#   share_kind_of_path <path>  shares | sensitive | other
#   share_name_taken <share>   exit 0 when a folder of that name exists in any tier (case-insensitive) or Samba has the share
# A fast share is a plain ZFS dataset fast/<kind>/<name> mounted at /fast/<kind>/<name>.
# Test knobs: HS_BULK, HS_FAST, HS_ZFS, HS_NET, HS_BULK_TYPE_FILE.
share_root() { case "$1" in fast) printf '%s\n' "${HS_FAST:-/fast}" ;; *) printf '%s\n' "${HS_BULK:-/bulk}" ;; esac; }

share_tiers() {
  local f
  f=$(share_root fast)
  printf 'bulk\n'
  if "${HS_ZFS:-zfs}" list -H -o name fast >/dev/null 2>&1 || [ -d "$f/shares" ] || [ -d "$f/sensitive" ]; then printf 'fast\n'; fi
}

share_dir() {   # share_dir <share>
  local tier parent d
  for tier in bulk fast; do
    for parent in shares sensitive; do
      d="$(share_root "$tier")/$parent/$1"
      if [ -d "$d" ]; then printf '%s\n' "$d"; return 0; fi
    done
  done
  return 1
}

share_kind_of_path() {   # share_kind_of_path <path>
  case "$1" in
    "$(share_root bulk)"/shares/*|"$(share_root fast)"/shares/*) printf 'shares\n' ;;
    "$(share_root bulk)"/sensitive/*|"$(share_root fast)"/sensitive/*) printf 'sensitive\n' ;;
    *) printf 'other\n' ;;
  esac
}

share_kind() {   # share_kind <share>
  local d
  d=$(share_dir "$1") || return 1
  share_kind_of_path "$d"
}

share_tier() {   # share_tier <share>
  local d
  d=$(share_dir "$1") || return 1
  case "$d" in "$(share_root fast)"/*) printf 'fast\n' ;; *) printf 'bulk\n' ;; esac
}

share_dataset() {   # share_dataset <share>
  local tier kind
  tier=$(share_tier "$1") || return 1
  kind=$(share_kind "$1") || return 1
  if [ "$tier" = bulk ] && [ "$(cat "${HS_BULK_TYPE_FILE:-/etc/hs/bulk-type}" 2>/dev/null || echo zfs)" = snapraid ]; then return 1; fi
  printf '%s/%s/%s\n' "$tier" "$kind" "$1"
}

share_name_taken() {   # share_name_taken <share>
  local tier parent d f n lc=${1,,}
  for tier in bulk fast; do
    for parent in shares sensitive; do
      d="$(share_root "$tier")/$parent"
      [ -d "$d" ] || continue
      for f in "$d"/*; do
        [ -e "$f" ] || continue
        n=${f##*/}
        [ "${n,,}" = "$lc" ] && return 0
      done
    done
  done
  # read once: grep -q on a pipe would end the producer early (pipefail)
  local listed
  listed=$("${HS_NET:-net}" conf listshares 2>/dev/null || true)
  awk -v n="$1" 'tolower($0) == tolower(n) { f = 1 } END { exit !f }' <<<"$listed"
}
