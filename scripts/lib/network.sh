# shellcheck shell=bash
# The network provider (capabilities/network/NOTES.md): which variant connects this server to the router.
#   network_provider   the variant's name, or nothing. The runtime setting networkProvider; a server that has the UniFi connection file
#                      from before the setting existed counts as "unifi".
#   network_run <verb> [args]   run a verb of the provider (scripts/providers/network/<variant>.sh)
. "$(dirname "${BASH_SOURCE[0]}")/setting.sh"

network_provider() {
  local v st=${HS_STATE_DIR:-/var/lib/hs}
  v=$(setting_get networkProvider 2>/dev/null || true)
  if [ -z "$v" ] && { [ -e "$st/unifi" ] || [ -L "$st/unifi" ]; }; then v=unifi; fi
  echo "$v"
}

network_run() {
  local p
  p=$(network_provider)
  [ -n "$p" ] || return 1
  bash "$(dirname "${BASH_SOURCE[0]}")/../providers/network/$p.sh" "$@"
}
