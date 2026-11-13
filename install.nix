# Minimal system for the first installation of a new server.
#
# It boots, gets an address via DHCP, lets adminuser in over SSH and can
# create ZFS pools. No Incus, Samba, NVIDIA or web UIs: those are in
# configuration.nix, which needs the pools "fast" and "bulk" to exist.
#
#   NIXOS_CONFIG=/mnt/etc/nixos/install.nix nixos-install
#
# After the first boot create the pools, then `sudo nixos-rebuild switch`
# applies configuration.nix. Details: README, "New server".
{ lib, pkgs, ... }:

let
  # Only hostId and sshKeys are needed here; the rest of machine.toml can be
  # filled in before switching to the full configuration.
  # The defaults of the options are written down once, in config/schema.toml (config/defaults.nix is made from it);
  # what machine.toml says wins. Options whose default refers to another setting (siteName) keep an `or` below.
  machine = import ./config/defaults.nix // (if builtins.pathExists ./machine.toml
    then builtins.fromTOML (builtins.readFile ./machine.toml)
    else import ./machine.nix);   # an old server until `hs config migrate` has run
  # The role (machine.toml: role): only the home server has pools. An edge node or a minimal one needs no ZFS and no hostId.
  home = machine.role == "homeserver";
  # GRUB on a given disk for a machine that boots with BIOS (a VPS); the installer wizard writes bootDevice then
  grub = machine.bootDevice != "";
  # The web interface (docs/PLAN-first-run-wizard.md decision 1): the installer sets webUi = true in machine.toml, so the first dashboard needs
  # no console rebuild. The package is taken from the binary cache when it has it (ADR 0003), else built from web/ during nixos-install. LAN only, never a public route (.claude/rules/web.md).
  webUi = machine.webUi;
  webPort = machine.webPort;
  hsWeb = pkgs.callPackage ./pkgs/hs-web.nix { };
  adminUser = machine.adminUser;
  hsCommand = import ./hs-command.nix { inherit pkgs; };
in
{
  imports = [ ./hardware-configuration.nix ];

  boot.loader.grub = lib.mkIf grub { enable = true; device = machine.bootDevice; efiSupport = true; efiInstallAsRemovable = true; };
  boot.loader.systemd-boot.enable = lib.mkIf (!grub) true;
  boot.loader.efi.canTouchEfiVariables = lib.mkIf (!grub) true;
  # the same consoles as configuration.nix: the screen is the main one, the first serial port gets a login prompt too
  boot.kernelParams = [ "console=ttyS0,115200n8" "console=tty0" ];

  boot.supportedFilesystems = lib.optionals home [ "zfs" ];
  boot.zfs.forceImportRoot = lib.mkIf home false;

  networking.hostName = machine.hostName;
  networking.hostId = lib.mkIf home machine.hostId;   # required by ZFS, must stay the same later
  networking.useDHCP = true;            # any NIC; bridges and VLANs come with the full config

  # <hostName>.local for a PC on the same network (decision 3); the IP in the banner is the fallback when mDNS does not work there
  services.avahi = lib.mkIf webUi {
    enable = true;
    openFirewall = true;
    publish = { enable = true; addresses = true; };
  };

  # Same rule as configuration.nix: the port is open to private addresses only (home networks), never to a public one.
  networking.nftables.enable = lib.mkIf webUi true;
  networking.firewall.extraInputRules = lib.mkIf webUi ''
    ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } tcp dport ${toString webPort} accept
  '';

  # ONE process on the host as root, the same unit as in configuration.nix (which replaces it after `hs rebuild`): scripts/web-serve.py.
  # Only the local adminuser can sign in here (no Samba, no domain).
  systemd.services.hs-web = lib.mkIf webUi {
    description = "Web interface (port ${toString webPort})";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    path = [ "/run/current-system/sw" ];
    environment = {
      HS_CALLER = "web";
      HS_WEB_PORT = toString webPort;
      HS_WEB_ROOT = "${hsWeb}";
      HS_WEB_BIND = "";
      HS_WEB_SECURE = "";
      HS_WEB_LOCAL_USER = adminUser;
      HS_WEB_UNLOCK_IN_UNIT = "1";
      HS_WEB_SESSION_FILE = "/run/hs-web/sessions.json";
    };
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 ${./scripts}/web-serve.py";
      Restart = "on-failure";
      PrivateTmp = true;
      NoNewPrivileges = true;
      RuntimeDirectory = "hs-web";
      RuntimeDirectoryMode = "0700";
      RuntimeDirectoryPreserve = "yes";
    };
  };

  # The one-time setup code (docs/adr/0022-first-run-console-token.md): shown on the screen and the serial port at every boot while the
  # installer's flag says `pending`. Rule 3 of the record: the output goes to the console device ONLY, never to the journal (StandardOutput=tty
  # instead of journal) and never to /etc/issue. A server without the flag (an upgraded one) prints nothing.
  systemd.services.hs-setup-code = lib.mkIf webUi (import ./setup-code-unit.nix { inherit pkgs hsCommand webPort; });

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  environment.etc."hs/admin-user".text = adminUser;

  users.users.${adminUser} = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = machine.sshKeys;
  };

  environment.systemPackages = with pkgs; [
    vim
    git
    python3         # the scripts behind `hs` (machine.toml is read with it): without it the first `hs rebuild` fails
    hsCommand   # the `hs` command from the first boot on (also in configuration.nix)
  ] ++ lib.optionals home [
    smartmontools   # smartctl, to check the disks before creating the pools
    newt            # whiptail, the disk menu of scripts/manage-pool.sh
    mergerfs snapraid attr jq rsync   # bulkType = "snapraid"
  ];

  # so scripts/manage-pool.sh knows how /bulk is meant to be built
  environment.etc."hs/bulk-type" = lib.mkIf home { text = machine.bulkType; };

  system.stateVersion = "26.05";
}
