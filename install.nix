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
in
{
  imports = [ ./hardware-configuration.nix ];

  boot.loader.grub = lib.mkIf grub { enable = true; device = machine.bootDevice; efiSupport = true; efiInstallAsRemovable = true; };
  boot.loader.systemd-boot.enable = lib.mkIf (!grub) true;
  boot.loader.efi.canTouchEfiVariables = lib.mkIf (!grub) true;

  boot.supportedFilesystems = lib.optionals home [ "zfs" ];
  boot.zfs.forceImportRoot = lib.mkIf home false;

  networking.hostName = machine.hostName;
  networking.hostId = lib.mkIf home machine.hostId;   # required by ZFS, must stay the same later
  networking.useDHCP = true;            # any NIC; bridges and VLANs come with the full config

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  users.users.adminuser = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = machine.sshKeys;
  };

  environment.systemPackages = with pkgs; [
    vim
    git
  ] ++ lib.optionals home [
    smartmontools   # smartctl, to check the disks before creating the pools
    newt            # whiptail, the disk menu of scripts/manage-pool.sh
    mergerfs snapraid attr jq rsync   # bulkType = "snapraid"
  ];

  # so scripts/manage-pool.sh knows how /bulk is meant to be built
  environment.etc."hs/bulk-type" = lib.mkIf home { text = machine.bulkType; };

  system.stateVersion = "26.05";
}
