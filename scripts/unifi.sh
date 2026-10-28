#!/usr/bin/env bash
# help: UniFi: DHCP ranges, who uses an address, fixed IPs for instances (first: hs net setup)
# help.de: UniFi: DHCP-Bereiche, wer eine Adresse benutzt, feste IPs für Instanzen (zuerst: hs net setup)
# args: setup [--address <url>] [--stdin] | check | networks | clients | used <ip> | reserved <mac> | set-ip <mac> <ip> [name] | clear-ip <mac>   [--dry-run]
set -euo pipefail
. "$(dirname "$0")/lib/ui.sh"
. "$(dirname "$0")/lib/secret.sh"   # address and key may live in the vault
. "$(dirname "$0")/lib/setting.sh"

# Talks to the UniFi Network application on the router with an API key
# (UniFi: Network -> Settings -> Control Plane -> Integrations -> Create API Key).
# Address and key are kept in a root-only file on this server, never in the
# repository or in machine.toml (that file ends up in the world-readable Nix store).
state=${HS_STATE_DIR:-/var/lib/hs}
conf=$state/unifi          # line 1: address, line 2: key
ranges=$state/dhcp-ranges  # "first-address last-address" per network, read by hs ct list
# The key cannot be narrowed in UniFi (full Network admin), so this script narrows itself: it calls only the
# endpoints below, writes only client reservations (rest/user), and only inside the networks listed in
# $state/unifi-write-networks (one CIDR per line, default: the container VLAN 95).
writable=$state/unifi-write-networks
site=default

usage() {
  say "usage: hs net setup [--address <url>] [--stdin]   store the router address and the API key (--stdin: the key is the first line on standard input)"
  say "       hs net check                      list networks and DHCP ranges (changes nothing)"
  say "       hs sys unifi networks             the router's networks, plain: name, subnet, dhcp, from, to"
  say "       hs sys unifi clients              every address that is reserved or online, plain: ip, mac, name, reserved|online|reserved+online"
  say "       hs sys unifi used <ip>            who has this address (nothing printed = free)"
  say "       hs sys unifi reserved <mac>       the address reserved for that MAC (nothing printed = none)"
  say "       hs net ip <ct> set <ip>           reserve the address for that instance's MAC"
  say "       hs net ip <ct> clear              remove the reservation"
  say "       --dry-run with set-ip / clear-ip only shows the request"
  exit 1
}

dry=false
args=()
for a in "$@"; do
  if [ "$a" = --dry-run ]; then dry=true; else args+=("$a"); fi
done
set -- "${args[@]}"
[ $# -ge 1 ] || usage
cmd="$1"; shift

if [ "$cmd" = setup ]; then
  secret_prepare unifi "$state" || exit 1   # a closed vault: nothing is asked; open: the file is created inside it
  gw=$(ip route show default 2>/dev/null | awk '{ print $3; exit }')
  step "Connect to UniFi"
  note "Create the key in UniFi: Network -> Settings -> Control Plane -> Integrations -> Create API Key"
  # --address and --stdin: nothing is asked (the web interface: the key never goes into an argument)
  url="" from_stdin=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --address) [ $# -ge 2 ] || usage; url=$2; shift 2 ;;
      --stdin) from_stdin=true; shift ;;
      *) usage ;;
    esac
  done
  if [ -z "$url" ]; then
    url=$(ask "Address of the UniFi router" "https://${gw:-10.10.10.1}")
    url=${url:-https://${gw:-10.10.10.1}}
  fi
  [[ "${url%/}" =~ ^https?://[A-Za-z0-9._:-]+$ ]] || fail "$(t "'%s' is not an address of the router (like https://10.10.10.1)." "$url")"
  if $from_stdin; then IFS= read -r key || key=""; else key=$(ask_secret "API key (not shown while typing or pasting):"); fi
  [ -n "$key" ] || fail "No key entered, nothing saved."
  mkdir -p "$state"
  ( umask 077; printf '%s\n%s\n' "${url%/}" "$key" > "$conf" )
  ok "$(t 'Saved to %s (readable by root only)' "$conf")"
  setting_set networkProvider unifi || true   # switches the capability "network" on
  exec bash "$0" check
fi

[ "$(secret_state "$conf")" != locked ] || secret_locked_exit   # closed vault is not "not set up"
[ -r "$conf" ] || { warn "UniFi is not set up on this server (or you are not root). Run: hs net setup"; exit 2; }
url=$(sed -n 1p "$conf")
key=$(sed -n 2p "$conf")

# api <METHOD> <path> [json]  ->  prints the response body, complains on anything but 200
api() {
  local out code body
  case "$1 $2" in
    "GET rest/networkconf"|"GET rest/user"|"GET stat/sta"|"POST rest/user") ;;
    "PUT rest/user/"*) [[ "${2#rest/user/}" =~ ^[0-9a-f]{24}$|^u[0-9]+$ ]] || { fail "$(t 'Refused: %s %s is not a client id' "$1" "$2")" >&2; return 1; } ;;
    *) fail "$(t 'Refused: this script may not call %s %s' "$1" "$2")" >&2; return 1 ;;
  esac
  out=$(curl -sS -k -m 15 -w '\n%{http_code}' -X "$1" \
        -H "X-API-KEY: $key" -H 'Accept: application/json' -H 'Content-Type: application/json' \
        ${3:+-d "$3"} "$url/proxy/network/api/s/$site/$2") || {
    warn "$(t 'The UniFi router does not answer at %s.' "$url")" >&2; return 1; }
  code=${out##*$'\n'}
  body=${out%$'\n'*}
  if [ "$code" != 200 ]; then
    warn "$(t 'UniFi answered %s for %s %s: %s' "$code" "$1" "$2" "$(head -c 300 <<<"$body")")" >&2
    [ "$code" != 401 ] && [ "$code" != 403 ] || note "The API key is wrong, or may not do this. Create a new one and run: hs net setup" >&2
    return 1
  fi
  printf '%s' "$body"
}

ip2int() { local a b c d; IFS=. read -r a b c d <<<"$1"; echo $(( (a << 24) | (b << 16) | (c << 8) | d )); }
valid_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

# in_writable <ip> [min prefix]: is the address inside a network this script may change?
# With a prefix (the router's network, e.g. 24) that network must not be wider than the allowed one.
in_writable() {
  local cidr base prefix mask want="$1" have="${2:-32}" list
  list=$( [ -r "$writable" ] && grep -E '^[0-9.]+/[0-9]+$' "$writable" || echo 10.10.95.0/24 )
  while IFS= read -r cidr; do
    base=${cidr%/*}; prefix=${cidr#*/}
    [ "$have" -ge "$prefix" ] || continue
    mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff ))
    [ $(( $(ip2int "$want") & mask )) -eq $(( $(ip2int "$base") & mask )) ] && return 0
  done <<<"$list"
  return 1
}
refuse_network() { fail "$(t "Refused: %s is outside the networks this script may change (%s). Edit %s to allow more." "$1" "$(grep -E '^[0-9.]+/[0-9]+$' "$writable" 2>/dev/null | paste -sd, - || true)" "$writable")" >&2; }

# name, subnet (gateway/prefix), dhcp on?, dhcp start, dhcp stop, id   (tab separated)
networks() {
  api GET rest/networkconf | jq -r '.data[] | select((.ip_subnet // "") != "")
    | [ .name, .ip_subnet, (.dhcpd_enabled // false), (.dhcpd_start // "-"), (.dhcpd_stop // "-"), ._id ] | @tsv'
}

# the network line whose subnet contains <ip>
network_of() {
  local want line subnet base prefix mask
  want=$(ip2int "$1")
  while IFS= read -r line; do
    subnet=$(cut -f2 <<<"$line"); base=${subnet%/*}; prefix=${subnet#*/}
    mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff ))
    if [ $(( want & mask )) -eq $(( $(ip2int "$base") & mask )) ]; then echo "$line"; return 0; fi
  done < <(networks)
  return 1
}

# who has <ip>: reserved for (also offline) or currently using it. "<mac>\t<name>\t<how>"
users_of() {
  api GET rest/user | jq -r --arg ip "$1" '.data[]
    | select(.use_fixedip == true and .fixed_ip == $ip)
    | [ .mac, (.name // .hostname // "?"), "reserved" ] | @tsv'
  api GET stat/sta | jq -r --arg ip "$1" '.data[]
    | select(.ip == $ip)
    | [ .mac, (.name // .hostname // "?"), "online" ] | @tsv'
}

case "$cmd" in
  check)
    step "UniFi"
    nets=$(networks) || fail "No answer from UniFi (see above)."
    ok "$(t 'The connection to %s works' "$url")"
    { thead 'Network' 'Subnet' 'DHCP' 'From' 'To'; printf '%s\n' "$(cut -f1-5 <<<"$nets")"; } | table
    # remember the DHCP ranges: hs ct list uses them to tell whether an
    # instance still has a handed-out (not fixed) address
    awk -F'\t' '$3 == "true" && $4 != "-" { print $4, $5 }' <<<"$nets" > "$ranges.tmp" && mv "$ranges.tmp" "$ranges"
    users=$(api GET rest/user)
    note "$(t 'Known clients: %s, with a fixed IP: %s' "$(jq '.data | length' <<<"$users")" "$(jq '[.data[] | select(.use_fixedip == true)] | length' <<<"$users")")"
    note "$(t 'DHCP ranges saved to %s (hs ct list uses them).' "$ranges")"
    ;;

  networks)
    # plain, no header (the web interface's router view): name, subnet, dhcp true|false, first, last
    [ $# -eq 0 ] || usage
    networks | cut -f1-5
    ;;

  clients)
    # plain, no header, sorted by address: ip, mac, name (- when none), how = reserved | online | reserved+online
    [ $# -eq 0 ] || usage
    users=$(api GET rest/user) || exit 1
    sta=$(api GET stat/sta) || exit 1
    U=$users S=$sta python3 -c '
import json, os
rows = {}
def add(items, how):
    for c in items:
        ip = c.get("fixed_ip") if how == "reserved" else c.get("ip")
        if how == "reserved" and not c.get("use_fixedip"):
            continue
        if not ip:
            continue
        e = rows.setdefault(ip, {"mac": c.get("mac", ""), "name": "", "how": set()})
        e["how"].add(how)
        e["name"] = e["name"] or c.get("name") or c.get("hostname") or ""
add(json.loads(os.environ["U"]).get("data", []), "reserved")
add(json.loads(os.environ["S"]).get("data", []), "online")
for ip in sorted(rows, key=lambda a: [int(x) if x.isdigit() else 0 for x in a.split(".")]):
    e = rows[ip]
    T = chr(9)
    print(T.join([ip, e["mac"], e["name"].replace(T, " ") or "-", "+".join(h for h in ("reserved", "online") if h in e["how"])]))
'
    ;;

  used)
    [ $# -eq 1 ] && valid_ip "$1" || usage
    users_of "$1" | sort -u
    ;;

  reserved)
    [ $# -eq 1 ] || usage
    api GET rest/user | jq -r --arg m "${1,,}" '.data[]
      | select((.mac | ascii_downcase) == $m and .use_fixedip == true) | .fixed_ip // empty' | head -n1
    ;;

  set-ip)
    [ $# -ge 2 ] && valid_ip "$2" || usage
    mac=${1,,}; ip="$2"; name="${3:-}"
    net=$(network_of "$ip") || fail "$(t 'No UniFi network contains %s.' "$ip")" >&2
    IFS=$'\t' read -r netname subnet dhcp from to netid <<<"$net"
    in_writable "$ip" "${subnet#*/}" || { refuse_network "$ip"; exit 1; }
    if [ "$dhcp" = true ] && [ "$from" != - ] &&
       [ "$(ip2int "$ip")" -ge "$(ip2int "$from")" ] && [ "$(ip2int "$ip")" -le "$(ip2int "$to")" ]; then
      fail "$(t "%s lies in the DHCP range of '%s' (%s - %s). Pick an address outside it." "$ip" "$netname" "$from" "$to")" >&2
    fi
    other=$(users_of "$ip" | awk -F'\t' -v m="$mac" 'tolower($1) != m' | sort -u)
    if [ -n "$other" ]; then
      {
        warn "$(t '%s is already taken:' "$ip")"
        while IFS=$'\t' read -r omac oname ohow; do note "$oname ($omac, $ohow)"; done <<<"$other"
      } >&2
      exit 1
    fi

    existing=$(api GET rest/user | jq -r --arg m "$mac" '.data[] | select((.mac | ascii_downcase) == $m)
      | [ ._id, (if .use_fixedip == true then (.fixed_ip // "") else "" end) ] | @tsv' | head -n1)
    id=${existing%%$'	'*}; oldip=${existing#*$'	'}
    # never overwrite a reservation that lives in a network we may not touch
    if [ -n "$existing" ] && [ -n "$oldip" ] && ! in_writable "$oldip"; then refuse_network "$oldip"; exit 1; fi
    body=$(jq -cn --arg ip "$ip" --arg net "$netid" --arg name "$name" --arg mac "$mac" \
      '{ use_fixedip: true, fixed_ip: $ip, network_id: $net }
       + (if $name != "" then { name: $name } else {} end)
       + { mac: $mac }')
    if $dry; then
      if [ -n "$id" ]; then printf '%s\n' "$(t "  UniFi: reserve %s in '%s' for %s (known client, PUT rest/user/%s)" "$ip" "$netname" "$mac" "$id")"
      else printf '%s\n' "$(t "  UniFi: reserve %s in '%s' for %s (new client, POST rest/user)" "$ip" "$netname" "$mac")"; fi
      exit 0
    fi
    if [ -n "$id" ]; then
      api PUT "rest/user/$id" "$(jq -c 'del(.mac)' <<<"$body")" >/dev/null
    else
      # the router has not seen this MAC yet: create the client entry together with the reservation
      api POST rest/user "$body" >/dev/null
    fi
    ok "$(t "UniFi: %s is reserved for %s%s in '%s'. It applies when the device asks for an address again (restart it)." "$ip" "$mac" "${name:+ ($name)}" "$netname")"
    ;;

  clear-ip)
    [ $# -eq 1 ] || usage
    mac=${1,,}
    existing=$(api GET rest/user | jq -r --arg m "$mac" '.data[] | select((.mac | ascii_downcase) == $m)
      | [ ._id, (.fixed_ip // "") ] | @tsv' | head -n1)
    id=${existing%%$'	'*}; oldip=${existing#*$'	'}
    [ -z "$existing" ] || [ -z "$oldip" ] || in_writable "$oldip" || { refuse_network "$oldip"; exit 1; }
    [ -n "$id" ] || { note "$(t 'UniFi does not know %s, nothing to remove.' "$mac")"; exit 0; }
    if $dry; then printf '%s\n' "$(t '  UniFi: remove the reservation of %s (PUT rest/user/%s)' "$mac" "$id")"; exit 0; fi
    api PUT "rest/user/$id" '{"use_fixedip":false}' >/dev/null
    ok "$(t 'UniFi: reservation of %s removed.' "$mac")"
    ;;

  *) usage ;;
esac
