# The capability "edge-watcher" (capabilities/edge-watcher/NOTES.md): the outside view of the home server. Ported from the proxyserver repo (modules/watch.nix);
# the script is vps/hs-watch.sh of THIS repo now (no copy on the VPS any more). Every 5 minutes: no "alive" message of the home server on the heartbeat topic
# for 45 minutes, or a public address that does not answer / answers 5xx, is an urgent message to this node's own push address.
# Both addresses are secrets, so they are files (hs config set heartbeatUrl / notifyUrl), never in machine.toml.
{ config, lib, pkgs, hs, ... }:

let
  sites = hs.machine.edgeWatchSites;
  stateFile = "/var/lib/hs-watch/state";
in
{
  # what scripts/lib/edge_facts.py (status document: watcher card) reads; no secrets
  environment.etc."hs/edge-watcher.json".text = builtins.toJSON { inherit sites stateFile; };

  systemd.services.hs-edge-watch = {
    description = "Watch the home server from outside (heartbeat and public addresses)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = with pkgs; [ bash curl coreutils gnugrep gawk ];
    environment = {
      HEARTBEAT_URL_FILE = "/var/lib/hs/heartbeat-url";
      ALERT_URL_FILE = "/var/lib/hs/notify-url";
      SITES = lib.concatStringsSep " " sites;
      HS_WATCH_CONF = "/dev/null";
      HS_WATCH_STATE = stateFile;
      HS_NTFY_LIB = "${hs.scripts}/lib/ntfy.sh";
    };
    serviceConfig.Type = "oneshot";
    script = "bash ${../../vps}/hs-watch.sh";
    onFailure = hs.notifyFailure;
  };

  systemd.timers.hs-edge-watch = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "5min";
    };
  };
}
