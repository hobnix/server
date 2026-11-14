# shellcheck shell=bash
# The pools of this server, read from the `pools` table of machine.toml (read-only; no output of its own, no zpool/lsblk).
# Without a `pools` line the layout is the legacy one: `bulk` (role data, kind = bulkType) and `fast` (role apps, zfs).
# `pools = {}` is a real answer: no pool at all (never legacy).
#
#   pools_rows               name<TAB>role<TAB>kind per pool, sorted by name, no empty field (cached in _HS_POOLS_ROWS)
#   pools_source             config | legacy
#   pool_names [role]        names, one per line (empty output = none; exit 0)
#   pool_exists <name>       exit 0/1
#   pool_role <name>         role; exit 1 when unknown
#   pool_kind <name>         kind (zfs | snapraid); exit 1 when unknown
#   pool_default <role>      first name of that role; exit 1 when none
#   pool_root <name>         ${HS_POOLS_ROOT}/<name>
#   pool_mounted <name>      exit 0 when pool_root is a mount point
#   pool_name_ok <name>      exit 0 when the name is allowed for a new pool (^[a-z][a-z0-9]{0,11}$, not a reserved word)
#   pools_format_rows        stdin: name<TAB>role<TAB>kind lines; stdout: the value `{ name = { role = "..", kind = ".." }, ... }`
#   pools_add_row <n> <r> <k>  add or overwrite one row in the `pools` line (machine_set, one line, sorted); exit 1 without a `pools` line
# Roles: data, apps. Kinds: zfs, snapraid.
# Test knobs: HS_MACHINE_FILE, HS_BULK_TYPE_FILE, HS_POOLS_ROOT, HS_MOUNTPOINT, HS_PYTHON.

# shellcheck source=scripts/lib/machine.sh
. "${BASH_SOURCE[0]%/*}/machine.sh"

_HS_POOLS_ROWS=
_HS_POOLS_SOURCE=
_HS_POOLS_LOADED=

_POOLS_PY='
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    d = {}
if isinstance(d, dict):
    for name in sorted(d):
        v = d[name]
        if not isinstance(v, dict):
            continue
        role, kind = v.get("role"), v.get("kind")
        if role in ("data", "apps") and kind in ("zfs", "snapraid"):
            print("%s\t%s\t%s" % (name, role, kind))
'

_pools_load() {
  [ -n "$_HS_POOLS_LOADED" ] && return 0
  local json rc=0 py=${HS_PYTHON:-python3} kind f
  # exit 1 = no file or not set; `pools = {}` prints {} (exit 0) and must give no rows
  json=$(machine_get_json pools 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ] || [ "$json" = null ]; then
    kind=$(machine_get bulkType 2>/dev/null | head -n1) || kind=
    if [ -z "$kind" ]; then
      f=${HS_BULK_TYPE_FILE:-/etc/hs/bulk-type}
      [ -r "$f" ] && IFS= read -r kind <"$f" || true
    fi
    case "$kind" in zfs|snapraid) ;; *) kind=zfs ;; esac
    _HS_POOLS_ROWS=$(printf 'bulk\tdata\t%s\nfast\tapps\tzfs\n' "$kind" | sort)
    _HS_POOLS_SOURCE=legacy
  else
    command -v "$py" >/dev/null 2>&1 || py=python
    _HS_POOLS_ROWS=$(printf '%s' "$json" | PYTHONUTF8=1 "$py" -c "$_POOLS_PY" 2>/dev/null | tr -d '\r') || _HS_POOLS_ROWS=
    _HS_POOLS_SOURCE=config
  fi
  _HS_POOLS_LOADED=1
}

pools_rows() { _pools_load; [ -z "$_HS_POOLS_ROWS" ] || printf '%s\n' "$_HS_POOLS_ROWS"; }
pools_source() { _pools_load; printf '%s\n' "$_HS_POOLS_SOURCE"; }
pool_names() {   # pool_names [role]
  _pools_load
  [ -z "$_HS_POOLS_ROWS" ] || awk -F'\t' -v r="${1:-}" 'r == "" || $2 == r { print $1 }' <<<"$_HS_POOLS_ROWS"
}
_pool_field() {   # _pool_field <name> <column>
  _pools_load
  local out
  out=$(awk -F'\t' -v n="$1" -v c="$2" '$1 == n { print $c; exit }' <<<"$_HS_POOLS_ROWS")
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}
pool_exists() { _pool_field "$1" 1 >/dev/null; }
pool_role() { _pool_field "$1" 2; }
pool_kind() { _pool_field "$1" 3; }
pool_default() {   # pool_default <role>
  local n
  n=$(pool_names "$1" | head -n1)
  [ -n "$n" ] || return 1
  printf '%s\n' "$n"
}
pool_root() { printf '%s/%s\n' "${HS_POOLS_ROOT:-}" "$1"; }
pool_mounted() { "${HS_MOUNTPOINT:-mountpoint}" -q "$(pool_root "$1")"; }
pool_name_ok() {
  [[ $1 =~ ^[a-z][a-z0-9]{0,11}$ ]] || return 1
  case " mirror raidz raidz1 raidz2 raidz3 draid spare log cache special dedup default none system incus boot nix etc var home root tmp usr bin sbin lib lib64 srv mnt run proc sys dev opt media " in
    *" $1 "*) return 1 ;;
  esac
  return 0
}
pools_format_rows() {
  local n r k inner=
  while IFS=$'\t' read -r n r k; do
    [ -n "$n" ] || continue
    inner+="${inner:+, }$n = { role = \"$r\", kind = \"$k\" }"
  done
  printf '{ %s }\n' "$inner"
}
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
