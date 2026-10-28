# shellcheck shell=bash
# local_domain: prints <siteName>.<realm> (lower case) or nothing. The name space of the gateway proxy (capabilities/gateway/NOTES.md).
# Same computation as scripts/dns.sh: realm = machine.toml adDomain.realm, siteName = /etc/hs/site-name.
# Knobs: HS_MACHINE_FILE, HS_SITE_NAME_FILE. Needs lib/machine.sh sourced.
local_domain() {
  local realm site
  realm=$(machine_get adDomain.realm 2>/dev/null | tr 'A-Z' 'a-z' | tr -d ' \r\n' || true)
  site=$(tr -d ' \r\n' <"${HS_SITE_NAME_FILE:-/etc/hs/site-name}" 2>/dev/null | tr 'A-Z' 'a-z' || true)
  [ -n "$realm" ] && [[ "$site" =~ ^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$ ]] || return 0
  printf '%s.%s\n' "$site" "$realm"
}
