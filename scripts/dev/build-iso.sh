#!/usr/bin/env bash
# Builds the installer ISO (installer/iso.nix) and prints where it is: ./result/iso/homeserver-installer.iso.
# Needs nix with a channel or NIX_PATH that has nixpkgs. In WSL: wsl -d Debian -- bash -lc "cd <repo> && bash scripts/dev/build-iso.sh".
#   --eval   only evaluate (a few minutes, no download of the image's contents): proves the configuration is sound
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo"
if [ "${1:-}" = --eval ]; then
  nix-instantiate '<nixpkgs/nixos>' -A config.system.build.isoImage -I nixos-config=installer/iso.nix >/dev/null
  echo "installer/iso.nix evaluates"
  exit 0
fi
nix-build '<nixpkgs/nixos>' -A config.system.build.isoImage -I nixos-config=installer/iso.nix -o result-iso
ls -lh result-iso/iso/*.iso
