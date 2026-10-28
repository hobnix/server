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
in
{
  imports = [ "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix" ];

  image.fileName = lib.mkForce "homeserver-installer.iso";
  isoImage.volumeID = lib.mkForce "HS_INSTALLER";

  # the console also on the serial port: a server without a screen, and `incus console` of a test VM, show the installer
  boot.kernelParams = [ "console=tty0" "console=ttyS0,115200n8" ];

  environment.etc."hs-installer".source = repo;
  environment.systemPackages = [ hsInstall pkgs.python3 pkgs.parted pkgs.gum pkgs.gptfdisk ];

  # what a person sees on the console after booting the stick
  services.getty.helpLine = lib.mkForce ''

    Homeserver installer.

      hs-install      install a new server (asks for the system disk, a name, an SSH key and a preset)

    Only the disk you pick and type the name of is erased. Guide: /etc/hs-installer/docs/install.md
  '';
}
