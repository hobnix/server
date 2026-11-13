# shellcheck shell=bash
# The network check of the installer and the first-run wizard (issue #179, docs/PLAN-first-run-wizard.md step 2). DHCP only: the check asks
# whether the server has a link, an address, a route, working names and a believable clock. Needs lib/nic.sh; netcheck_show also lib/ui.sh.
#   netcheck_rows   one row per item, always the same six in this order, tab separated, an empty field is -: item, state (ok|warn|fail), value, fix
#                   items: link, wireless, address, route, dns, clock. An item that cannot work after an earlier failure is fail too (value -, fix names
#                   the first problem), so the shape never changes.
#   netcheck_ok     exit 1 when a row is fail
#   netcheck_show   the rows for a person (ui.sh), and the router advice when everything passed
# Test knobs: fake `ip` and `getent` on PATH, HS_SYS_NET (fake /sys/class/net), HS_NETCHECK_NOW (epoch seconds), HS_NETCHECK_HOST (the name to resolve).
_nc_dir=$(dirname "${BASH_SOURCE[0]}")
# shellcheck source=nic.sh
. "$_nc_dir/nic.sh"

_nc_wireless() { [ -e "$(nic_net_dir)/$1/wireless" ] || [ -e "$(nic_net_dir)/$1/phy80211" ]; }

netcheck_rows() {
  local T=$'\t' n up="" wired="" wifi="" first="" first_fix="" line v="" dyn="" fix
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    if _nc_wireless "$n"; then wifi="$wifi${wifi:+, }$n"; else wired="$wired${wired:+, }$n"; fi
    [ "$(nic_link "$n")" = up ] && up="$up${up:+, }$n"
  done < <(nic_list)
  # link
  if [ -n "$up" ]; then printf 'link\tok\t%s\t-\n' "$up"
  else
    first=link; first_fix="Connect a network cable between this server and the router."
    printf 'link\tfail\t-\t%s\n' "$first_fix"
  fi
  # wireless
  if [ -n "$wifi" ] && [ -z "$wired" ]; then printf 'wireless\twarn\t%s\ta server needs a cable\n' "$wifi"
  else printf 'wireless\tok\t-\t-\n'; fi
  # address
  if [ -z "$first" ]; then
    # the address of the card the default route uses (a bridge such as incusbr0 must not be shown); without a route: the first one
    rdev=$(ip -o route show default 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }' || true)
    line=""
    [ -z "$rdev" ] || line=$(ip -o -4 addr show dev "$rdev" scope global 2>/dev/null | sed -n 1p || true)
    [ -n "$line" ] || line=$(ip -o -4 addr show scope global 2>/dev/null | sed -n 1p || true)
    if [ -n "$line" ]; then
      v=$(printf '%s\n' "$line" | awk '{ print $4 " on " $2 }')
      dyn=-; case "$line" in *dynamic*) dyn="reserve this address on your router" ;; esac
      printf 'address\tok\t%s\t%s\n' "$v" "$dyn"
    else
      first=address; first_fix="No address was given: DHCP is off on the router, or the router does not answer."
      printf 'address\tfail\t-\t%s\n' "$first_fix"
    fi
  else printf 'address\tfail\t-\tFix the %s first.\n' "$first"; fi
  # route
  if [ -z "$first" ]; then
    line=$(ip -o route show default 2>/dev/null | sed -n 1p || true)
    v=$(printf '%s\n' "$line" | awk '{ for (i = 1; i < NF; i++) { if ($i == "via") via = $(i + 1); if ($i == "dev") dev = $(i + 1) } if (via != "" || dev != "") print (via != "" ? via " on " dev : "on " dev) }')
    if [ -n "$v" ]; then printf 'route\tok\t%s\t-\n' "$v"
    else
      first=route; first_fix="There is an address but no default route: check that the router hands out a gateway (DHCP)."
      printf 'route\tfail\t-\t%s\n' "$first_fix"
    fi
  else printf 'route\tfail\t-\tFix the %s first.\n' "$first"; fi
  # dns
  local host=${HS_NETCHECK_HOST:-github.com}
  if [ -z "$first" ]; then
    v=$(getent hosts "$host" 2>/dev/null | awk 'NR == 1 { print $1 }' || true)
    if [ -n "$v" ]; then printf 'dns\tok\t%s is %s\t-\n' "$host" "$v"
    else printf 'dns\tfail\t-\tThe name %s does not resolve: check the router DNS or the internet connection.\n' "$host"; fi
  else printf 'dns\tfail\t-\tFix the %s first.\n' "$first"; fi
  # clock
  local now=${HS_NETCHECK_NOW:-$(date +%s)}
  if [ "$now" -ge 1767225600 ] 2>/dev/null; then printf 'clock\tok\t%s\t-\n' "$(date -u -d "@$now" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "$now")"
  else printf 'clock\tfail\t-\tThe clock is wrong (before 2026): set it with date -s "YYYY-MM-DD HH:MM:SS".\n'; fi
}

netcheck_ok() { ! netcheck_rows | awk -F'\t' '$2 == "fail" { f = 1 } END { exit !f }'; }

netcheck_show() {
  local rows
  rows=$(netcheck_rows)
  { thead "Item" "State" "Value" "Fix"; printf '%s\n' "$rows"; } | table
  if ! printf '%s\n' "$rows" | awk -F'\t' '$2 == "fail" { f = 1 } END { exit !f }'; then
    note "Reserve this address on your router (a fixed lease for this server), so it keeps the same address."
  fi
}
