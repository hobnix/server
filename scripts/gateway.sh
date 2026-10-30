#!/usr/bin/env bash
# help: the gateway proxy (Traefik): running, who holds the ports, local domain, wildcard DNS, routes
# help.de: der Gateway-Proxy (Traefik): läuft er, wer hält die Ports, lokale Domain, Wildcard-DNS, Routen
# args: status | routes | check | --status | --routes | --certs | --check-wildcard
# Traefik on the host gives every local service a name <label>.<site>.<realm> by Host header (capabilities/gateway/NOTES.md).
#   hs gateway status      key/value lines for people, warnings for a port held by another process, a stopped service, a wrong wildcard
#   hs gateway routes      every route: local names, passthrough domains, the web interface
#   hs gateway check       does *.<site>.<realm> point at this server; else the one DNS record a person adds on the DNS server
#   --status, --routes     the same as data (hs sys gateway status|routes): key<TAB>value / kind host path target file, `-` for empty
#   --certs                host<TAB>state<TAB>until for every host served directly: staging | default | none | ok (asked of Traefik with
#                          openssl s_client on the public https port, never read from the key store); no row without a public https port
#   --check-wildcard       no output, exit 0 = the wildcard works (the first-run checklist, scripts/setup-list.sh)
# hs never asks for the DNS administrator's password: the person types it into samba-tool. This script only CHECKS the record.
# Test knobs: HS_GATEWAY_DIR, HS_GATEWAY_UNIT_STATE, HS_GATEWAY_LISTENERS (a file in `ss -Hltnp` format), HS_GATEWAY_RESOLVE (a command that
# stands in for `getent ahostsv4 <name>`), HS_GATEWAY_RESOLV_CONF, HS_ETC_DIR, HS_HOST_IP, HS_MACHINE_FILE, HS_SITE_NAME_FILE, HS_PYTHON.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/ui.sh"
. "$here/lib/machine.sh"
. "$here/lib/localdomain.sh"
. "$here/lib/setting.sh"
gdir=${HS_GATEWAY_DIR:-/var/lib/hs-gateway}
routes_dir=$gdir/routes
etc=${HS_ETC_DIR:-/etc/hs}
py=${HS_PYTHON:-python3}; command -v "$py" >/dev/null 2>&1 || py=python
tab=$'\t'
render() { PYTHONUTF8=1 "$py" "$here/gateway_render.py" "$@"; }

usage() { say "usage: hs gateway status | routes | check"; exit 1; }

host_ip() { printf '%s' "${HS_HOST_IP:-$(ip -4 -o addr show br0 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4; exit }')}"; }
unit_state() {
  local s
  if [ -n "${HS_GATEWAY_UNIT_STATE:-}" ]; then s=$(cat "$HS_GATEWAY_UNIT_STATE" 2>/dev/null || true)
  else s=$(systemctl is-active traefik 2>/dev/null || true); fi
  case "$s" in active|inactive|failed) printf '%s' "$s" ;; *) printf 'unknown' ;; esac
}
# owner of a TCP port: traefik | free | <process>
port_owner() {
  local out name
  if [ -n "${HS_GATEWAY_LISTENERS:-}" ]; then
    out=$(awk -v p=":$1" '{ n = length($4); if (substr($4, n - length(p) + 1) == p) print }' "$HS_GATEWAY_LISTENERS" 2>/dev/null | head -n 1 || true)
  else
    out=$(ss -Hltnp "sport = :$1" 2>/dev/null | head -n 1 || true)
  fi
  [ -n "$out" ] || { printf 'free'; return; }
  name=$(sed -n 's/.*users:(("\([^"]*\)".*/\1/p' <<<"$out")
  printf '%s' "${name:-unknown}"
}
# the public ports from /etc/hs/gateway-public (https=<n>, http=<n>, tunnel=<n>)
public_port() { local v; v=$(sed -n "s/^$1=//p" "$etc/gateway-public" 2>/dev/null | head -n 1 || true); printf '%s' "${v:-0}"; }
count_lines() { local n; n=$(grep -c . <<<"$1" || true); printf '%s' "${n:-0}"; }

domain=$(local_domain)

# wildcard state: ok | wrong | missing | -
wildcard_state() {
  local ip name got
  [ -n "$domain" ] || { printf -- '-'; return; }
  ip=$(host_ip)
  name="hs-check-$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || echo 0badc0de).$domain"
  if [ -n "${HS_GATEWAY_RESOLVE:-}" ]; then got=$("$HS_GATEWAY_RESOLVE" "$name" 2>/dev/null || true)
  else got=$(getent ahostsv4 "$name" 2>/dev/null || true); fi
  got=$(awk 'NF { print $1; exit }' <<<"$got")
  if [ -z "$got" ]; then printf 'missing'
  elif [ -n "$ip" ] && [ "$got" = "$ip" ]; then printf 'ok'
  else printf 'wrong'; fi
}

webui_url() { if [ -n "$domain" ]; then printf 'http://%s/' "$domain"; else printf -- '-'; fi; }
direct_url() { local ip port; ip=$(host_ip); port=$(machine_get webPort 2>/dev/null || true); port=${port:-8480}; if [ -n "$ip" ]; then printf 'http://%s:%s/' "$ip" "$port"; else printf -- '-'; fi; }

pt_files() { ls "$routes_dir" 2>/dev/null | grep '^pt-.*\.yml$' || true; }

# /etc/hs/gateway-public acme=: off | staging | production
acme_mode() { local v; v=$(sed -n 's/^acme=//p' "$etc/gateway-public" 2>/dev/null | head -n 1 || true); case "$v" in staging|production) printf '%s' "$v" ;; *) printf 'off' ;; esac; }
# off | tunnel | direct | tunnel,direct (direct = Traefik's own certificates; both need reverseProxy = traefik-public)
public_proxy() {
  local m=""
  [ "$(setting_get reverseProxy 2>/dev/null || true)" = traefik-public ] || { printf 'off'; return; }
  [ "$1" = 0 ] || m=tunnel
  [ "$(acme_mode)" = off ] || m="${m:+$m,}direct"
  printf '%s' "${m:-off}"
}
# host<TAB>mode of every public route file whose mode includes direct
direct_hosts() { render modes "$routes_dir" 2>/dev/null | awk -F'\t' '$2 ~ /(^|,)direct(,|$)/ { print $1 }' || true; }
# host<TAB>state<TAB>until: what Traefik SERVES for the host (openssl s_client), never the key store: staging | default | none | ok
cert_rows() {
  local h out issuer until st port
  port=$(public_port https)
  [ "$port" != 0 ] || return 0
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    out=$(timeout 5 openssl s_client -connect "127.0.0.1:$port" -servername "$h" </dev/null 2>/dev/null | openssl x509 -noout -issuer -enddate 2>/dev/null || true)
    issuer=$(sed -n 's/^issuer=//p' <<<"$out")
    until=$(sed -n 's/^notAfter=//p' <<<"$out")
    if [ -z "$issuer" ]; then st=none
    elif grep -q 'TRAEFIK DEFAULT CERT' <<<"$issuer"; then st=default
    elif grep -q 'STAGING' <<<"$issuer"; then st=staging
    else st=ok; fi
    printf '%s\t%s\t%s\n' "$h" "$st" "${until:--}"
  done < <(direct_hosts)
}

status_rows() {   # key<TAB>value
  local ps pp pt s
  ps=$(public_port https); pp=$(public_port http); pt=$(public_port tunnel)
  printf 'service\t%s\n' "$(unit_state)"
  printf 'port80\t%s\n' "$(port_owner 80)"
  if [ "$ps" != 0 ]; then printf 'public_https\t%s\n' "$ps"; else printf 'public_https\toff\n'; fi
  if [ "$pp" != 0 ]; then printf 'public_http\t%s\n' "$pp"; else printf 'public_http\toff\n'; fi
  if [ "$ps" != 0 ]; then printf 'port_public_https\t%s\n' "$(port_owner "$ps")"; else printf 'port_public_https\t-\n'; fi
  if [ "$pp" != 0 ]; then printf 'port_public_http\t%s\n' "$(port_owner "$pp")"; else printf 'port_public_http\t-\n'; fi
  if [ "$pt" != 0 ]; then printf 'public_tunnel\t%s\n' "$pt"; else printf 'public_tunnel\toff\n'; fi
  if [ "$pt" != 0 ]; then printf 'port_public_tunnel\t%s\n' "$(port_owner "$pt")"; else printf 'port_public_tunnel\t-\n'; fi
  printf 'domain\t%s\n' "${domain:--}"
  printf 'wildcard\t%s\n' "$(wildcard_state)"
  printf 'local_routes\t%s\n' "$(count_lines "$(render read "$routes_dir")")"
  printf 'passthrough\t%s\n' "$(count_lines "$(pt_files)")"
  printf 'public_routes\t%s\n' "$(count_lines "$(render read "$routes_dir" --prefix pub-)")"
  printf 'public_proxy\t%s\n' "$(public_proxy "$pt")"
  printf 'acme\t%s\n' "$(acme_mode)"
  printf 'unmanaged\t%s\n' "$(count_lines "$(render unmanaged "$routes_dir")")"
  printf 'webui\t%s\n' "$(webui_url)"
  printf 'direct\t%s\n' "$(direct_url)"
}

route_rows() {   # kind host path target file
  local port f d a h
  port=$(machine_get webPort 2>/dev/null || true); port=${port:-8480}
  render read "$routes_dir" | while IFS=$'\t' read -r h p t f; do printf 'local\t%s\t%s\t%s\t%s\n' "$h" "$p" "$t" "$f"; done
  render read "$routes_dir" --prefix pub- | while IFS=$'\t' read -r h p t f; do printf 'public\t%s\t%s\t%s\t%s\n' "$h" "$p" "$t" "$f"; done
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    d=$(head -n 1 "$routes_dir/$f" 2>/dev/null | sed -n 's/.* domain=\([^ ]*\).*/\1/p')
    a=$(head -n 1 "$routes_dir/$f" 2>/dev/null | sed -n 's/.* address=\([^ ]*\).*/\1/p')
    h=$(head -n 1 "$routes_dir/$f" 2>/dev/null | sed -n 's/.* https=\([^ ]*\).*/\1/p')
    a=${a:+$a${h:+:$h}}
    printf 'passthrough\t%s\t-\t%s\t%s\n' "${d:--}" "${a:--}" "$f"
  done < <(pt_files)
  # the web interface routers exist only while webUi is on (capabilities/gateway/module.nix)
  if [ "$(machine_get webUi 2>/dev/null || true)" = true ]; then
    [ -z "$domain" ] || printf 'base\t%s\t/\thttp://127.0.0.1:%s\t00-hs-base.yml\n' "$domain" "$port"
  fi
  if [ "$(public_port https)" != 0 ]; then printf 'base\t*\t-\t127.0.0.1:1\t00-hs-base.yml\n'; fi
  render unmanaged "$routes_dir" | while IFS= read -r f; do [ -z "$f" ] || printf 'unmanaged\t-\t-\t-\t%s\n' "$f"; done
}

sub=${1:-}
case "$sub" in
  --status) status_rows ;;
  --routes) route_rows ;;
  --certs) cert_rows ;;
  --check-wildcard) [ "$(wildcard_state)" = ok ] ;;
  status)
    declare -A v=()
    while IFS=$'\t' read -r k val; do v[$k]=$val; done < <(status_rows)
    step "$(t 'Gateway proxy (Traefik)')"
    kv "Service" "${v[service]}"
    kv "Port 80" "${v[port80]}"
    kv "Public HTTPS" "${v[public_https]}$([ "${v[port_public_https]}" = - ] || printf ' (%s)' "${v[port_public_https]}")"
    kv "Public HTTP" "${v[public_http]}$([ "${v[port_public_http]}" = - ] || printf ' (%s)' "${v[port_public_http]}")"
    kv "Public tunnel" "${v[public_tunnel]}$([ "${v[port_public_tunnel]}" = - ] || printf ' (%s)' "${v[port_public_tunnel]}")"
    kv "Public routes" "${v[public_routes]}"
    kv "Public proxy" "${v[public_proxy]}"
    kv "Own certificates" "${v[acme]}"
    kv "Local domain" "${v[domain]}"
    kv "Wildcard DNS" "${v[wildcard]}"
    kv "Local routes" "${v[local_routes]}"
    kv "Passthrough" "${v[passthrough]}"
    kv "Unmanaged files" "${v[unmanaged]}"
    kv "Web interface" "${v[webui]}"
    kv "Direct address" "${v[direct]}"
    bad=false
    if [ "${v[service]}" != active ]; then warn "$(t 'Traefik is not running (%s).' "${v[service]}")"; next_step "hs rebuild"; bad=true; fi
    for k in port80 port_public_https port_public_http port_public_tunnel; do
      case "${v[$k]}" in free|traefik|-) ;; *) warn "$(t 'A port is held by %s, not by Traefik (%s).' "${v[$k]}" "$k")"; bad=true ;; esac
    done
    if [ "${v[domain]}" = - ]; then warn "$(t 'No local domain: the gateway proxy needs adDomain in machine.toml.')"; bad=true
    elif [ "${v[wildcard]}" != ok ]; then warn "$(t 'The wildcard DNS record is %s.' "${v[wildcard]}")"; next_step "hs gateway check"; bad=true; fi
    if [ "${v[acme]}" != off ]; then
      certs=$(cert_rows)
      if [ -n "$certs" ]; then
        { thead 'Host' 'Certificate' 'Valid until'; printf '%s\n' "$certs"; } | table
        while IFS=$'\t' read -r ch cs _; do
          case "$cs" in default|none) warn "$(t '%s: no certificate yet: is port 443 forwarded and does the DNS name point here (no Cloudflare proxy)?' "$ch")"; bad=true ;; esac
        done <<<"$certs"
      fi
    fi
    $bad || ok "$(t 'The gateway proxy is running and the wildcard record works.')" ;;
  routes)
    { thead 'Kind' 'Host' 'Path' 'Target'; route_rows | cut -f1-4; } | table ;;
  check)
    [ -n "$domain" ] || fail "$(t 'No local domain: the gateway proxy needs adDomain in machine.toml.')"
    ip=$(host_ip)
    st=$(wildcard_state)
    if [ "$st" = ok ]; then ok "$(t '*.%s points at this server (%s)' "$domain" "$ip")"; exit 0; fi
    if [ "$st" = wrong ]; then warn "$(t 'A name under %s resolves, but not to this server (%s).' "$domain" "$ip")"
    else warn "$(t 'A name under %s does not resolve: the wildcard record is missing.' "$domain")"; fi
    site=${domain%%.*}; realm=${domain#*.}
    dc=$(awk '$1 == "nameserver" { print $2; exit }' "${HS_GATEWAY_RESOLV_CONF:-/etc/resolv.conf}" 2>/dev/null || true)
    note "$(t 'On the DNS server, a person with the domain administrator password adds one record:')"
    note "samba-tool dns add ${dc:-<dc address>} $realm '*.$site' A ${ip:-<server ip>} -U Administrator"
    note "$(t 'or in Windows DNS Manager: zone %s > %s > New Host, name *, address %s' "$realm" "$site" "${ip:-<server ip>}")"
    exit 1 ;;
  *) usage ;;
esac
