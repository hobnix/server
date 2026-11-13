# The boot unit of the one-time setup code (docs/adr/0022-first-run-console-token.md), shared by install.nix and configuration.nix.
# Rule 3 of the record: stdout goes to the console device only (StandardOutput=tty), never to the journal and never to the login banner.
{ pkgs, hsCommand, webPort }:
{
  description = "Show the one-time setup code on the console (only while the first setup is pending)";
  wantedBy = [ "multi-user.target" ];
  after = [ "network.target" "hs-web.service" ];
  wants = [ "hs-web.service" ];
  path = [ hsCommand pkgs.bash pkgs.python3 pkgs.gnused pkgs.util-linux pkgs.findutils pkgs.iproute2 pkgs.gawk pkgs.gnugrep pkgs.coreutils pkgs.hostname ];
  environment = { HS_WEB_PORT = toString webPort; HS_STATE_DIR = "/var/lib/hs"; };
  unitConfig.ConditionPathExists = "/var/lib/hs/first-run.json";
  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
    ExecStart = "${hsCommand}/bin/hs setup-code boot";
    StandardOutput = "tty";
    StandardError = "journal";   # only fixed refusal texts: the code goes to stdout only
    TTYPath = "/dev/console";
  };
}
