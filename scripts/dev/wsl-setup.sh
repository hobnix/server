#!/usr/bin/env bash
# One-time setup of a Debian WSL for the root tests of this repository (docs/dev-environment.md). Run it INSIDE the WSL as your normal user:
#
#   wsl -d Debian -- bash /mnt/c/<path to the repository>/scripts/dev/wsl-setup.sh
#
# It installs the tools the tests use and (asks first) allows passwordless sudo for this user, so tests can use loop devices without a password
# prompt. Do that only on a machine that holds nothing you care about as root: a development WSL is such a machine.
# It changes nothing on Windows and nothing outside this WSL. The kernel of WSL2 has no ZFS: ZFS tests run in CI or in the throwaway VM (t vm).
set -euo pipefail
[ "$(id -u)" -ne 0 ] || { echo "run it as your normal user (it uses sudo itself)"; exit 1; }
[ -r /etc/debian_version ] || { echo "this script is for Debian"; exit 1; }
pkgs=(python3 python3-pil shellcheck jq git rsync nodejs npm restic cryptsetup-bin snapraid smartmontools mergerfs
      util-linux bsdextrautils e2fsprogs xfsprogs dosfstools openssh-client curl tmux ca-certificates)
echo "Installing: ${pkgs[*]}"
sudo apt-get update -qq
sudo apt-get install -y -qq "${pkgs[@]}"
sudo -k   # forget the password just typed, or the check below always passes
if sudo -n true 2>/dev/null; then
  echo "Passwordless sudo is on already."
else
  read -r -p "Allow passwordless sudo for $(id -un) in THIS WSL? [y/N] " a
  if [ "$a" = y ] || [ "$a" = Y ]; then
    echo "$(id -un) ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/hobnix-dev >/dev/null
    sudo chmod 0440 /etc/sudoers.d/hobnix-dev
    echo "Done: /etc/sudoers.d/hobnix-dev (remove the file to undo)."
  fi
fi
echo; echo "Checks:"
for c in python3 shellcheck node jq restic cryptsetup snapraid mergerfs losetup mkfs.ext4 rsync; do
  if command -v "$c" >/dev/null 2>&1; then echo "  ok    $c"; else echo "  MISSING $c"; fi
done
[ -e /dev/loop0 ] && echo "  ok    loop devices" || echo "  MISSING loop devices"
echo; echo "Next, from the repository on Windows (Git Bash):  scripts/dev/t wsl quick   |   scripts/dev/t wsl root"
