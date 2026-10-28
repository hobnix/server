#!/usr/bin/env bash
# help: the other servers (nodes) this one can look at: list, add, remove, show, make the key, read a node's status
# help.de: die anderen Server (Knoten), die dieser ansehen kann: anzeigen, hinzufügen, entfernen, Schlüssel anlegen, den Status eines Knotens lesen
# args: list | --list | show <name> | --show <name> | --keyline <name> | add <name> <host> [--kind peer|vps|edge] [--port N] | remove <name> [--yes] | key <name> [--new] [--yes] | status <name> | --status <name>
# This server is the main node and is not in the registry. A remote node is a row of /var/lib/hs/nodes.tsv
# (name, kind, host, port, added; tab separated, no empty field). The main node PULLS: it runs ssh with a key of its own for that node, and the node accepts
# the key only through a forced command that knows fixed words (scripts/node-remote.sh: `status`). Nothing here gives a node control of this server.
#   kind vps   the proxyserver: ssh user root, port 2222 (Tailscale SSH owns port 22), forced command vps-remote.sh of the proxyserver repo
#   kind edge  a node of this repo with role = "edge" (the new public VPS): ssh user root, port 2222, forced command scripts/node-remote.sh; its machine.toml line is nodeKeys
#   kind peer  another home server (the cousin's): ssh user adminuser, port 22, forced command scripts/node-remote.sh
# The old capability `vps` stays as it is: while the runtime setting vpsHost is set and no row is called proxyserver, the list has an IMPLICIT node
# `proxyserver` (kind vps, key = the old /var/lib/hs/vps-key, source setting). Its status is read with the same key.
# --list (hs sys node list): one node per line, tab separated: name, kind, host, port, source (file|setting), key (ok|locked|missing). No node: no lines.
# --show <name> (hs sys node show): key<TAB>value lines (name, kind, host, port, user, source, key, words, command). Exit 1 when unknown.
# --keyline <name> (hs sys node keyline): key<TAB>value lines for the interface: key (ok|locked|missing), user (ssh user on the other server), file (where the other
#   server's owner puts the line), line (the PUBLIC half with the options of the forced command; the private key is never printed). Exit 1: unknown node.
# --status <name> (hs sys node status): the status document of the node, ONE JSON object on stdout (exit 1 and a message on stderr when the node
#   does not answer, the key is missing or the vault is closed). Only the word `status` is ever sent.
# Test knobs: HS_STATE_DIR, HS_MACHINE_FILE, HS_SETTINGS_DIR, HS_SSH (stand-in for ssh), HS_NOW, HS_VAULT_DIR.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/secret.sh"
. "$here/lib/setting.sh"
. "$here/lib/machine.sh"
state=${HS_STATE_DIR:-/var/lib/hs}
nodes=$state/nodes.tsv
ssh_bin=${HS_SSH:-ssh}
# the words this server ever sends to a node (the receiving side checks again); step 1: status only
NODE_WORDS="status"

usage() {
  say "usage: hs node list"
  say "       hs node show <name>"
  say "       hs node add <name> <host> [--kind peer|vps|edge] [--port N]"
  say "       hs node remove <name> [--yes]"
  say "       hs node key <name> [--new] [--yes]"
  say "       hs node status <name>"
  exit 1
}
interactive() { [ -t 0 ] && [ -t 1 ] && [ -z "${HS_CALLER:-}" ] || [ -n "${HS_GUIDED_TTY:-}" ]; }

valid_name() { [[ "$1" =~ ^[a-z][a-z0-9-]{0,30}$ ]] && [ "$1" != local ] && [ "$1" != main ]; }
valid_host() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,100}$ ]] && [[ "$1" != *..* ]]; }
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

# rows: name kind host port source
all_rows() {
  local n k h p a seen=0
  if [ -f "$nodes" ]; then
    while IFS=$'\t' read -r n k h p a; do
      [ -n "$n" ] || continue
      case "$n" in \#*) continue ;; esac
      [ "$n" = proxyserver ] && seen=1
      printf '%s\t%s\t%s\t%s\tfile\n' "$n" "$k" "$h" "$p"
    done < "$nodes"
  fi
  if [ "$seen" = 0 ]; then
    h=$(setting_get vpsHost 2>/dev/null || true)
    [ -n "$h" ] || h=$(machine_get vpsHost 2>/dev/null || true)
    if [ -n "$h" ] && valid_host "$h"; then printf 'proxyserver\tvps\t%s\t2222\tsetting\n' "$h"; fi
  fi
  return 0
}
row_of() { all_rows | awk -F'\t' -v n="$1" '$1 == n { print; exit }'; }   # the row of one node, or nothing

key_path() {   # key_path <name> <source>
  if [ "$2" = setting ]; then echo "$state/vps-key"; else echo "$state/node-key-$1"; fi
}
ssh_user() { if [ "$1" = vps ] || [ "$1" = edge ]; then echo root; else echo adminuser; fi; }
known_hosts() { echo "$state/node-known-hosts"; }

key_state() { secret_state "$1"; }

load_node() {   # load_node <name>: sets n_kind n_host n_port n_src n_key n_user, or fails
  local row
  valid_name "$1" || fail "$(t 'Not a node name: %s (lower case letters, digits and dashes)' "$1")"
  row=$(row_of "$1")
  [ -n "$row" ] || fail "$(t 'There is no node called %s.' "$1")"
  IFS=$'\t' read -r _ n_kind n_host n_port n_src <<<"$row"
  n_key=$(key_path "$1" "$n_src")
  n_user=$(ssh_user "$n_kind")
}

cmd_list() {
  all_rows | while IFS=$'\t' read -r n k h p s; do
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$k" "$h" "$p" "$s" "$(key_state "$(key_path "$n" "$s")")"
  done
}

cmd_list_people() {
  local rows
  rows=$(cmd_list)
  if [ -z "$rows" ]; then
    note "There are no other nodes yet."
    note "Add one: hs node add <name> <host> [--kind peer|vps|edge]"
    return 0
  fi
  { thead "Node" "Kind" "Host" "Port" "Key"; printf '%s\n' "$rows" | awk -F'\t' '{ print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $6 }'; } | table
}

ssh_cmd() {   # ssh_cmd <word>: fills the array `cmd` (the key is only a PATH here, never its content)
  cmd=("$ssh_bin" -i "$n_key" -T -p "$n_port"
    -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none
    -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$(known_hosts)"
    -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4
    "$n_user@$n_host" "$1")
}

cmd_show() {   # key<TAB>value; plain on purpose
  load_node "$1"
  local ks; ks=$(key_state "$n_key")
  ssh_cmd status
  printf 'name\t%s\nkind\t%s\nhost\t%s\nport\t%s\nuser\t%s\nsource\t%s\nkey\t%s\nwords\t%s\ncommand\t%s\n' \
    "$1" "$n_kind" "$n_host" "$n_port" "$n_user" "$n_src" "$ks" "$NODE_WORDS" "${cmd[*]}"
}

cmd_show_people() {
  local k v
  load_node "$1"
  while IFS=$'\t' read -r k v; do kv "$k" "$v"; done < <(cmd_show "$1")
}

cmd_add() {
  local name=${1:-} host=${2:-} kind=peer port=""
  shift 2 2>/dev/null || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind) kind=${2:-}; shift 2 || usage ;;
      --port) port=${2:-}; shift 2 || usage ;;
      *) usage ;;
    esac
  done
  [ -n "$name" ] && [ -n "$host" ] || usage
  valid_name "$name" || fail "$(t 'Not a node name: %s (lower case letters, digits and dashes)' "$name")"
  valid_host "$host" || fail "$(t 'Not a host name or address: %s' "$host")"
  case "$kind" in peer|vps|edge) ;; *) fail "$(t 'The kind is peer, vps or edge.')" ;; esac
  [ -n "$port" ] || { if [ "$kind" = peer ]; then port=22; else port=2222; fi; }
  valid_port "$port" || fail "$(t 'Not a port: %s' "$port")"
  { [ ! -f "$nodes" ] || ! awk -F'	' -v n="$name" '$1 == n { f = 1 } END { exit !f }' "$nodes"; } || fail "$(t 'There is already a node called %s.' "$name")"
  mkdir -p "$state"
  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$kind" "$host" "$port" "${HS_NOW:-$(date +%s)}" >> "$nodes"
  ok "$(t 'Node %s added' "$name")"
  note "$(t 'Next: hs node key %s (it prints the line the other server has to allow), then hs node status %s' "$name" "$name")"
}

cmd_remove() {
  local name=${1:-} yes=false
  [ -n "$name" ] || usage
  shift
  for a in "$@"; do case "$a" in --yes) yes=true ;; *) usage ;; esac; done
  valid_name "$name" || fail "$(t 'Not a node name: %s (lower case letters, digits and dashes)' "$name")"
  [ -f "$nodes" ] && awk -F'\t' -v n="$name" '$1 == n { f = 1 } END { exit !f }' "$nodes" \
    || fail "$(t 'There is no node called %s in the list (the implicit node proxyserver goes away with hs config unset vpsHost).' "$name")"
  if ! $yes; then
    interactive || fail "Nothing is changed without --yes when there is no terminal."
    confirm "$(t 'Remove node %s from the list? The other server is not touched.' "$name")" || fail "cancelled"
  fi
  awk -F'\t' -v n="$name" '$1 != n' "$nodes" > "$nodes.new"
  mv "$nodes.new" "$nodes"
  ok "$(t 'Node %s removed' "$name")"
  note "$(t 'Its key file stays (%s); delete the line from the other server authorized keys and remove the file.' "$state/node-key-$name")"
}

cmd_key() {
  local name=${1:-} new=false yes=false a st key pub run
  [ -n "$name" ] || usage
  shift
  for a in "$@"; do case "$a" in --new) new=true ;; --yes) yes=true ;; *) usage ;; esac; done
  load_node "$name"
  [ "$n_src" != setting ] || fail "$(t 'The key of the implicit node proxyserver is made by: hs vps key')"
  command -v ssh-keygen >/dev/null 2>&1 || fail "ssh-keygen is not installed."
  key=$n_key
  st=$(secret_state "$key")
  if [ "$st" = locked ]; then vault_locked_note >&2; fail_fix "The key lives in the closed vault." "hs unlock"; fi
  if [ "$st" = ok ] && $new; then
    if ! $yes; then
      interactive || fail "Replacing the key needs --yes when there is no terminal."
      confirm "$(t 'Replace the key? The other server stops accepting the old one.')" || fail "cancelled"
    fi
    st=missing
    rm -f "$key"
  fi
  if [ "$st" != ok ]; then
    secret_prepare "node-key-$name" "$state" || fail_fix "The vault is closed." "hs unlock"
    mkdir -p "$state"
    run=${HS_RUN_DIR:-/run}
    [ -d "$run" ] && [ -w "$run" ] || run=${TMPDIR:-/tmp}
    tmp=$(umask 077; mktemp -d "$run/hs-node-key.XXXXXX")
    trap 'rm -rf "$tmp"' EXIT
    ssh-keygen -q -t ed25519 -N '' -C "hs-node-$(hostname 2>/dev/null || echo main)" -f "$tmp/k" >/dev/null
    ( umask 077; cat "$tmp/k" > "$key" )
    chmod 600 "$key" 2>/dev/null || true
    ok "Key created"
  else
    ok "Key exists"
  fi
  pub=$(ssh-keygen -y -f "$key" 2>/dev/null | awk 'NF { print $1 " " $2; exit }') || true
  [ -n "$pub" ] || fail "The key could not be read."
  step "Line for the other server"
  if [ "$n_kind" = edge ]; then
    say "nodeKeys = [\"$pub hs-node\"]"
    note "That is the machine.toml line of the edge node (role = \"edge\"); it puts the forced command in front of the key itself. Then: hs rebuild there."
  elif [ "$n_kind" = vps ]; then
    say "webKey = \"$pub hs-node\";"
    note "That is the machine.nix line of the proxyserver (its forced command knows update, watch and status)."
  else
    say "restrict,command=\"/etc/nixos/scripts/node-remote.sh\" $pub hs-node"
    note "$(t 'The owner of the other server puts this line into the authorized keys of its user %s. The key then answers status and nothing else.' "$n_user")"
  fi
}

cmd_keyline() {   # plain key<TAB>value lines; only the public half ever leaves
  load_node "$1"
  local ks pub where line
  ks=$(key_state "$n_key")
  printf 'key\t%s\nuser\t%s\n' "$ks" "$n_user"
  [ "$ks" = ok ] || return 0
  pub=$(ssh-keygen -y -f "$n_key" 2>/dev/null | awk 'NF { print $1 " " $2; exit }') || true
  [ -n "$pub" ] || return 0
  case "$n_kind" in
    edge) where="machine.toml of the edge node (nodeKeys), then hs rebuild there"; line="nodeKeys = [\"$pub hs-node\"]" ;;
    vps) where="machine.nix of the proxyserver (webKey)"; line="webKey = \"$pub hs-node\";" ;;
    *) where="authorized keys of the user $n_user on the other server"; line="restrict,command=\"/etc/nixos/scripts/node-remote.sh\" $pub hs-node" ;;
  esac
  printf 'file\t%s\nline\t%s\n' "$where" "$line"
}

cmd_status_json() {   # the raw document, for the interface
  load_node "$1"
  case "$(key_state "$n_key")" in
    ok) ;;
    locked) echo "The vault is closed: run hs unlock." >&2; exit 1 ;;
    *) echo "There is no key for node $1 yet: run hs node key $1." >&2; exit 1 ;;
  esac
  ssh_cmd status
  local out rc=0
  out=$("${cmd[@]}" 2>/dev/null </dev/null | head -c 262144) || rc=$?
  if [ -z "$out" ]; then echo "Node $1 did not answer." >&2; exit 1; fi
  case "$out" in "{"*) ;; *) echo "Node $1 answered something that is not a status document." >&2; exit 1 ;; esac
  printf '%s\n' "$out"
}

cmd_status_people() {
  local doc
  doc=$(cmd_status_json "$1" 2>&1) || { fail "$(t 'Node %s: %s' "$1" "$doc")"; }
  if ! command -v jq >/dev/null 2>&1; then printf '%s\n' "$doc"; return 0; fi
  load_node "$1"
  step "$(t 'Node %s' "$1")"
  jq -r '
    def sz: if . == null then "-" else ((. / 1073741824 * 10 | floor) / 10 | tostring) + " GiB" end;
    [ ["host", (.host // "-")],
      ["kind", (.kind // "-")],
      ["uptime (h)", (if .uptime_s then ((.uptime_s / 3600 * 10 | floor) / 10 | tostring) else "-" end)],
      ["load", (if .load then (.load | map(tostring) | join(" ")) else "-" end)],
      ["problems", (if .problems == null then "-" else (.problems | tostring) end)],
      ["fast pool", (if .pools.fast then ((.pools.fast.used | sz) + " / " + (.pools.fast.size | sz)) else "-" end)],
      ["bulk pool", (if .pools.bulk then ((.pools.bulk.used | sz) + " / " + (.pools.bulk.size | sz)) else "-" end)],
      ["backup", (if .backup then (.backup.status + ", " + ((.backup.age_s // 0) / 3600 | floor | tostring) + " h ago") else "-" end)],
      ["instances", (if .instances then ((.instances.running | tostring) + " of " + (.instances.total | tostring) + " running") else "-" end)],
      ["time", (.time // "-" | tostring)] ] | .[] | @tsv' <<<"$doc" \
    | while IFS=$'\t' read -r k v; do kv "$k" "$v"; done
}

sub=${1:-}
[ -n "$sub" ] || usage
shift
case "$sub" in
  list) cmd_list_people ;;
  --list) cmd_list ;;
  show) [ $# -eq 1 ] || usage; cmd_show_people "$1" ;;
  --show) [ $# -eq 1 ] || usage; cmd_show "$1" ;;
  add) cmd_add "$@" ;;
  remove) cmd_remove "$@" ;;
  key) cmd_key "$@" ;;
  status) [ $# -eq 1 ] || usage; cmd_status_people "$1" ;;
  --keyline) [ $# -eq 1 ] || usage; cmd_keyline "$1" ;;
  --status) [ $# -eq 1 ] || usage; cmd_status_json "$1" ;;
  *) usage ;;
esac
