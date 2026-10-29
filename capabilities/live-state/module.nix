# The capability "live-state" (capabilities/live-state/capability.toml, NOTES.md): Redis on a unix socket plus the collector hs-live.
# Loaded by capabilities/default.nix only while the capability is on (machine.toml liveState = "redis" with webUi on a homeserver,
# or `live-state` in `capabilities`).
{ config, lib, pkgs, hs, ... }:

{
  # Redis for the live state: no TCP (port 0, so no firewall rule), nothing on disk (no snapshots, no append file), RAM capped.
  # The socket is /run/redis-hobnix/redis.sock. UNVERIFIED: that `group` exists in the pinned nixpkgs module; the socket
  # permissions below do not depend on it (hs-web and hs-live run as root and get the group through SupplementaryGroups).
  services.redis.servers.hobnix = {
    enable = true;
    port = 0;
    unixSocketPerm = 660;
    save = [ ];
    appendOnly = false;
    settings = {
      maxmemory = "32mb";
      maxmemory-policy = "allkeys-lru";
    };
  };

  # The socket belongs to the group redis-hobnix (mode 660). hs-live is the group for a later non-root reader (the deck, phase 6).
  users.groups.hs-live = { };

  # The collector: runs `hs sys <topic>` on an interval and publishes the text to Redis (scripts/live-collect.py).
  systemd.services.hs-live = {
    description = "Live state collector (hs sys ... into Redis)";
    wantedBy = [ "multi-user.target" ];
    after = [ "redis-hobnix.service" ];
    requires = [ "redis-hobnix.service" ];
    path = [ "/run/current-system/sw" pkgs.python3 ];
    environment.HS_CALLER = "ui";
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 ${hs.scripts}/live-collect.py";
      Restart = "always";
      RestartSec = 5;
      SupplementaryGroups = [ "hs-live" "redis-hobnix" ];
    };
    onFailure = hs.notifyFailure;
  };
}
