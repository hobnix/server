# The capability "tailscale" (capabilities/tailscale/capability.toml, NOTES.md): this server in a tailnet. The first provider of
# "private-access": it tells the rest of the system which interface that is (hs.privateInterfaces, capabilities/options.nix).
# Moved here from configuration.nix; capabilities/default.nix loads it only while the capability is on.
{ config, lib, pkgs, hs, ... }:

let
  # This server as a Tailscale subnet router for the home networks (machine.toml: tailscaleRouter, default false)
  tailscaleRouter = hs.machine.tailscaleRouter;
  # HTTPS for the web interface through `tailscale serve` (machine.toml: webTailscale, default false)
  webTailscale = hs.machine.webTailscale;
  webUi = hs.machine.webUi;
  webPort = hs.machine.webPort;
  # a headless node (an edge VPS) joins the tailnet by itself: auth key file and tags (machine.toml: tailscaleAuthKeyFile, tailscaleTags)
  authKeyFile = hs.machine.tailscaleAuthKeyFile;
  tags = hs.machine.tailscaleTags;
  upFlags = lib.optional (tags != [ ]) "--advertise-tags=${lib.concatStringsSep "," tags}"
    ++ lib.optional (hs.machine.role == "edge") "--hostname=${hs.hostName}";
in
{
  hs.privateInterfaces = [ "tailscale0" ];

  # Tailscale subnet router (machine.toml: tailscaleRouter = true). Only the program is set up here;
  # joining the tailnet and the routes are done by hand once, see packages/authentik/guide.md section 6:
  #   sudo tailscale up --advertise-routes=10.10.95.0/24,10.10.10.95/32 --accept-dns=false
  # useRoutingFeatures "server" turns on IP forwarding and a loose reverse-path check for the tunnel.
  services.tailscale = {
    enable = true;
    useRoutingFeatures = if tailscaleRouter then "server" else "client";
    openFirewall = true;   # UDP 41641: direct connections instead of the relay
    authKeyFile = lib.mkIf (authKeyFile != "") authKeyFile;   # read once at the first login
    extraUpFlags = lib.mkIf (upFlags != [ ]) upFlags;
  };

  # HTTPS for the web interface: `tailscale serve` terminates TLS with the certificate Tailscale issues for this machine's name
  # (https://<host>.<tailnet>.ts.net, tailnet members only) and hands the plain request to the page on loopback. Needs once, by hand: `sudo tailscale up`
  # and "HTTPS certificates" switched on in the Tailscale admin console (DNS page). Not the internet: no funnel, no Zoraxy rule.
  systemd.services.hs-web-tailscale = lib.mkIf (webUi && webTailscale) {
    description = "HTTPS for the web interface through tailscale serve";
    wantedBy = [ "multi-user.target" ];
    after = [ "hs-web.service" "tailscaled.service" ];
    path = [ config.services.tailscale.package ];
    script = "tailscale serve --bg --https=443 http://127.0.0.1:${toString webPort}";
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; Restart = "on-failure"; RestartSec = 60; };
  };
}
