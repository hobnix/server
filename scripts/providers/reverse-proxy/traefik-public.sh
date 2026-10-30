#!/usr/bin/env bash
# Provider "reverse-proxy", variant traefik-public: the PUBLIC routes on the gateway proxy, entrypoint public-tunnel, which only the
# cloudflared container may reach (capabilities/gateway/NOTES.md, .work/services-paths/spec-phase2.md). Same contract as zoraxy.sh, but a
# host file is written WHOLE from a host spec (a single route written without the auth of its service would skip the login):
#   traefik-public.sh info             name, public (yes), domains (proxyDomains), mode (api), features (paths,headers,auth), container (-), note
#   traefik-public.sh list             host<TAB>path<TAB>target<TAB>id for every public route (id = the file name)
#   traefik-public.sh owned-list       host<TAB>path of the same: every pub-*.yml is hs's
#   traefik-public.sh specs            host<TAB>spec line for every pub-*.yml (what hs wrote; services.py compares it with what it wants)
#   traefik-public.sh check            ok
#   traefik-public.sh ensure-host H F  write pub-<H>.yml from the host spec file F (empty F: delete the file); exit 0, 1 on an error
#   traefik-public.sh ensure|remove    refused (exit 1): hs services apply writes whole hosts
#   traefik-public.sh adopt H P        exit 0
#   traefik-public.sh login-check F    exit 1: no login needed
# A file is rendered by scripts/gateway_render.py, written to tmp/ and moved in (mv is atomic: one broken file would freeze the directory).
# Test knobs: HS_GATEWAY_DIR (default /var/lib/hs-gateway), HS_GATEWAY_UNIT_STATE, HS_ETC_DIR (gateway-public: tunnel=<port>),
# HS_SETTINGS_DIR, HS_PYTHON.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../../lib/setting.sh"
gdir=${HS_GATEWAY_DIR:-/var/lib/hs-gateway}
routes_dir=$gdir/routes
tmp_dir=$gdir/tmp
etc=${HS_ETC_DIR:-/etc/hs}
py=${HS_PYTHON:-python3}; command -v "$py" >/dev/null 2>&1 || py=python
render() { PYTHONUTF8=1 "$py" "$here/../../gateway_render.py" "$@"; }
tab=$'\t'
umask 027

unit_state() { if [ -n "${HS_GATEWAY_UNIT_STATE:-}" ]; then cat "$HS_GATEWAY_UNIT_STATE" 2>/dev/null || echo unknown; else systemctl is-active traefik 2>/dev/null || true; fi; }
tunnel_port() { sed -n 's/^tunnel=\([0-9]*\)$/\1/p' "$etc/gateway-public" 2>/dev/null | head -n1; }
file_of() { printf '%s/pub-%s.yml' "$routes_dir" "$1"; }
refuse="traefik-public writes whole hosts: hs services apply"

case "${1:-}" in
  info)
    printf 'name\ttraefik-public\npublic\tyes\n'
    printf 'domains\t%s\n' "$(setting_get proxyDomains 2>/dev/null || true)"
    printf 'mode\tapi\nfeatures\tpaths,headers,auth\ncontainer\t-\n'
    case "$(unit_state)" in active) ;; *) printf 'note\tTraefik is not running\n' ;; esac
    case "$(tunnel_port)" in ''|0) printf 'note\tno public entrypoint: hs config set gatewayTunnelPort 8081, then hs rebuild\n' ;; esac ;;
  list) render read "$routes_dir" --prefix pub- | awk -F"$tab" '{ print $1 "\t" $2 "\t" $3 "\t" $4 }' ;;
  owned-list) render read "$routes_dir" --prefix pub- | awk -F"$tab" '{ print $1 "\t" $2 }' ;;
  specs) render specs "$routes_dir" ;;
  check) echo ok ;;
  ensure-host)
    host=${2:-}; spec=${3:-}
    [ -n "$host" ] && [ -f "$spec" ] || { echo "usage: traefik-public.sh ensure-host <host> <specfile>" >&2; exit 1; }
    if [ ! -s "$spec" ]; then rm -f "$(file_of "$host")"; echo removed; exit 0; fi
    case "$(tunnel_port)" in ''|0) echo "no public entrypoint: hs config set gatewayTunnelPort 8081, then hs rebuild" >&2; exit 1 ;; esac
    mkdir -p "$tmp_dir" "$routes_dir" 2>/dev/null
    tmp=$(mktemp "$tmp_dir/pub-$host.XXXXXX") || { echo "could not write the route file of $host" >&2; exit 1; }
    if ! render public "$host" "$spec" >"$tmp"; then rm -f "$tmp"; echo "could not render the route file of $host" >&2; exit 1; fi
    chmod 0640 "$tmp" && mv -f "$tmp" "$(file_of "$host")" || { rm -f "$tmp"; echo "could not write the route file of $host" >&2; exit 1; }
    echo written ;;
  ensure|remove) echo "$refuse" >&2; exit 1 ;;
  adopt) exit 0 ;;
  login-check) echo "no login needed" >&2; exit 1 ;;
  *) echo "usage: traefik-public.sh info|list|owned-list|specs|check|ensure-host <host> <specfile>|adopt <host> <path>|login-check <file>" >&2; exit 1 ;;
esac
