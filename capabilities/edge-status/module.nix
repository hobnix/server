# The capability "edge-status" (capabilities/edge-status/NOTES.md): the status document of this node. Ported from the proxyserver repo (modules/deck.nix):
# hs-edge-status writes /run/hs-deck/deck.json every 10 s (scripts/edge-status.sh), hs-edge-api hands it out read only on port 9740 over Tailscale
# (scripts/deck-serve.py, the SAME file the home server uses: no copy), and the forced command scripts/node-remote.sh answers `status` with it (hs node status).
# Also here: the push message at once when a unit the node depends on fails, and the file that tells the status document the node's name and secret paths.
{ config, lib, pkgs, hs, ... }:

let
  scripts = hs.scripts;
in
{
  environment.etc."hs/edge-status.json".text = builtins.toJSON {
    hostName = hs.hostName;
    role = hs.machine.role;
    # secrets are only named here by the path of their file
    notifyUrlFile = "/var/lib/hs/notify-url";
    heartbeatUrlFile = "/var/lib/hs/heartbeat-url";
    tailscaleAuthKeyFile = hs.machine.tailscaleAuthKeyFile;
  };

  systemd.services.hs-edge-status = {
    description = "Write the status document of the edge node (hs sys edge status)";
    path = [ "/run/current-system/sw" "/run/wrappers" ];
    serviceConfig.Type = "oneshot";
    script = ''
      mkdir -p /run/hs-deck && chmod 755 /run/hs-deck
      bash ${scripts}/edge-status.sh > /run/hs-deck/deck.json.new && chmod 644 /run/hs-deck/deck.json.new && mv /run/hs-deck/deck.json.new /run/hs-deck/deck.json
    '';
    startAt = "*:*:0/10";
  };

  systemd.services.hs-edge-api = {
    description = "Read-only status endpoint for the main node and displays (port 9740)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 ${scripts}/deck-serve.py 9740 /run/hs-deck/deck.json";
      DynamicUser = true;
      Restart = "on-failure";
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
  };
  # only on the private interfaces (Tailscale): the public side has no rule for 9740; the Tailscale ACL must allow tcp 9740 to the node's tag
  networking.firewall.interfaces = lib.genAttrs config.hs.privateInterfaces (_: { allowedTCPPorts = [ 9740 ]; });

  # services whose failure is reported at once (the health check finds the rest within 15 minutes)
  systemd.services.tailscaled.unitConfig.OnFailure = hs.notifyFailure;
  systemd.services.nftables.unitConfig.OnFailure = hs.notifyFailure;
  systemd.services.sshd.unitConfig.OnFailure = hs.notifyFailure;
}
