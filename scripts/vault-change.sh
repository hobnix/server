#!/usr/bin/env bash
# help: change the vault and the secrets without asking anything: what would happen (plan), then do it as a background job (start)
# help.de: den Tresor und die Geheimnisse ändern, ohne etwas zu fragen: was passieren würde (plan), dann als Hintergrundjob ausführen (start)
# args: plan|start header-backup | move [<name>...] | close | secrets-fix
# System command (hs sys secrets plan|start): for the interface and tests. It never asks and prints plain key<TAB>value lines like
# backup-change.sh. The work is vault.sh's and secrets.sh's (no logic is repeated here). The reads are `hs sys vault list|usage|uses`.
#   header-backup   save the LUKS header of the vault (/var/lib/hs/vault-header); needs the vault open
#   move [<name>]   copy secrets into the vault, check the copy and leave a link; without names the usual ones that exist; needs the vault open
#   close           close the vault (red: confirm_name = close); refused while something uses it. Everything that needs a secret waits for the unlock
#   secrets-fix     root-only permissions on the secrets (hs secrets fix); never touches the content of the vault
# NOT here on purpose: `init` (erases a partition, done at the installation, with the disk typed), `bind` (moves a whole folder; stop its users first)
# and `open` (the unlock page opens it with the passphrase of the disks).
# plan: exit 0 = allowed, 1 = refused. Output: status ok|refused, reason<TAB><text>, heading|step|note|warn|danger|command<TAB><line>,
#   confirm_name<TAB>close, long<TAB>no.
# start: the same checks (and the typed word for close), then a background job (status started, unit). A job, because the web interface has its own
# mount namespace: a vault closed or written from in there would not reach the host.
# Test knobs: HS_VAULT (stand-in for vault.sh), HS_SECRETS (stand-in for secrets.sh).
set -euo pipefail
here=$(dirname "$0")
vault=${HS_VAULT:-$here/vault.sh}
secrets=${HS_SECRETS:-$here/secrets.sh}

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

verb=${1:-}; action=${2:-}
case "$verb" in plan|start) ;; *) echo "usage: vault-change.sh plan|start header-backup|move [<name>...]|close|secrets-fix" >&2; exit 1 ;; esac
case "$action" in header-backup|move|close|secrets-fix) ;; *) refuse "unknown action (header-backup, move, close or secrets-fix)" ;; esac
shift 2 || true
names=() confirm=""
while [ $# -gt 0 ]; do
  case "$1" in
    --confirm) [ $# -ge 2 ] || refuse "--confirm needs a value"; confirm=$2; shift 2 ;;
    -*) refuse "unknown option $1" ;;
    *) [ "$action" = move ] || refuse "unexpected extra arguments"
       [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,60}$ ]] || refuse "'$1' is not a name of a secret"
       names+=("$1"); shift ;;
  esac
done

export HS_PLAIN=1 HS_LANG=en HS_CALLER=${HS_CALLER:-ui}
unset HS_GUIDED_TTY

state() { bash "$vault" usage </dev/null 2>/dev/null | awk -F'\t' '$1 == "state" { print $2; exit }' || true; }

cmd=() title="" shown="" steps=() dangers=() note=""
case "$action" in
  header-backup|move|close)
    case "$(state)" in
      open) ;;
      closed) if [ "$action" = close ]; then refuse "The vault is closed already."; fi
              refuse "The vault is closed: unlock it first (the unlock page, or hs unlock)." ;;
      *) refuse "There is no vault on this server (hs vault init)." ;;
    esac ;;
esac
case "$action" in
  header-backup)
    cmd=(bash "$vault" header-backup); title="save the LUKS header of the vault"; shown="hs vault header-backup"
    steps=("write the header to /var/lib/hs/vault-header (mode 600, part of the host backup)")
    note="Keep a copy elsewhere too: with the header and the passphrase the vault opens even when the partition is damaged." ;;
  move)
    cmd=(bash "$vault" move ${names[@]+"${names[@]}"}); title="move secrets into the vault"; shown="hs vault move ${names[*]:-}"
    steps=("copy ${names[*]:-the usual secrets that exist} into the vault, check the copy, overwrite the old file and leave a link at the old path")
    note="Safe to run again: what is in the vault already is skipped." ;;
  close)
    cmd=(bash "$vault" close --yes); title="close the vault"; shown="hs vault close --yes"
    steps=("close the vault; it is refused while something uses it")
    dangers=("Everything that needs a secret (the backup password, the router key, the domain database) waits until the unlock.") ;;
  secrets-fix)
    cmd=(bash "$secrets" fix); title="set root-only permissions on the secrets"; shown="hs secrets fix"
    steps=("make the files that hold secrets readable by root only (the content of the vault is not touched)") ;;
esac

if [ "$verb" = start ]; then
  if [ "$action" = close ] && [ "$confirm" != close ]; then refuse "type the word to confirm: close"; fi
  . "$here/lib/job.sh"
  unit=$(hs_job "vault-$action" "hs vault $action" -- "${cmd[@]}") || refuse "the job could not be started"
  printf 'status\tstarted\nunit\t%s\n' "$unit"
  exit 0
fi

printf 'status\tok\nheading\t%s\n' "$title"
for s in "${steps[@]}"; do printf 'step\t%s\n' "$s"; done
for d in ${dangers[@]+"${dangers[@]}"}; do printf 'danger\t%s\n' "$d"; done
[ -z "$note" ] || printf 'note\t%s\n' "$note"
printf 'command\t%s\n' "$shown"
if [ "$action" = close ]; then printf 'confirm_name\tclose\n'; fi
printf 'long\tno\n'
exit 0
