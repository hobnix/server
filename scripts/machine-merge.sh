#!/usr/bin/env bash
# help: old name of hs config sync / hs config migrate (kept for one release)
# help.de: alter Name von hs config sync / hs config migrate (noch ein Release lang)
# args: [--check]
# Transition shim: the update that brings machine.toml still runs the OLD update.sh, which calls this script
# from the new checkout. A server that still has machine.nix gets it converted here, one that has machine.toml
# gets its layout synced. Remove with the Nix fallback to machine.nix.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/machine.sh"
if [ -f "$(machine_file)" ]; then
  exec bash "$here/machine-sync.sh" sync "$@"
elif [ -f "$(dirname "$(machine_file)")/machine.nix" ] && [ "${1:-}" != --check ]; then
  exec bash "$here/machine-sync.sh" migrate
fi
