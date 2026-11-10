# The capability "testlab" (capabilities/testlab/NOTES.md): the nightly run of `hs testlab run --ref develop`. UNVERIFIED: never evaluated on a
# server. The service starts the command; the command itself starts the job (scripts/testlab.sh), so the run shows on the Jobs page.
# Loaded by capabilities/default.nix only while `testlab` is in `capabilities`. The timer exists only with testlabNightly = true.
{ config, lib, pkgs, hs, ... }:

{
  systemd.services.hs-testlab-nightly = {
    description = "Test-lab: build the installer ISO of develop and run stages 1 to 6 in nested VMs";
    # stage 6 (a headless browser opens every web page) needs playwright and its browsers; UNVERIFIED: never evaluated here
    path = [ "/run/current-system/sw" pkgs.git pkgs.nix pkgs.openssh (pkgs.python3.withPackages (ps: [ ps.playwright ])) ];
    environment = {
      HS_CALLER = "timer";
      PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
      PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS = "true";
    };
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
