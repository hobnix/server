# The internal link (capabilities/incus/NOTES.md): a host-only Incus bridge between the host and chosen containers (cloudflared -> Traefik),
# no NAT, no DHCP, no default route. Pure function of machine.toml, used by capabilities/incus/module.nix and capabilities/gateway/module.nix.
# The bridge name is defined here and nowhere else in Nix (the shell side: scripts/lib/internal-link.sh).
{ lib, machine }:
let
  subnet = machine.incusInternalSubnet;
  oct = "(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])";
  m = builtins.match "${oct}\\.${oct}\\.${oct}\\.${oct}/29" subnet;
  n = if m == null then [ 0 0 0 0 ] else map lib.toInt m;
  a = builtins.elemAt n 0; b = builtins.elemAt n 1; c = builtins.elemAt n 2; d = builtins.elemAt n 3;
  private = a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
  base = "${toString a}.${toString b}.${toString c}";
in rec {
  name = "hs-internal";
  inherit subnet;
  valid = m != null && private && lib.mod d 8 == 0;
  host = "${base}.${toString (d + 1)}";
  peer = "${base}.${toString (d + 2)}";
  hostCidr = "${host}/29";
}
