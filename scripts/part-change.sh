#!/usr/bin/env bash
# help: switch an optional part (capability) of this server on or off without asking anything: what would happen (plan), then do it (start)
# help.de: einen optionalen Teil (Capability) dieses Servers an- oder ausschalten, ohne etwas zu fragen: was passieren würde (plan), dann ausführen (start)
# args: plan|start enable|disable <part>
# System command (hs sys parts plan|start): for the interface and tests. It never asks and prints plain key<TAB>value lines like expiry-change.sh.
# An extension without a NixOS module is switched by `hs ext enable|disable` and is on or off at once. Any other part is a line in machine.toml
# (`capabilities`) and takes effect with the next `hs rebuild` (the plan says so). Parts of the edge role (edge-*) follow the role and are refused here.
# Turning a part with a module OFF is red (the typed word is its name): its services stop at the next rebuild.
# plan: exit 0 = allowed, 1 = refused. Output: status ok|refused, reason<TAB><text>, heading|step|note|warn|danger|command<TAB><line>, confirm_name<TAB><name>, long<TAB>no.
# start: the same checks, then status<TAB>done.
# Test knobs: HS_EXT (stand-in for ext.sh), HS_PARTS (stand-in for parts.sh), HS_MACHINE_FILE.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/machine.sh"
ext=${HS_EXT:-$here/ext.sh}
parts=${HS_PARTS:-$here/parts.sh}

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

verb=${1:-}; action=${2:-}; name=${3:-}
case "$verb" in plan|start) ;; *) echo "usage: part-change.sh plan|start enable|disable <part>" >&2; exit 1 ;; esac
case "$action" in enable|disable) ;; *) refuse "unknown action (enable or disable)" ;; esac
[[ "$name" =~ ^[a-z][a-z0-9-]{0,30}$ ]] || refuse "not a part name"
[ $# -eq 3 ] || refuse "unexpected extra arguments"
export HS_PLAIN=1 HS_LANG=en HS_CALLER=${HS_CALLER:-ui}
unset HS_GUIDED_TTY

row=$(bash "$parts" --list 2>/dev/null | awk -F'\t' -v n="$name" '$1 == n { print; exit }')
[ -n "$row" ] || refuse "There is no part called $name."
IFS=$'\t' read -r _ st kind nix sw _ <<<"$row"
[ "$sw" = yes ] || refuse "$name follows the role of this server; it is not switched here."
if [ "$action" = enable ] && [ "$st" = on ]; then refuse "$name is on already."; fi
if [ "$action" = disable ] && [ "$st" = off ]; then refuse "$name is off already."; fi

caps_list() { machine_has capabilities || return 0; machine_get capabilities 2>/dev/null || true; }
caps_write() { local v="" n; for n in "$@"; do v+="${v:+, }\"$n\""; done; machine_set capabilities "[$v]" ext; }

if [ "$kind" = extension ]; then cmd=(bash "$ext" "$action" "$name"); else cmd=(machine.toml capabilities "$action" "$name"); fi

if [ "$verb" = start ]; then
  if [ "$kind" = extension ]; then
    rc=0; out=$("${cmd[@]}" </dev/null 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
      printf 'status\trefused\nreason\t%s\n' "$(printf '%s' "$out" | sed -e 's/^[[:space:]]*//' -e 's/^[✗!] *//' | awk 'NF' | tail -n 1)"
      exit 1
    fi
  else
    mapfile -t cur < <(caps_list)
    keep=()
    for x in ${cur[@]+"${cur[@]}"}; do [ "$x" = "$name" ] || keep+=("$x"); done
    if [ "$action" = enable ]; then keep+=("$name"); fi
    caps_write ${keep[@]+"${keep[@]}"} || refuse "machine.toml could not be changed"
  fi
  printf 'status\tdone\n'
  exit 0
fi

printf 'status\tok\n'
if [ "$action" = enable ]; then
  printf 'heading\tswitch %s on\n' "$name"
  printf 'step\tput %s into the list capabilities of machine.toml\n' "$name"
else
  printf 'heading\tswitch %s off\n' "$name"
  printf 'step\ttake %s out of the list capabilities of machine.toml\n' "$name"
fi
if [ "$nix" = yes ]; then
  printf 'warn\t%s brings a NixOS module: the change takes effect with the next hs rebuild.\n' "$name"
  if [ "$action" = disable ]; then
    printf 'danger\tIts services stop at the next rebuild.\nconfirm_name\t%s\n' "$name"
  fi
else
  printf 'note\tNo rebuild is needed: the pages and commands of %s appear or go away at once.\n' "$name"
fi
if [ "$kind" = extension ]; then printf 'command\ths ext %s %s\n' "$action" "$name"; else printf 'command\tmachine.toml: capabilities %s %s\n' "$action" "$name"; fi
printf 'long\tno\n'
