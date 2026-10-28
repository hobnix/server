{ config, lib, pkgs, hs, ... }:

let
  inherit (hs) machine whenUnlocked notifyFailure;
  scripts = hs.scripts;
  incusUi = machine.incusUi;
  vlans = machine.vlans;
  bridgeOf = name: "br-${name}";          # bridge per VLAN, e.g. br-home
  # Every instance gets a snapshot per night, kept for a week (cheap on ZFS).
  # They cover the instance itself, not folders mounted from /bulk.
  autoSnapshots = {
    "snapshots.schedule" = "@daily";
    "snapshots.expiry" = "7d";
    "snapshots.pattern" = "auto-{{ creation_date|date:'2006-01-02' }}";
  };

  defaultVlanNames = builtins.attrNames (lib.filterAttrs (_: v: v.default or false) vlans);
  defaultVlan =
    if builtins.length defaultVlanNames == 1
    then builtins.head defaultVlanNames
    else throw "machine.toml: exactly one VLAN must have `default = true` (found ${toString (builtins.length defaultVlanNames)})";

  # Incus devices shared by all profiles
  nicDevice = name: {
    name = "eth0";
    type = "nic";
    nictype = "bridged";
    parent = bridgeOf name;
  };
  rootDevice = {
    root = {
      path = "/";
      pool = "default";
      type = "disk";
    };
  };
in
{
  # ──────────────────────── Incus ────────────────────────
  virtualisation.incus = {
    enable = true;
    ui.enable = incusUi;
    preseed = {
      # Incus doesn't listen on the network by default; the UI and remote `incus` need it
      config = lib.optionalAttrs incusUi { "core.https_address" = ":8443"; };

      storage_pools = [{
        name = "default";
        driver = "zfs";
        config.source = "fast/incus";          # Incus creates/mounts child datasets itself
      }];

      # "default" profile uses the VLAN marked `default = true` in machine.toml.
      # Every VLAN also gets its own profile named after it:
      #   incus launch images:debian/13 myapp --profile <vlan-name>
      profiles =
        [{
          name = "default";
          config = autoSnapshots;
          devices = { eth0 = nicDevice defaultVlan; } // rootDevice;
        }]
        ++ lib.mapAttrsToList (name: _: {
          inherit name;
          config = autoSnapshots;
          devices = { eth0 = nicDevice name; } // rootDevice;
        }) vlans;
    };
  };

  systemd.services.incus.unitConfig = whenUnlocked;

  # ──────────────────────── Nightly housekeeping ────────────────────────
  # Same as running `hs mac` and `hs share repair` by hand: pins the MAC of
  # new instances and publishes new datasets as Samba shares. The fixed IP in
  # UniFi and the per-user access of a new share still have to be set by hand.
  # Results: journalctl -u hs-mac -u hs-sync-shares
  systemd.services.hs-mac = {
    description = "Pin the MAC of all Incus instances (hs mac)";
    after = [ "incus.service" ];
    path = [ "/run/current-system/sw" ];
    serviceConfig.Type = "oneshot";
    script = "bash ${scripts}/mac.sh";
    startAt = "03:30";
    onFailure = notifyFailure;
  };
}
