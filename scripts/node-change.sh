#!/usr/bin/env bash
# help: add, remove or make the key of a node (another server) without asking anything: what would happen (plan), then do it (start)
# help.de: einen Knoten (anderen Server) hinzufügen, entfernen oder seinen Schlüssel anlegen, ohne etwas zu fragen: was passieren würde (plan), dann ausführen (start)
# args: plan|start add <name> <host> [--kind peer|vps|edge] [--port N] | plan|start remove <name> | plan|start key <name> [--new]
# System command (hs sys node plan|start): for the interface and tests. It never asks and prints plain key<TAB>value lines like expiry-change.sh.
# The work is node.sh's (add / remove / key); this script checks the input and says what would happen. NOTHING here touches the other server:
# a node is a row in /var/lib/hs/nodes.tsv and a key file on THIS server; what the other server allows is its owner's decision (the key line,
# shown by `hs sys node keyline`). No word of this script ever reaches a remote node, and a remote node gets no write action from here.
#   add <name> <host> [--kind K] [--port N]  write the row (changes nothing on the other server)
#   remove <name>                            take the row out of the list; the key file stays. Red: the typed word is the node's name.
#   key <name> [--new]                       make the SSH key for the node (only the public half is ever shown); --new replaces it. Red: the typed word is the name.
# plan: exit 0 = allowed, 1 = refused, 2 = something is missing (status needs, needs<TAB>host). Output: status ok|refused|needs, reason<TAB><text>,
#   heading|step|note|warn|danger|command<TAB><line>, confirm_name<TAB><name> (remove, key --new), long<TAB>no.
# start: the same checks, then status<TAB>done.
# Test knobs: HS_NODE (stand-in for node.sh).
set -euo pipefail
here=$(dirname "$0")
node=${HS_NODE:-$here/node.sh}

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

verb=${1:-}; action=${2:-}; name=${3:-}
case "$verb" in plan|start) ;; *) echo "usage: node-change.sh plan|start add <name> <host> [--kind K] [--port N] | remove <name> | key <name> [--new]" >&2; exit 1 ;; esac
case "$action" in add|remove|key) ;; *) refuse "unknown action (add, remove or key)" ;; esac
if [ -z "$name" ]; then
  if [ "$action" = add ]; then printf 'status\tneeds\nneeds\tname\n'; exit 2; fi
  refuse "a node name is needed"
fi
[[ "$name" =~ ^[a-z][a-z0-9-]{0,30}$ ]] && [ "$name" != local ] && [ "$name" != main ] || refuse "not a node name (lower case letters, digits and dashes, at most 31, starting with a letter)"
shift 3

export HS_PLAIN=1 HS_LANG=en HS_CALLER=${HS_CALLER:-ui}
unset HS_GUIDED_TTY

exists=false kind="" host="" port="" new=false
if bash "$node" --list 2>/dev/null | awk -F'\t' -v n="$name" '$1 == n { f = 1 } END { exit !f }'; then exists=true; fi

case "$action" in
  add)
    host=${1:-}; [ $# -eq 0 ] || shift
    if [ -z "$host" ]; then printf 'status\tneeds\nneeds\thost\n'; exit 2; fi
    [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,100}$ ]] && [[ "$host" != *..* ]] || refuse "not a host name or address"
    kind=peer
    while [ $# -gt 0 ]; do
      case "$1" in
        --kind) kind=${2:-}; shift 2 || refuse "--kind needs a value" ;;
        --port) port=${2:-}; shift 2 || refuse "--port needs a value" ;;
        *) refuse "unknown option $1" ;;
      esac
    done
    case "$kind" in peer|vps|edge) ;; *) refuse "the kind is peer, vps or edge" ;; esac
    if [ -n "$port" ]; then { [[ "$port" =~ ^[0-9]{1,5}$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; } || refuse "not a port"; fi
    $exists && refuse "There is already a node called $name."
    cmd=(bash "$node" add "$name" "$host" --kind "$kind"); [ -z "$port" ] || cmd+=(--port "$port") ;;
  remove)
    [ $# -eq 0 ] || refuse "unexpected extra arguments"
    $exists || refuse "There is no node called $name."
    # only a row of the list can go; the implicit proxyserver of the setting vpsHost goes away with the setting
    bash "$node" --list 2>/dev/null | awk -F'\t' -v n="$name" '$1 == n && $5 == "file" { f = 1 } END { exit !f }' \
      || refuse "$name comes from the setting vpsHost: it goes away with hs config unset vpsHost."
    cmd=(bash "$node" remove "$name" --yes) ;;
  key)
    for a in "$@"; do case "$a" in --new) new=true ;; *) refuse "unexpected argument $a" ;; esac; done
    $exists || refuse "There is no node called $name."
    cmd=(bash "$node" key "$name" --yes); if $new; then cmd+=(--new); fi ;;
esac

if [ "$verb" = start ]; then
  rc=0; out=$("${cmd[@]}" </dev/null 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'status\trefused\nreason\t%s\n' "$(printf '%s' "$out" | sed -e 's/^[[:space:]]*//' -e 's/^[✗!] *//' | awk 'NF' | tail -n 1)"
    exit 1
  fi
  printf 'status\tdone\n'
  exit 0
fi

printf 'status\tok\n'
case "$action" in
  add)
    printf 'heading\tadd the node %s\n' "$name"
    printf 'step\tput %s (%s, %s) on the list of servers this one can look at\n' "$name" "$host" "$kind"
    printf 'note\tNothing changes on the other server. Next: make the key, then the owner of that server puts one line on it.\n' ;;
  remove)
    printf 'heading\tremove the node %s\n' "$name"
    printf 'step\ttake %s off the list; this server stops looking at it\n' "$name"
    printf 'danger\tThe other server is not touched and its key file stays here. Its owner should delete the line from the authorized keys.\n'
    printf 'confirm_name\t%s\n' "$name" ;;
  key)
    if $new; then
      printf 'heading\tmake a new key for %s\n' "$name"
      printf 'step\treplace the key for %s; the other server stops accepting the old one\n' "$name"
      printf 'danger\tThe node is out of reach until its owner has put the new line on the server.\n'
      printf 'confirm_name\t%s\n' "$name"
    else
      printf 'heading\tmake the key for %s\n' "$name"
      printf 'step\tcreate the SSH key this server uses for %s (nothing happens if it exists)\n' "$name"
      printf 'note\tThe key can only ask for the status of the other server; the line to put on it is shown afterwards.\n'
    fi ;;
esac
printf 'command\t%s\n' "${cmd[*]}"
printf 'long\tno\n'
