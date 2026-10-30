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
#   traefik-public.sh refresh [--check]  re-render the files whose entrypoints (mode) no longer match the settings: host<TAB>new mode
#                                      (- = no public entrypoint now, file left as is); --check writes nothing
#   traefik-public.sh ensure|remove    refused (exit 1): hs services apply writes whole hosts
#   traefik-public.sh adopt H P        exit 0
#   traefik-public.sh login-check F    exit 1: no login needed
# A file is rendered by scripts/gateway_render.py, written to tmp/ and moved in (mv is atomic: one broken file would freeze the directory).
# A host is served per mode: tunnel (tunnel=<port> in gateway-public), direct (acme=staging|production there AND the host lies under a
# domain of the setting gatewayDirectDomains; empty = no domain) and http (direct and http=<port> not 0 and not 80). A tunnel-only setup
# renders exactly as before: no d- routers, no certificate resolver.
# Test knobs: HS_GATEWAY_DIR (default /var/lib/hs-gateway), HS_GATEWAY_UNIT_STATE, HS_ETC_DIR (gateway-public: https=, http=, tunnel=,
# acme=), HS_SETTINGS_DIR (gatewayDirectDomains, proxyDomains), HS_PYTHON.
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
gp_get() { sed -n "s/^$1=\(.*\)\$/\1/p" "$etc/gateway-public" 2>/dev/null | head -n1; }
tunnel_port() { gp_get tunnel; }
acme_on() { case "$(gp_get acme)" in ''|off) return 1 ;; *) return 0 ;; esac; }
under() { [ "$1" = "$2" ] || case "$1" in *."$2") return 0 ;; *) return 1 ;; esac; }
pt_host() {   # 0 when the host lies under a passthrough domain (SNI on public-https: no direct route there; the tunnel is unaffected)
  local d
  while IFS= read -r d; do [ -n "$d" ] && under "$1" "$d" && return 0; done < <(render ptdomains "$routes_dir" 2>/dev/null)
  return 1
}
direct_host() {   # 0 when the host lies under a domain of gatewayDirectDomains (and not under a passthrough domain)
  local d; acme_on || return 1
  pt_host "$1" && return 1
  while IFS= read -r d; do [ -n "$d" ] && under "$1" "$d" && return 0; done < <(setting_get gatewayDirectDomains 2>/dev/null | tr ',' '\n')
  return 1
}
mode_of() {   # the entrypoint modes of a host, comma list, empty = none
  local m=
  case "$(tunnel_port)" in ''|0) ;; *) m=tunnel ;; esac
  if direct_host "$1"; then
    m=${m:+$m,}direct
    case "$(gp_get http)" in ''|0|80) ;; *) m=$m,http ;; esac
  fi
  printf '%s' "$m"
}
write_host() {   # <host> <specfile> <mode>: render to tmp/ and move in; 2 = could not render, 1 = could not write
  local tmp
  mkdir -p "$tmp_dir" "$routes_dir" 2>/dev/null
  tmp=$(mktemp "$tmp_dir/pub-$1.XXXXXX") || return 1
  if ! render public "$1" "$2" --mode "$3" >"$tmp"; then rm -f "$tmp"; return 2; fi
  chmod 0640 "$tmp" && mv -f "$tmp" "$(file_of "$1")" || { rm -f "$tmp"; return 1; }
}
file_of() { printf '%s/pub-%s.yml' "$routes_dir" "$1"; }
refuse="traefik-public writes whole hosts: hs services apply"

case "${1:-}" in
  info)
    printf 'name\ttraefik-public\npublic\tyes\n'
    printf 'domains\t%s\n' "$(setting_get proxyDomains 2>/dev/null || true)"
    printf 'mode\tapi\nfeatures\tpaths,headers,auth\ncontainer\t-\n'
    mp=
    case "$(tunnel_port)" in ''|0) ;; *) mp=tunnel ;; esac
    acme_on && [ -n "$(setting_get gatewayDirectDomains 2>/dev/null | tr -d ' ,')" ] && mp=${mp:+$mp,}direct
    printf 'mode-public\t%s\n' "${mp:--}"
    case "$(unit_state)" in active) ;; *) printf 'note\tTraefik is not running\n' ;; esac
    [ -n "$mp" ] || printf 'note\tno public entrypoint: set gatewayTunnelPort (tunnel), or gatewayPublicHttps, gatewayAcmeEmail and gatewayDirectDomains (direct), then hs rebuild\n'
    n=$(bash "$0" refresh --check 2>/dev/null | awk -F'\t' '$2 != "-"' | wc -l | tr -d ' ')
    [ "${n:-0}" = 0 ] || printf 'note\t%s route files use old entrypoints: hs services apply\n' "$n" ;;
  list) render read "$routes_dir" --prefix pub- | awk -F"$tab" '{ print $1 "\t" $2 "\t" $3 "\t" $4 }' ;;
  owned-list) render read "$routes_dir" --prefix pub- | awk -F"$tab" '{ print $1 "\t" $2 }' ;;
  specs) render specs "$routes_dir" ;;
  check) echo ok ;;
  ensure-host)
    host=${2:-}; spec=${3:-}
    [ -n "$host" ] && [ -f "$spec" ] || { echo "usage: traefik-public.sh ensure-host <host> <specfile>" >&2; exit 1; }
    if [ ! -s "$spec" ]; then rm -f "$(file_of "$host")"; echo removed; exit 0; fi
    m=$(mode_of "$host")
    if [ -z "$m" ]; then
      if pt_host "$host"; then echo "$host is forwarded by passthrough (hs ext passthrough list) and has no tunnel" >&2
      else echo "no public entrypoint: set gatewayTunnelPort (tunnel), or gatewayPublicHttps, gatewayAcmeEmail and gatewayDirectDomains (direct), then hs rebuild" >&2; fi
      exit 1
    fi
    write_host "$host" "$spec" "$m"
    case $? in 0) ;; 2) echo "could not render the route file of $host" >&2; exit 1 ;; *) echo "could not write the route file of $host" >&2; exit 1 ;; esac
    echo written ;;
  refresh)
    check=false; [ "${2:-}" = "--check" ] && check=true
    st=$(mktemp) || exit 1; trap 'rm -f "$st"' EXIT
    render specs "$routes_dir" >"$st"
    while IFS="$tab" read -r host cur; do
      [ -n "$host" ] || continue
      m=$(mode_of "$host")
      if [ -z "$m" ]; then printf '%s\t-\n' "$host"; continue; fi
      [ "$m" != "$cur" ] || continue
      if ! $check; then
        sp=$(mktemp) || exit 1
        awk -F"$tab" -v h="$host" '$1 == h { sub(/^[^\t]*\t/, ""); print }' "$st" >"$sp"
        write_host "$host" "$sp" "$m"; rc=$?
        rm -f "$sp"
        [ "$rc" = 0 ] || { echo "could not rewrite the route file of $host" >&2; continue; }
      fi
      printf '%s\t%s\n' "$host" "$m"
    done < <(render modes "$routes_dir")
    exit 0 ;;
  ensure|remove) echo "$refuse" >&2; exit 1 ;;
  adopt) exit 0 ;;
  login-check) echo "no login needed" >&2; exit 1 ;;
  *) echo "usage: traefik-public.sh info|list|owned-list|specs|check|ensure-host <host> <specfile>|refresh [--check]|adopt <host> <path>|login-check <file>" >&2; exit 1 ;;
esac
