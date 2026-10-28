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
attr() {   # attr <config path> -> the value as Nix prints it
  ( cd "$work" && nix-instantiate --eval --strict -I nixos-config=./configuration.nix \
      -E "(import <nixpkgs/nixos> { configuration = ./configuration.nix; }).config.$1" 2>&1 | head -n 3 )
}

# variant <name> <expected facts as "attr=value" separated by |> <machine.toml lines...>
variant() {
  local name=$1 facts=$2; shift 2
  [ -z "$only" ] || [ "$only" = "$name" ] || return 0
  echo "-- $name"
  machine "$@"
  if ! evaluates; then bad "$name: the system does not evaluate: $(grep -E 'error:|Failed assertions|^- ' "$work/err.txt" | head -n 2 | tr '\n' ' ')"; return; fi
  ok "$name: evaluates"
  local f a want got
  IFS='|' read -ra F <<<"$facts"
  for f in "${F[@]}"; do
    [ -n "$f" ] || continue
    a=${f%%=*}; want=${f#*=}
    got=$(attr "$a")
    if [ "$got" = "$want" ]; then ok "$name: $a = $want"; else bad "$name: $a is '$got', expected '$want'"; fi
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
LR='environment.etc."hs/gateway-lan-ranges".text'
variant gateway-ranges-local "$LR="'"10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 127.0.0.1/32 fc00::/7 ::1/128\n"' 'capabilities = ["gateway"]'
variant gateway-ranges-public "$LR="'"10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.1/32 fc00::/7 ::1/128\n"' 'capabilities = ["gateway"]' 'gatewayPublicHttp = 80'
refused gateway-public-443-tailscale 'capabilities = ["gateway"]' 'gatewayPublicHttps = 443' 'webUi = true' 'webTailscale = true'
refused gateway-public-https-80 'capabilities = ["gateway"]' 'gatewayPublicHttps = 80'
refused gateway-public-http-443 'capabilities = ["gateway"]' 'gatewayPublicHttp = 443'
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

echo "-> $pass ok, $fail failed"
[ "$fail" -eq 0 ]
