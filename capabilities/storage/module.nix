{ config, lib, pkgs, hs, ... }:

let
  inherit (hs) machine bulkSnapraid bulkReady whenUnlocked notifyFailure ad;
  scripts = hs.scripts;
  zfsArcMaxGB = machine.zfsArcMaxGB;
  syncEveryHours = machine.syncEveryHours;
  shareSnapshots = machine.shareSnapshots;
  diskSpindownMinutes = machine.diskSpindownMinutes;
  pciBind = machine.pciBind;
in
{
  boot.zfs.forceImportRoot = false;
  # ARC limit (zfsArcMaxGB in machine.toml): the module option applies at boot, the tmpfiles rule writes the live value
  # at every switch, so a rebuild takes it without a reboot.
  boot.extraModprobeConfig = lib.mkIf (zfsArcMaxGB > 0) "options zfs zfs_arc_max=${toString (zfsArcMaxGB * 1073741824)}";
  # An encrypted pool (fast) is imported WITHOUT asking for its key on the console: hs-unlock below / `hs unlock`
  # loads it (over SSH, or by itself with /var/lib/hs/disk-key). The default (true) stops the boot at a console prompt.
  boot.zfs.requestEncryptionCredentials = false;

  # Pools are created manually via CLI; NixOS imports them at boot and
  # zfs-mount.service mounts their datasets (no fileSystems entries needed).
  # They must exist before this config is applied: a new server is installed
  # with install.nix first (see README, "New server").
  boot.zfs.extraPools = [ "fast" ] ++ lib.optional (!bulkSnapraid) "bulk";

  # No disk is listed in the config: each array member carries a filesystem
  # label (bulk-data-NN, bulk-parity-N) written by `hs pool bulk`. At boot
  # the labelled disks are mounted, the data disks merged into /bulk, and the
  # SnapRAID config regenerated.
  systemd.services.bulk-mount = lib.mkIf bulkSnapraid {
    description = "Mount and merge the bulk disks";
    unitConfig = whenUnlocked;
    wantedBy = [ "multi-user.target" ];
    # zfs-mount: the upload cache (hs share <share> cache) is a dataset on the SSD pool
    after = [ "local-fs.target" "systemd-udev-settle.service" "zfs-mount.service" ];
    wants = [ "systemd-udev-settle.service" ];
    before = [ "samba-smbd.service" "incus.service" ];
    path = [ "/run/wrappers" "/run/current-system/sw" ];
    # NEVER restart this unit during a switch. The mergerfs daemons live in its process group: a restart kills them, /bulk is mounted again
    # from scratch, and every container that holds a folder of the old mount (Jellyfin /media, Immich, the Wings backups) keeps a dead handle
    # ("Transport endpoint is not connected") until it is restarted. Every change under scripts/ changes this unit, so `hs rebuild` did it
    # (2026-10-06, Jellyfin stopped playing). The script only matters at boot and at unlock; a change takes effect at the next boot.
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = "bash ${scripts}/bulk-mount.sh";
  };
  # Parity is only as fresh as the last sync: what is new or changed since is unprotected.
  # Once a night at 03:00 by default (machine.toml: syncEveryHours; every run wakes all data disks); a sync only works on what changed.
  systemd.services.hs-bulk-sync = lib.mkIf bulkSnapraid {
    description = "Update the SnapRAID parity (hs pool bulk sync)";
    unitConfig = whenUnlocked;
    after = [ "bulk-mount.service" ];
    path = [ "/run/current-system/sw" ];
    # no parity disk: skip the run (not a failure, the health check and the status say "no parity disk")
    serviceConfig.Type = "oneshot";
    serviceConfig.ExecCondition = "${pkgs.gnugrep}/bin/grep -q '^parity ' /var/lib/snapraid/snapraid.conf";
    script = "bash ${scripts}/bulk-sync.sh";
    startAt = if syncEveryHours >= 24 then "*-*-* 03:00:00" else "*-*-* ${toString (lib.mod 3 syncEveryHours)}/${toString syncEveryHours}:00:00";   # "3/24" is not valid in systemd
    onFailure = notifyFailure;       # also when the sync is refused
  };
  # Uploads to shares with the cache switched on (hs share <share> cache) wait on the
  # SSD pool. Every sync moves them to the disks first; this timer only steps
  # in earlier when the cache is filling up.
  systemd.services.hs-cache-mover = lib.mkIf bulkSnapraid {
    description = "Move cached uploads to the bulk disks when the cache fills up (hs cache-mover)";
    unitConfig = whenUnlocked;
    after = [ "bulk-mount.service" ];
    path = [ "/run/current-system/sw" ];
    serviceConfig.Type = "oneshot";
    script = "bash ${scripts}/cache-mover.sh --if-full";
    startAt = "*:7/15";
    onFailure = notifyFailure;
  };
  systemd.services.hs-bulk-scrub = lib.mkIf bulkSnapraid {
    description = "Verify part of the bulk data against parity (hs pool bulk sync --scrub)";
    unitConfig = whenUnlocked;
    after = [ "bulk-mount.service" ];
    path = [ "/run/current-system/sw" ];
    serviceConfig.Type = "oneshot";
    serviceConfig.ExecCondition = "${pkgs.gnugrep}/bin/grep -q '^parity ' /var/lib/snapraid/snapraid.conf";
    script = "bash ${scripts}/bulk-sync.sh --scrub";
    startAt = "Sun 05:00";
    onFailure = notifyFailure;
  };
  # Containers reach shares through a 1:1 mapping of user 1000 / group 100
  # (the merged filesystem can't do id-shifted mounts); root must be allowed
  # to hand out those two ids.
  users.users.root.subUidRanges = lib.mkIf bulkSnapraid [{ startUid = 1000; count = 1; }];
  users.users.root.subGidRanges = lib.mkIf bulkSnapraid [{ startGid = 100; count = 1; }];

  # ──────────────────────── ZFS maintenance ────────────────────────
  services.zfs.autoScrub = {
    enable = true;
    # inside the maintenance window (docs/Entwicklungsnotizen.md#storage), not NixOS' default of Sunday 00:00 plus up to 6 h of random delay
    interval = "Sun *-*-* 05:00:00";
    randomizedDelaySec = "0";
  };
  services.zfs.trim.enable = true;           # periodic TRIM for the "fast" SSD pool

  # ──────────────────────── Encrypted disks ────────────────────────
  # LUKS disks (hs pool bulk add --encrypt, or adopted) and encrypted ZFS pools
  # share one passphrase. At boot, hs-unlock opens them when /var/lib/hs/disk-key
  # exists (hs unlock --setup-key); otherwise it leaves /run/hs/storage-locked,
  # sends a message, and the services below wait until someone runs `hs unlock`
  # (which starts the units listed in /etc/hs/unlock-units). Without encrypted
  # disks the unit does nothing. DefaultDependencies off: it has to run before
  # zfs-mount, which is part of local-fs.target.
  systemd.services.hs-unlock = {
    description = "Unlock encrypted disks when the key file is present (hs unlock)";
    wantedBy = [ "multi-user.target" ];
    after = [ "zfs-import.target" "systemd-udev-settle.service" ];
    wants = [ "systemd-udev-settle.service" ];
    before = [ "zfs-mount.service" "bulk-mount.service" "incus.service" "samba-smbd.service" ];
    unitConfig.DefaultDependencies = false;
    path = [ "/run/current-system/sw" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = "bash ${scripts}/unlock.sh --boot";
  };
  # While the vault is closed the server is not usable: tell the owner. hs-unlock (above) writes the marker and sends the push message
  # at once, but that is often before the network is up, so this unit repeats it after network-online until it arrives (or someone unlocks).
  systemd.services.hs-unlock-alarm = {
    description = "Push message: the vault must be unlocked (hs unlock), repeated until it arrives";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" "hs-unlock.service" ];
    unitConfig.ConditionPathExists = "/run/hs/storage-locked";
    path = [ "/run/current-system/sw" ];
    serviceConfig.Type = "oneshot";
    script = "bash ${scripts}/unlock.sh --alarm";
  };

  environment.etc."hs/unlock-units".text = lib.concatStringsSep " " (
    [ "zfs-mount.service" ]
    ++ lib.optional bulkSnapraid "bulk-mount.service"
    ++ [ "incus.service" "samba-smbd.service" ]
    ++ lib.optional (ad != null) "samba-winbindd.service"
  );

  systemd.services.zfs-mount.unitConfig = whenUnlocked;

  # Automatic snapshots of the shares (ZFS layout only; off unless machine.toml says
  # `shareSnapshots = true;`): 24 hourly, 7 daily, 4 weekly per share, see scripts/snapshots-auto.sh.
  systemd.services.hs-share-snapshots = lib.mkIf (shareSnapshots && !bulkSnapraid) {
    description = "Automatic ZFS snapshots of the shares (hs snapshots)";
    after = [ bulkReady ];
    path = [ "/run/current-system/sw" ];
    serviceConfig.Type = "oneshot";
    unitConfig = whenUnlocked;
    script = "bash ${scripts}/snapshots-auto.sh run";
    startAt = "hourly";
    onFailure = notifyFailure;
  };

  # The state database (/var/lib/hs/state.db): the one collector. Every minute it reads the disks
  # (monitor.sh --disks + lsblk) and updates the inventory, the events and the SMART readings; disk-event.sh also starts it
  # at every plug and unplug. Not after bulkReady on purpose: it must keep working while the storage is locked.
  systemd.services.hs-state-collect = {
    description = "Update the state database: disk inventory, events, SMART readings (hs sys state collect)";
    path = [ "/run/current-system/sw" pkgs.python3 ];
    serviceConfig.Type = "oneshot";
    script = "bash ${scripts}/state.sh collect";
    startAt = "minutely";
    onFailure = notifyFailure;
  };

  # (With diskSpindownMinutes > 0 these self-tests DO wake a sleeping disk and keep it busy; that is wanted. The list, the monitor and the
  # smartctl exporter read with -n standby and leave sleeping disks alone.)
  # SMART self-tests inside the disks (they stay usable): a short one every week, a long one
  # (hours) on the first of the month. A failed test makes the health check complain (disk
  # rated BAD), and so does a schedule that stopped. By hand: hs disk selftest short|long
  systemd.services.hs-selftest-short = {
    description = "Start a short SMART self-test in every disk (hs disk selftest short)";
    path = [ "/run/current-system/sw" ];
    serviceConfig.Type = "oneshot";
    script = "bash ${scripts}/selftest.sh short";
    startAt = "Sat 03:10";    # maintenance window (starts 03:00)
    onFailure = notifyFailure;
  };
  systemd.services.hs-selftest-long = {
    description = "Start a long SMART self-test in every disk (hs disk selftest long)";
    path = [ "/run/current-system/sw" ];
    serviceConfig.Type = "oneshot";
    script = "bash ${scripts}/selftest.sh long";
    startAt = "*-*-01 03:15";    # maintenance window (starts 03:00)
    onFailure = notifyFailure;
  };

  # Shares of other homeservers (hs remote add) are mounted read-only under /mnt/remote. A peer that is off
  # must never block anything, so nothing waits for the mount: this tries again every 2 minutes and
  # exits 0 either way. Only runs when something is set up.
  systemd.services.hs-remote-mount = {
    description = "Mount the shares of other homeservers (hs remote)";
    unitConfig.ConditionPathExists = [ "!/run/hs/storage-locked" "/var/lib/hs/remote-mounts" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ "/run/current-system/sw" "/run/wrappers" ];
    serviceConfig.Type = "oneshot";
    script = "bash ${scripts}/remote.sh mount-all";
    startAt = "*:0/2";
  };

  # Standby timer for the spinning bulk/parity/backup disks (machine.toml: diskSpindownMinutes > 0; scripts/disk-spindown.sh).
  # The disks lose the setting on a power cycle, so it runs at boot, after the bulk mount, and again when a disk appears.
  # Nothing to do (and no unit) while the option is 0: a disk set earlier is back to normal after the next power-off.
  systemd.services.hs-disk-spindown = lib.mkIf (diskSpindownMinutes > 0) {
    description = "Let the spinning bulk disks sleep when idle (hs disk spindown)";
    unitConfig = whenUnlocked;
    wantedBy = [ "multi-user.target" ];
    after = [ "bulk-mount.service" "zfs-mount.service" "systemd-udev-settle.service" ];
    path = [ "/run/current-system/sw" ];
    serviceConfig.Type = "oneshot";
    script = "bash ${scripts}/disk-spindown.sh apply";
    onFailure = notifyFailure;
  };

  # A disk was plugged in or taken out (started by the udev rule above). %i = "<action>-<kernel name>".
  # scripts/disk-event.sh logs it to /var/lib/hs/disk-events and sends a push message; see: hs disk events
  systemd.services."hs-disk-event@" = {
    description = "Disk event: %i";
    path = [ "/run/current-system/sw" ];
    serviceConfig.Type = "oneshot";
    scriptArgs = "%i";
    script = ''
      action=''${1%%-*}
      name=''${1#*-}
      bash ${scripts}/disk-event.sh "$action" "$name"
    '';
  };

  # pciBind (machine.toml): a PCI device that stays without a driver after every boot. Seen on a 9300-16i HBA (two SAS3008
  # chips behind a PLX switch): the second chip (05:00.0) was never probed by mpt3sas, binding it by hand later worked. This
  # service attaches the listed devices early (before the pools are imported, the disks may sit behind them) and keeps a log
  # of what the device looked like before and after in /var/lib/hs/pci-bind.log, to find the real cause. Writes only to that log.
  systemd.services.hs-pci-bind = lib.mkIf (pciBind != [ ]) {
    description = "Attach PCI devices that stay without a driver at boot";
    wantedBy = [ "sysinit.target" ];
    before = [ "sysinit.target" "zfs-import.target" "zfs-import-fast.service" "hs-unlock.service" "bulk-mount.service" ];
    after = [ "systemd-modules-load.service" "systemd-udevd.service" "systemd-udev-trigger.service" ];
    unitConfig.DefaultDependencies = false;
    path = with pkgs; [ coreutils gnugrep util-linux kmod systemd ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; TimeoutStartSec = "20min"; };
    onFailure = notifyFailure;
    script = ''
      log=/var/lib/hs/pci-bind.log
      mkdir -p /var/lib/hs
      # state of one device, one line each, to the log
      snap() {
        d=/sys/bus/pci/devices/$2
        drv=none; [ -L "$d/driver" ] && drv=$(basename "$(readlink "$d/driver")")
        mods=$(modprobe -R "$(cat "$d/modalias")" 2>/dev/null | tr '
' ' ' || true)
        echo "[$1] $2 id=$(cat "$d/vendor") $(cat "$d/device") enable=$(cat "$d/enable") runtime=$(cat "$d/power/runtime_status" 2>/dev/null || echo ?) driver=$drv module=$mods"
        echo "[$1] parent=$(basename "$(dirname "$(readlink -f "$d")")") iommu_group=$(basename "$(readlink "$d/iommu_group" 2>/dev/null || echo ?)") uptime=$(cut -d' ' -f1 /proc/uptime)s"
        for m in $mods; do echo "[$1] module $m initstate=$(cat "/sys/module/$m/initstate" 2>/dev/null || echo not-loaded)"; done
      }
      {
        echo "=== $(date -Is) boot $(cut -c1-8 /proc/sys/kernel/random/boot_id) kernel $(uname -r)"
        echo "cmdline: $(cat /proc/cmdline)"
      } >> "$log"
      for addr in ${lib.escapeShellArgs pciBind}; do
        dev=/sys/bus/pci/devices/$addr
        if [ ! -d "$dev" ]; then echo "$addr: not on the PCI bus" >> "$log"; continue; fi
        snap before "$addr" >> "$log"
        echo "[before] kernel lines about it:" >> "$log"
        { dmesg | grep -iE "$addr|mpt3sas|pcieport|aer:" | tail -40 || true; } | sed 's/^/    /' >> "$log"
        if [ -L "$dev/driver" ]; then echo "[$addr] already has a driver, nothing to do" >> "$log"; continue; fi
        start=$(cut -d' ' -f1 /proc/uptime)
        for m in $(modprobe -R "$(cat "$dev/modalias")" 2>/dev/null || true); do modprobe "$m" || true; done
        echo "$addr" > /sys/bus/pci/drivers_probe 2>> "$log" || echo "[$addr] drivers_probe failed" >> "$log"
        if [ ! -L "$dev/driver" ]; then
          for m in $(modprobe -R "$(cat "$dev/modalias")" 2>/dev/null || true); do
            echo "$addr" > "/sys/bus/pci/drivers/$m/bind" 2>> "$log" || true
          done
        fi
        udevadm settle --timeout=300 || true
        echo "[$addr] attach took $(( $(cut -d' ' -f1 /proc/uptime | cut -d. -f1) - ''${start%.*} ))s" >> "$log"
        snap after "$addr" >> "$log"
        [ -L "$dev/driver" ] || { echo "$addr: still without a driver" >> "$log"; exit 1; }
      done
    '';
  };
}
