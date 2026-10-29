#!/usr/bin/env bash
# help: run `vps update` or `vps watch` on the proxyserver (the VPS) without asking anything: what would happen (plan), then do it as a background job (start)
# help.de: `vps update` oder `vps watch` auf dem Proxyserver (dem VPS) ausführen, ohne etwas zu fragen: was passieren würde (plan), dann als Hintergrundjob ausführen (start)
# args: plan|start update|watch
# System command (hs sys vps plan|start): for the interface and tests. It never asks and prints plain key<TAB>value lines like backup-change.sh.
# The VPS is reached with a key of its own (hs vps key; the private half is the secret /var/lib/hs/vps-key, in the vault when there is one).
# That key can do ONLY update, watch and status on the VPS (its machine.nix: webKey; the forced command modules/cli/vps-remote.sh in the
# proxyserver repo). The only word that reaches the VPS is the verb, checked here against a fixed list.
#   update   `vps update` on the VPS: git pull, then nixos-rebuild switch (a few minutes; the VPS keeps going if this connection drops)
#   watch    `vps watch`: look at the home server from outside now (ps-watch)
# plan: exit 0 = allowed, 1 = refused (vpsHost not set, no key yet, vault closed). Output: status ok|refused, reason<TAB><text>,
#   heading|step|note|warn|command<TAB><line>, long<TAB>yes|no.
# start: the same checks, then ssh runs as a background job (status started, unit); its output is the job log. The private key is only a
#   PATH in the ssh command line, never its content.
# Test knobs: HS_SSH (stand-in for ssh), HS_STATE_DIR, HS_MACHINE_FILE.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/secret.sh"
. "$here/lib/machine.sh"
state=${HS_STATE_DIR:-/var/lib/hs}
ssh_bin=${HS_SSH:-ssh}

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

verb=${1:-}; action=${2:-}
case "$verb" in plan|start) ;; *) echo "usage: vps-change.sh plan|start update|watch" >&2; exit 1 ;; esac
case "$action" in update|watch) ;; *) refuse "unknown action (update or watch)" ;; esac
[ $# -eq 2 ] || refuse "unexpected extra arguments"

export HS_PLAIN=1 HS_LANG=en HS_CALLER=${HS_CALLER:-ui}
unset HS_GUIDED_TTY

host=$(machine_get vpsHost 2>/dev/null || true)
[ -n "$host" ] || refuse "vpsHost is not set in machine.toml (the Tailscale name or address of the proxyserver), then hs rebuild."
{ [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,100}$ ]] && [[ "$host" != *..* ]]; } || refuse "vpsHost in machine.toml is not a host name or address."

key=$state/vps-key
case "$(secret_state "$key")" in
  ok) ;;
  locked) refuse "The vault is closed: run hs unlock, then try again." ;;
  *) refuse "There is no key for the proxyserver yet: run hs vps key and follow what it prints." ;;
esac

# pinned host key: the first connection is accepted and remembered, a changed key is refused afterwards (ssh says so in the job log)
known=$state/vps-known-hosts
cmd=("$ssh_bin" -i "$key" -T -p 2222
  -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none
  -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$known"
  -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=8
  "root@$host" "$action")

if [ "$verb" = start ]; then
  . "$here/lib/job.sh"
  unit=$(hs_job "vps-$action" "vps $action" -- "${cmd[@]}") || refuse "the job could not be started"
  printf 'status\tstarted\nunit\t%s\n' "$unit"
  exit 0
fi

printf 'status\tok\n'
case "$action" in
  update)
    printf 'heading\tupdate the proxyserver (%s)\n' "$host"
    printf 'step\tconnect to %s over SSH with the key for this (it can only run update, watch and status there)\n' "$host"
    printf 'step\tvps update there: pull the proxyserver repository, then nixos-rebuild switch\n'
    printf 'warn\tThe proxyserver rebuilds itself: mail and the game ports may be unreachable for a moment while its services restart.\n'
    printf 'note\tThe rebuild takes a few minutes. It is its own unit on the VPS, so it goes on if this connection drops. The result is a push message and the Tasks tab.\n'
    printf 'note\tThe first connection remembers the host key of the VPS; a changed one is refused afterwards.\n' ;;
  watch)
    printf 'heading\tlook at the home server from the proxyserver (%s)\n' "$host"
    printf 'step\tconnect to %s over SSH and run vps watch there (the outside check of this server: heartbeat and public addresses)\n' "$host"
    printf 'note\tIf something is wrong, the proxyserver sends its own push message; the output shows its last lines.\n' ;;
esac
printf 'command\t%s\n' "${cmd[*]}"
if [ "$action" = update ]; then printf 'long\tyes\n'; else printf 'long\tno\n'; fi
exit 0
