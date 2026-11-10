# The capability "testlab" (capabilities/testlab/NOTES.md): the nightly run of `hs testlab run --ref develop`. UNVERIFIED: never evaluated on a
# server. The service starts the command; the command itself starts the job (scripts/testlab.sh), so the run shows on the Jobs page.
# Loaded by capabilities/default.nix only while `testlab` is in `capabilities`. The timer exists only with testlabNightly = true.
{ config, lib, pkgs, hs, ... }:

{
  systemd.services.hs-testlab-nightly = {
    description = "Test-lab: build the installer ISO of develop and run it in a nested VM";
    path = [ "/run/current-system/sw" pkgs.git pkgs.nix pkgs.openssh pkgs.python3 ];
    environment.HS_CALLER = "timer";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.bash}/bin/bash ${hs.scripts}/testlab.sh run --ref develop --stage all --yes --background";
    };
    onFailure = hs.notifyFailure;
  };

  systemd.timers.hs-testlab-nightly = lib.mkIf hs.machine.testlabNightly {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:30:00";
      RandomizedDelaySec = "20min";
      Persistent = false;   # a missed night is not caught up at boot: the ISO build is heavy
    };
  };
}
