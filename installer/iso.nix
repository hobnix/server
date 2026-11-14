# The installer ISO of this repository (docs/PLAN-modular-core.md step 10a).
#
# It is the minimal NixOS installer image plus a copy of this repository (/etc/hs-installer) and one command, `hs-install`, which
# asks for the system disk, the server name, an SSH key and a preset and then installs the minimal system (install.nix) with a copy of
# the repository in /etc/nixos. Build it with scripts/dev/build-iso.sh. Nothing here is the server's own configuration.
{ pkgs, modulesPath, lib, ... }:
let
  # the repository without what a server does not need (git history, build leftovers, tests, local agent files)
  skip = [ ".git" "node_modules" "target" "__pycache__" "tests" ".claude" ];
  skipped = name: builtins.elem name skip || lib.hasPrefix "result" name;
  repo = builtins.path {
    path = ../.;
    name = "homeserver-repo";
    filter = path: _type: !(skipped (baseNameOf path));
  };
  hsInstall = pkgs.writeShellScriptBin "hs-install" ''
    exec ${pkgs.bash}/bin/bash /etc/hs-installer/scripts/install-wizard.sh "$@"
  '';
  # UNVERIFIED: not tested on hardware (issue #254): restore a server from its backup disk and password
  hsRestore = pkgs.writeShellScriptBin "hs-restore" ''
    exec ${pkgs.bash}/bin/bash /etc/hs-installer/scripts/install-restore.sh "$@"
  '';
  # the version this stick was built from (scripts/dev/build-iso.sh sets HS_ISO_DESCRIBE and HS_ISO_COMMIT; empty when built by hand: the old
  # file name, and the installer then makes no git checkout). Issue #400; the installer reads it for the git checkout (issue #396).
  describe = builtins.getEnv "HS_ISO_DESCRIBE";
  commit = builtins.getEnv "HS_ISO_COMMIT";
in
{
  imports = [ "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix" ];

  # homeserver-installer-v0.1.0.iso (the tag of a release build); homeserver-installer.iso without a version. The volume label stays
  # HS_INSTALLER (at most 32 characters, and the boot menu looks for it). The image module names the file "<image.baseName>.iso": setting
  # image.fileName has no effect on the file (seen on NixOS 26.05, 2026-11-10: the ISO was called nixos-minimal-26.05...iso).
  image.baseName = lib.mkForce (if describe == "" then "homeserver-installer" else "homeserver-installer-${describe}");
  isoImage.volumeID = lib.mkForce "HS_INSTALLER";

  # the console also on the serial port: a server without a screen, and `incus console` of a test VM, show the installer
  boot.kernelParams = [ "console=tty0" "console=ttyS0,115200n8" ];

  environment.etc."hs-installer".source = repo;
  environment.etc."hs-installer-version".text = "describe=${if describe == "" then "-" else describe}\ncommit=${if commit == "" then "-" else commit}\n";
  environment.systemPackages = [ hsInstall hsRestore pkgs.python3 pkgs.parted pkgs.gum pkgs.gptfdisk pkgs.restic ];

  # what a person sees on the console after booting the stick
  services.getty.helpLine = lib.mkForce ''

    Homeserver installer.

      hs-install      install a new server (asks for the system disk, a name, an SSH key and a preset;
                      with no options it first asks: New install or Restore from backup)
      hs-restore      restore a server from its backup disk and the backup password (UNVERIFIED: not tested on hardware)

    Only the disk you pick and type the name of is erased. Guide: /etc/hs-installer/docs/install.md
  '';
}
