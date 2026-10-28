# Options that capabilities share (docs/PLAN-modular-core.md step 3). Always loaded by capabilities/default.nix, whatever is on.
{ lib, ... }:

{
  options.hs.privateInterfaces = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [ "tailscale0" ];
    description = ''
      Network interfaces that only trusted devices can reach, set by the capability that provides "private-access" (tailscale).
      The web interface, the status document and SSH (when sshOverIp is off) are opened on these interfaces and nowhere else
      outside the home networks, so none of them has to know which provider it is.
    '';
  };
}
