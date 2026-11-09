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
# the version goes into the file name (homeserver-installer-<describe>.iso) and /etc/hs-installer-version; a tree with local changes names no
# commit, so a stick built from it makes no git checkout (scripts/lib/checkout.sh). HS_ISO_DESCRIBE / HS_ISO_COMMIT in the environment win (CI).
if [ -z "${HS_ISO_DESCRIBE+x}" ]; then
  HS_ISO_DESCRIBE=$(git describe --tags --always 2>/dev/null || true)
  # CI checks out one commit without tags (actions/checkout): on a tag build the tag is the version
  if [ "${GITHUB_REF_TYPE:-}" = tag ] && [ -n "${GITHUB_REF_NAME:-}" ]; then HS_ISO_DESCRIBE=$GITHUB_REF_NAME; fi
  if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then HS_ISO_DESCRIBE=${HS_ISO_DESCRIBE:+$HS_ISO_DESCRIBE-}dirty; HS_ISO_COMMIT=""; fi
fi
[ -n "${HS_ISO_COMMIT+x}" ] || HS_ISO_COMMIT=$(git rev-parse HEAD 2>/dev/null || true)
export HS_ISO_DESCRIBE HS_ISO_COMMIT
nix-build '<nixpkgs/nixos>' -A config.system.build.isoImage -I nixos-config=installer/iso.nix -o result-iso
ls -lh result-iso/iso/*.iso
