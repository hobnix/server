#!/usr/bin/env bash
# Evaluates the system configuration with each capability on its own, with all of them, and with none (docs/PLAN-modular-core.md
# step 8, "test matrix"). A capability that breaks alone, or that only works because another one is on, is entangled: this finds it.
# CI runs it in the "nixos" job; it can be run by hand wherever `nix-instantiate` and nixpkgs exist (the WSL Debian here):
#
#   bash scripts/dev/nix-matrix.sh [--only <variant>]      (NIX_PATH must find <nixpkgs>, default nixpkgs=channel:nixos-unstable)
#
# Needs no machine, no pools and no root: the configuration is only evaluated, never built. Not an `hs` command.
set -uo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
only=""
[ "${1:-}" != --only ] || only=${2:-}
export NIX_PATH=${NIX_PATH:-nixpkgs=channel:nixos-unstable}
command -v jq >/dev/null 2>&1 || { echo "jq is not installed: cannot compare the values"; exit 77; }
command -v nix-instantiate >/dev/null 2>&1 || { echo "nix-instantiate is not installed: nothing to evaluate"; exit 77; }

work=$(mktemp -d /tmp/nix-matrix.XXXXXX)
trap 'rm -rf "$work"' EXIT
( cd "$repo" && tar --exclude=.git --exclude=node_modules --exclude=web/dist -cf - . ) | tar -xf - -C "$work"
printf '{ lib, ... }: { fileSystems."/" = { device = "/dev/vda1"; fsType = "ext4"; }; boot.loader.grub.enable = lib.mkDefault false; }\n' > "$work/hardware-configuration.nix"

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ok    $*"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $*"; }

# write machine.toml: the example, CHANGEME replaced, plus the given lines
machine() { cp "$work/machine.toml.example" "$work/machine.toml"; sed -i 's/CHANGEME/deadbeef/' "$work/machine.toml"; for l in "$@"; do printf '%s\n' "$l" >> "$work/machine.toml"; done; }
evaluates() { ( cd "$work" && nix-instantiate '<nixpkgs/nixos>' -A system -I nixos-config=./configuration.nix >/dev/null 2>"$work/err.txt" ); }
# facts <config paths...> -> the values as a JSON list, from ONE evaluation of the system (a separate evaluation per value took ~7 s each)
facts() {
  local list="" a
  for a in "$@"; do list="$list c.$a"; done
  ( cd "$work" && nix-instantiate --eval --strict --json -I nixos-config=./configuration.nix \
      -E "let c = (import <nixpkgs/nixos> { configuration = ./configuration.nix; }).config; in [$list ]" 2>&1 )
}
# as_json <Nix literal> -> the same value as JSON, so that "[ ]" and "[]" compare equal
as_json() { nix-instantiate --eval --strict --json -E "$1" 2>&1; }

# variant <name> <expected facts as "attr=value" separated by |> <machine.toml lines...>
variant() {
  local name=$1 facts=$2; shift 2
  [ -z "$only" ] || [ "$only" = "$name" ] || return 0
  echo "-- $name"
  machine "$@"
  if ! evaluates; then bad "$name: the system does not evaluate: $(grep -E 'error:|Failed assertions|^- ' "$work/err.txt" | head -n 2 | tr '\n' ' ')"; return; fi
  ok "$name: evaluates"
  local f a want got i=0 attrs=() wants=() all
  IFS='|' read -ra F <<<"$facts"
  for f in "${F[@]}"; do
    [ -n "$f" ] || continue
    attrs+=("${f%%=*}"); wants+=("${f#*=}")
  done
  [ "${#attrs[@]}" -gt 0 ] || return 0
  all=$(facts "${attrs[@]}")
  for a in "${attrs[@]}"; do
    want=${wants[$i]}
    got=$(printf '%s' "$all" | jq -c ".[$i]" 2>/dev/null || echo "not readable: $all")
    if [ "$got" = "$(as_json "$want" | jq -c .)" ]; then ok "$name: $a = $want"; else bad "$name: $a is '$got', expected '$want'"; fi
    i=$((i + 1))
  done
}
# a variant that must be refused (an assertion)
refused() {
  local name=$1; shift
  [ -z "$only" ] || [ "$only" = "$name" ] || return 0
  echo "-- $name"
  machine "$@"
  if evaluates; then bad "$name: evaluated, but should have been refused"; else ok "$name: refused, as it should be"; fi
}

PROM='services.prometheus.enable'; TS='services.tailscale.enable'; PRIV='hs.privateInterfaces'

variant core         "$PROM=false|$TS=false|$PRIV=[ ]"
for dir in "$repo"/capabilities/*/; do
  cap=$(basename "$dir")
  case "$cap" in
    metrics)   variant "only-$cap" "$PROM=true|$TS=false|$PRIV=[ ]" "capabilities = [\"$cap\"]" ;;
    tailscale) variant "only-$cap" "$PROM=false|$TS=true|$PRIV=[ \"tailscale0\" ]" "capabilities = [\"$cap\"]" ;;
    gateway)   variant "only-$cap" "$PROM=false|$TS=false|$PRIV=[ ]|services.traefik.enable=true" "capabilities = [\"$cap\"]" ;;
    *)         variant "only-$cap" "$PROM=false|$TS=false|$PRIV=[ ]" "capabilities = [\"$cap\"]" ;;   # no Nix module: it must still evaluate
  esac
done
all=$(ls -d "$repo"/capabilities/*/ | xargs -n1 basename | sed 's/.*/"&"/' | paste -sd, | sed 's/,/, /g')
variant all          "$PROM=true|$TS=true|$PRIV=[ \"tailscale0\" ]" "capabilities = [$all]"
refused gateway-webport-80 'capabilities = ["gateway"]' 'webUi = true' 'webPort = 80'
variant gateway-public "services.traefik.enable=true" 'capabilities = ["gateway"]' 'gatewayPublicHttps = 4443' 'gatewayPublicHttp = 8008'
variant gateway-public-direct "services.traefik.enable=true" 'capabilities = ["gateway"]' 'gatewayPublicHttps = 443' 'gatewayPublicHttp = 80'   # the router forwards 443 and 80 as they are
# direct mode (own Let's Encrypt certificates): the resolver and hs-deadend are exclusive; tunnel-only and public-only setups have no resolver
GP='environment.etc."hs/gateway-public".text'
RW='systemd.services.traefik.serviceConfig.ReadWritePaths'
variant gateway-direct "$GP="'"https=443\nhttp=80\ntunnel=0\nacme=staging\n"'"|$RW="'[ "/var/lib/traefik" "/var/lib/traefik" "/var/lib/hs-gateway/acme" ]' 'capabilities = ["gateway"]' 'gatewayPublicHttps = 443' 'gatewayPublicHttp = 80' 'gatewayAcmeEmail = "a@example.org"'
variant gateway-direct-prod "$GP="'"https=443\nhttp=80\ntunnel=0\nacme=production\n"' 'capabilities = ["gateway"]' 'gatewayPublicHttps = 443' 'gatewayPublicHttp = 80' 'gatewayAcmeEmail = "a@example.org"' 'gatewayAcmeStaging = false'
variant gateway-tunnel-only-acme-off "$GP="'"https=0\nhttp=0\ntunnel=8081\nacme=off\n"'"|$RW="'[ "/var/lib/traefik" "/var/lib/traefik" ]' 'capabilities = ["gateway"]' 'gatewayTunnelPort = 8081' 'gatewayTunnelFrom = [ "10.10.95.19/32" ]'
variant gateway-public-no-acme "$GP="'"https=443\nhttp=80\ntunnel=0\nacme=off\n"' 'capabilities = ["gateway"]' 'gatewayPublicHttps = 443' 'gatewayPublicHttp = 80'
refused gateway-acme-no-https 'capabilities = ["gateway"]' 'gatewayAcmeEmail = "a@example.org"'
refused gateway-acme-bad-email 'capabilities = ["gateway"]' 'gatewayPublicHttps = 443' 'gatewayAcmeEmail = "nope"'
LR='environment.etc."hs/gateway-lan-ranges".text'
variant gateway-ranges-local "$LR="'"10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 127.0.0.1/32 fc00::/7 ::1/128\n"' 'capabilities = ["gateway"]'
variant gateway-ranges-public "$LR="'"10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.1/32 fc00::/7 ::1/128\n"' 'capabilities = ["gateway"]' 'gatewayPublicHttp = 80'
refused gateway-public-443-tailscale 'capabilities = ["gateway"]' 'gatewayPublicHttps = 443' 'webUi = true' 'webTailscale = true'
refused gateway-public-https-80 'capabilities = ["gateway"]' 'gatewayPublicHttps = 80'
refused gateway-public-http-443 'capabilities = ["gateway"]' 'gatewayPublicHttp = 443'
variant gateway-tunnel "services.traefik.enable=true" 'capabilities = ["gateway"]' 'gatewayTunnelPort = 8081' 'gatewayTunnelFrom = [ "10.10.95.19/32" ]'
refused gateway-tunnel-no-from 'role = "minimal"' 'capabilities = ["gateway"]' 'gatewayTunnelPort = 8081'   # no incus: the empty list has no default
TF='environment.etc."hs/gateway-tunnel-from".text'
# the empty list on a server with Incus = the container on the internal link; an explicit list wins and gets no link-scoped rule
variant gateway-tunnel-link-default "$TF="'"10.99.0.2/32\n"'"|hs.internalLinkAccept="'[ "ip saddr { 10.99.0.2/32 } tcp dport 8081" ]' 'capabilities = ["gateway", "incus"]' 'gatewayTunnelPort = 8081'
variant gateway-tunnel-explicit "$TF="'"10.10.95.19/32\n"'"|hs.internalLinkAccept=[ ]" 'capabilities = ["gateway", "incus"]' 'gatewayTunnelPort = 8081' 'gatewayTunnelFrom = [ "10.10.95.19/32" ]'
refused gateway-tunnel-80 'capabilities = ["gateway"]' 'gatewayTunnelPort = 80' 'gatewayTunnelFrom = [ "10.10.95.19/32" ]'
refused gateway-tunnel-public-port 'capabilities = ["gateway"]' 'gatewayPublicHttps = 4443' 'gatewayTunnelPort = 4443' 'gatewayTunnelFrom = [ "10.10.95.19/32" ]'
refused gateway-tunnel-not-an-address 'capabilities = ["gateway"]' 'gatewayTunnelPort = 8081' 'gatewayTunnelFrom = [ "8081" ]'
refused gateway-tunnel-open 'capabilities = ["gateway"]' 'gatewayTunnelPort = 8081' 'gatewayTunnelFrom = [ "0.0.0.0/0" ]'
variant gateway-ad "services.traefik.enable=true" 'capabilities = ["gateway"]' 'adDomain = { realm = "AD.HOME.LAN", workgroup = "HOME" }'   # the hs-webui Host router
variant legacy-switches "$PROM=true|$TS=true" 'metrics = true' 'tailscaleRouter = true'
variant ad-domain 'environment.etc."hs/capabilities".text="ad\nstorage\nincus\nsamba\nbackup\n"' 'adDomain = { realm = "AD.HOME.LAN", workgroup = "HOME" }'   # the capability ad is computed from adDomain
# the author's preset as a whole (presets/example-server.toml [machine]): its lines must evaluate together, whatever the other variants say
mapfile -t example < <(awk '/^\[machine\]/ { f = 1; next } /^\[/ { f = 0 } f && /^[A-Za-z]+ *=/' "$repo/presets/example-server.toml")   # the lines are valid machine.toml lines as they are
variant preset-example "$PROM=true|$TS=true|$PRIV=[ \"tailscale0\" ]" "${example[@]}"
# the roles: a home server has the four home capabilities without naming them, edge and minimal have none of them
INCUS='virtualisation.incus.enable'; SMB='services.samba.enable'; ZFSPOOLS='boot.zfs.extraPools'
variant role-homeserver "$INCUS=true|$SMB=true|$ZFSPOOLS=[ \"fast\" \"bulk\" ]"
variant role-minimal "$INCUS=false|$SMB=false|$ZFSPOOLS=[ ]|$PROM=false" 'role = "minimal"'
mapfile -t edge < <(awk '/^\[machine\]/ { f = 1; next } /^\[/ { f = 0 } f && /^[A-Za-z]+ *=/' "$repo/presets/edge.toml")
variant role-edge "$INCUS=false|$SMB=false|$ZFSPOOLS=[ ]|$TS=true|services.postfix.enable=false" "${edge[@]}"
variant role-edge-configured "$INCUS=false|$SMB=false|$TS=true|services.postfix.enable=true|networking.firewall.filterForward=true|services.openssh.settings.PermitRootLogin=\"forced-commands-only\""   "${edge[@]}" 'bootDevice = "/dev/sda"' 'sshOverIp = false' 'edgeDomain = "example.org"' 'edgeMxHost = "mx.example.org"' 'edgeAcmeEmail = "me@example.org"'   'edgeStalwartIp = "100.64.0.10"' 'edgeWingsIp = "100.64.0.11"' 'edgeGamePorts = ["25565-25579"]' 'edgeRtcIp = "100.64.0.12"' 'edgeRtcTcp = ["7881"]'   'edgeWatchSites = ["https://example.org"]' 'nodeKeys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAInodekey hs-node"]'
refused edge-forwards-ssh "${edge[@]}" 'edgeWingsIp = "100.64.0.11"' 'edgeGamePorts = ["20-30"]'   # a pool that covers 22 and 25 is never forwarded
refused ssh-closed-without-provider 'sshOverIp = false'
variant ssh-closed-with-tailscale "$TS=true" 'sshOverIp = false' 'capabilities = ["tailscale"]'
# the internal link of Incus (capabilities/incus/internal-link.nix): facts file, nft table, subnet checks
IL='environment.etc."hs/internal-link".text'
variant incus-link "$IL="'"name=hs-internal\nsubnet=10.99.0.0/29\nhost=10.99.0.1\npeer=10.99.0.2\n"'"|networking.nftables.tables.hs-internal.family=\"inet\""
variant incus-link-custom "$IL="'"name=hs-internal\nsubnet=10.250.0.8/29\nhost=10.250.0.9\npeer=10.250.0.10\n"' 'incusInternalSubnet = "10.250.0.8/29"'
refused incus-link-unaligned 'incusInternalSubnet = "10.99.0.3/29"'
refused incus-link-public 'incusInternalSubnet = "8.8.8.0/29"'

echo "-> $pass ok, $fail failed"
[ "$fail" -eq 0 ]
