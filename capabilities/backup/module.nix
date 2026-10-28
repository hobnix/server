{ config, lib, pkgs, hs, ... }:

let
  inherit (hs) bulkReady whenUnlocked notifyFailure;
  scripts = hs.scripts;
in
{
  # Nightly backup to the disk labelled "backup" (hs backup). Mounts it, backs
  # up, unmounts. Does nothing until `hs backup init` has been run once.
  # After the SnapRAID sync at 03:00 and the nightly housekeeping.
  systemd.services.hs-backup = {
    description = "Back up shares, containers and host files with restic (hs backup)";
    unitConfig = whenUnlocked;
    after = [ bulkReady "incus.service" ];
    path = [ "/run/current-system/sw" "/run/wrappers" ];
    serviceConfig = {
      Type = "oneshot";
      Nice = 10;
      IOSchedulingClass = "idle";
    };
    script = "bash ${scripts}/backup.sh now --scheduled";
    startAt = "04:00";
    onFailure = notifyFailure;
  };

  # A backup nobody has restored from is a hope: once a month restore a few random files from the
  # newest backup and compare them. The health check complains when no drill succeeded for 45
  # days. Only when the backup is set up (the password file exists).
  systemd.services.hs-backup-drill = {
    description = "Restore a few files from the backup and compare them (hs backup drill)";
    unitConfig.ConditionPathExists = [ "!/run/hs/storage-locked" "/var/lib/hs/restic-password" ];
    after = [ bulkReady "incus.service" ];
    path = [ "/run/current-system/sw" "/run/wrappers" ];
    serviceConfig = {
      Type = "oneshot";
      Nice = 10;
      IOSchedulingClass = "idle";
    };
    script = "bash ${scripts}/backup.sh drill 5";
    startAt = "*-*-15 05:30";
    onFailure = notifyFailure;
  };

  # The same for containers: once a month the container drilled longest ago is restored from its snapshot into a
  # throwaway Incus instance (no network card), started, and deleted again; the domain backup file is unpacked.
  # The health check complains when no container drill succeeded for 90 days (after the first one worked).
  systemd.services.hs-backup-drill-ct = {
    description = "Restore a container into a throwaway instance and boot it (hs backup drill ct)";
    unitConfig.ConditionPathExists = [ "!/run/hs/storage-locked" "/var/lib/hs/restic-password" ];
    after = [ bulkReady "incus.service" ];
    path = [ "/run/current-system/sw" "/run/wrappers" ];
    serviceConfig = {
      Type = "oneshot";
      Nice = 10;
      IOSchedulingClass = "idle";
    };
    script = "bash ${scripts}/backup.sh drill ct";
    startAt = "*-*-22 05:30";
    onFailure = notifyFailure;
  };

  # The picture of the restore drills as one push message, once a month after both drills have run (15th and 22nd):
  # when each check last worked, which tries failed, the off-site copy, how many guides were checked on the server.
  # It reads the state files only (no disk, no restic), so it needs no bulk mount; "high" priority when something is overdue.
  systemd.services.hs-backup-report = {
    description = "Monthly report of the restore drills as a push message (hs backup report)";
    unitConfig.ConditionPathExists = [ "/var/lib/hs/restic-password" ];
    path = [ "/run/current-system/sw" "/run/wrappers" ];
    serviceConfig = {
      Type = "oneshot";
      Nice = 10;
    };
    script = "bash ${scripts}/backup.sh report --scheduled";
    startAt = "*-*-25 08:00";
    onFailure = notifyFailure;
  };
}
