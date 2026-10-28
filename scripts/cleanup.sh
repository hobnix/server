#!/usr/bin/env bash
# help: find leftovers (old containers and services, stale mounts, old generations); only reports, changes nothing
# help.de: Überbleibsel finden (alte Container und Dienste, verwaiste Einhängepunkte, alte Generationen); meldet nur, ändert nichts
# args: [--list]
# Every finding has the command that removes it. --list = kind<TAB>what<TAB>fix, for other scripts.
# HS_INCUS, HS_STATE_DIR, HS_WEBZFS_DIR, HS_TEMP_DIR, HS_GENERATIONS point tests at stand-ins.
set -uo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
incus=${HS_INCUS:-incus}
state=${HS_STATE_DIR:-/var/lib/hs}
webzfs=${HS_WEBZFS_DIR:-/var/lib/webzfs}
temp=${HS_TEMP_DIR:-/mnt/temp}

list=false
case "${1:-}" in
  --list) list=true ;;
  "") ;;
  *) say "usage: hs cleanup [--list]"; exit 1 ;;
esac

found=()
add() { found+=("$1"$'\t'"$2"$'\t'"$3"); }   # add <kind> <what> <fix>

# the LDAP Account Manager container: replaced by hs user / hs group
if "$incus" list -c n -f csv 2>/dev/null </dev/null | grep -qx lam; then
  add container "The container 'lam' (LDAP Account Manager) is not needed any more; hs user and hs group replaced it" "hs ct lam remove"
fi

# WebZFS: the service, its user and its state are gone from the configuration
if [ -d "$webzfs" ]; then
  add leftover "$webzfs is left over from WebZFS (certificate, session key)" "sudo rm -rf $webzfs"
fi
if getent passwd webzfs >/dev/null 2>&1 && [ -z "${HS_NO_PASSWD:-}" ]; then
  add leftover "The system user 'webzfs' still exists (the next hs rebuild removes it with its group)" "hs rebuild"
fi

# disks mounted with `hs disk temp` that nobody ejected
if [ -d "$temp" ]; then
  for d in "$temp"/*/; do
    [ -d "$d" ] || continue
    n=$(basename "$d")
    if mountpoint -q "$d" 2>/dev/null; then
      add mount "The temporary disk '$n' is still mounted and shared as temp-$n" "hs disk temp eject $n"
    else
      add mount "$d is an empty leftover folder of a temporary disk" "sudo rmdir $d"
    fi
  done
fi

# stopped containers (not removed: the owner decides, this only says)
stopped=$("$incus" list -c ns -f csv 2>/dev/null </dev/null | awk -F, '$2 == "STOPPED" { print $1 }' || true)
for c in $stopped; do
  [ "$c" != lam ] || continue
  add container "The container '$c' is stopped" "hs ct $c start   (or: hs ct $c remove)"
done

# many old system generations keep old programs on the disk
gens=${HS_GENERATIONS:-$(nix-env -p /nix/var/nix/profiles/system --list-generations 2>/dev/null | wc -l || true)}
if [ "${gens:-0}" -gt 15 ]; then
  add generations "$gens system generations are kept" "hs system gc"
fi

# copies the tools made before they changed machine.toml (or the old machine.nix)
old=$(find "$state" -maxdepth 1 \( -name 'machine.toml.before-*' -o -name 'machine.nix.before-*' \) 2>/dev/null | wc -l)
if [ "$old" -gt 0 ]; then
  add copy "$old copies of machine.toml from before a change (in $state)" "ls $state/machine.*.before-*"
fi

if $list; then
  for f in "${found[@]}"; do printf '%s\n' "$f"; done
  exit 0
fi

if [ ${#found[@]} -eq 0 ]; then status_line "Leftovers" "None" ok; exit 0; fi
status_line "Leftovers" "${#found[@]}" warn
for f in "${found[@]}"; do
  IFS=$'\t' read -r _ what fix <<<"$f"
  warn "$what"
  note "-> $fix"
done
echo
note "This only reports. Nothing was changed."
