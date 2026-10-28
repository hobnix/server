#!/usr/bin/env bash
# Provider "reverse-proxy", variant traefik: the LOCAL slot (capabilities/gateway/NOTES.md). Same contract as zoraxy.sh:
#   traefik.sh info             name, public (always no), domains (the local domain, <site>.<realm>, or empty), mode (api), note
#   traefik.sh list             host<TAB>path<TAB>target<TAB>id for every local route (id = the file name)
#   traefik.sh owned-list       host<TAB>path of the same: every local-*.yml is hs's
#   traefik.sh check            ok
#   traefik.sh ensure H P T     make the route; exit 0, 1 on a render or write error
#   traefik.sh remove H P       drop the route; the last route of a host deletes its file; exit 0 also when it is gone
#   traefik.sh adopt H P        exit 0 (files made by hand stay "unmanaged")
#   traefik.sh login-check F    exit 1: no login needed
# A route is a file local-<host>.yml in $HS_GATEWAY_DIR/routes, rendered by scripts/gateway_render.py, written to tmp/ and moved in
# (mv is atomic: Traefik never sees half a file, and one broken file would freeze the whole directory).
# Test knobs: HS_GATEWAY_DIR (default /var/lib/hs-gateway), HS_GATEWAY_UNIT_STATE, HS_MACHINE_FILE, HS_SITE_NAME_FILE, HS_PYTHON.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../../lib/machine.sh"
. "$here/../../lib/localdomain.sh"
gdir=${HS_GATEWAY_DIR:-/var/lib/hs-gateway}
routes_dir=$gdir/routes
tmp_dir=$gdir/tmp
py=${HS_PYTHON:-python3}; command -v "$py" >/dev/null 2>&1 || py=python
render() { PYTHONUTF8=1 "$py" "$here/../../gateway_render.py" "$@"; }
tab=$'\t'
umask 027

unit_state() { if [ -n "${HS_GATEWAY_UNIT_STATE:-}" ]; then cat "$HS_GATEWAY_UNIT_STATE" 2>/dev/null || echo unknown; else systemctl is-active traefik 2>/dev/null || true; fi; }
file_of() { printf '%s/local-%s.yml' "$routes_dir" "$1"; }

# routes of one host as path=target arguments, one per line
host_routes() { render read "$routes_dir" | awk -F"$tab" -v h="$1" '$1 == h { print $2 "=" $3 }'; }

# write_host <host> <path=target>...: render, write into tmp/, move in; no routes = delete the file
write_host() {
  local host=$1 tmp; shift
  if [ $# -eq 0 ]; then rm -f "$(file_of "$host")"; return 0; fi
  mkdir -p "$tmp_dir" "$routes_dir" 2>/dev/null
  tmp=$(mktemp "$tmp_dir/local-$host.XXXXXX") || return 1
  if ! render local "$host" "$@" >"$tmp"; then rm -f "$tmp"; return 1; fi
  chmod 0640 "$tmp" && mv -f "$tmp" "$(file_of "$host")" || { rm -f "$tmp"; return 1; }
}

case "${1:-}" in
  info)
    printf 'name\ttraefik\npublic\tno\n'
    printf 'domains\t%s\n' "$(local_domain)"
    printf 'mode\tapi\n'
    case "$(unit_state)" in active) ;; *) printf 'note\tTraefik is not running\n' ;; esac ;;
  list) render read "$routes_dir" | awk -F"$tab" '{ print $1 "\t" $2 "\t" $3 "\t" $4 }' ;;
  owned-list) render read "$routes_dir" | awk -F"$tab" '{ print $1 "\t" $2 }' ;;
  check) echo ok ;;
  ensure)
    host=${2:-}; path=${3:-/}; target=${4:-}
    [ -n "$host" ] && [ -n "$target" ] || { echo "usage: traefik.sh ensure <host> <path> <target>" >&2; exit 1; }
    args=(); while IFS= read -r r; do [ -z "$r" ] || [ "${r%%=*}" = "$path" ] || args+=("$r"); done < <(host_routes "$host")
    args+=("$path=$target")
    write_host "$host" "${args[@]}" || { echo "could not write the route file of $host" >&2; exit 1; }
    echo "added" ;;
  remove)
    host=${2:-}; path=${3:-/}
    [ -n "$host" ] || { echo "usage: traefik.sh remove <host> <path>" >&2; exit 1; }
    args=(); while IFS= read -r r; do [ -z "$r" ] || [ "${r%%=*}" = "$path" ] || args+=("$r"); done < <(host_routes "$host")
    write_host "$host" "${args[@]+"${args[@]}"}" || { echo "could not write the route file of $host" >&2; exit 1; }
    echo "removed" ;;
  adopt) exit 0 ;;
  login-check) echo "no login needed" >&2; exit 1 ;;
  *) echo "usage: traefik.sh info|list|check|owned-list|adopt <host> <path>|ensure <host> <path> <target>|remove <host> <path>|login-check <file>" >&2; exit 1 ;;
esac
