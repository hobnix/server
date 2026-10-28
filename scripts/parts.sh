#!/usr/bin/env bash
# help: the optional parts (capabilities) of this server as data: which are on, which bring a NixOS module
# help.de: die optionalen Teile (Capabilities) dieses Servers als Daten: welche an sind, welche ein NixOS-Modul mitbringen
# args: --list
# System command (hs sys parts list), read only, for the Settings page of the web interface (part switches). One part per line, tab separated, no empty field:
#   name, state (on|off), kind (extension|part), nix (yes = switching it needs hs rebuild), switch (yes = machine.toml can switch it; no = it follows the role or an old
#   setting), title. A part is `extension` when its capability.toml says extension = true (hs ext enable|disable switches it at once when it has no module).
# Test knobs: HS_PACKAGES_DIR, HS_CAPABILITIES_FILE, HS_STATE_DIR, HS_MACHINE_FILE.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/registry-load.sh"

[ "${1:-}" = --list ] || { echo "usage: parts.sh --list" >&2; exit 1; }

title_of() { sed -n 's/^title[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$1/capability.toml" | head -n 1; }

declare -A seen=()
while IFS= read -r root; do
  for d in "$root"/*/; do
    [ -f "${d}capability.toml" ] || continue
    n=$(basename "$d")
    [[ "$n" =~ ^[a-z][a-z0-9-]{0,30}$ ]] || continue
    [ -z "${seen[$n]:-}" ] || continue
    seen[$n]=1
    if capability_on "$n"; then st=on; else st=off; fi
    if grep -qE '^extension[[:space:]]*=[[:space:]]*true' "${d}capability.toml" 2>/dev/null; then kind=extension; else kind=part; fi
    if [ -f "${d}module.nix" ]; then nix=yes; else nix=no; fi
    # the edge parts follow the role; they are not switched here
    case "$n" in edge-*) sw=no ;; *) sw=yes ;; esac
    t=$(title_of "${d%/}"); [ -n "$t" ] || t=$n
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$st" "$kind" "$nix" "$sw" "${t//$'\t'/ }"
  done
done < <(_ext_roots) | sort
