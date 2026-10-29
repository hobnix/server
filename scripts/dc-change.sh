#!/usr/bin/env bash
# help: certificates of the domain controller without asking anything: what would happen (plan), then do it (start)
# help.de: Zertifikate des Domänencontrollers ohne Rückfragen: was passieren würde (plan), dann ausführen (start)
# args: plan|start ca | renew [--dc <instance>] [--confirm <instance>]
# System command (hs sys dc plan|start): for the interface and tests. It never asks and prints plain key<TAB>value lines like backup-change.sh.
# The work is dc-cert.sh's (no logic is repeated here). The read is `hs sys dc state`.
#   ca      make the small CA of this setup (once; key in the vault, certificate in /var/lib/hs). Refused when it exists; answers done.
#   renew   a new certificate for the controller that runs on THIS server: new key inside the controller, signed by the CA of this server,
#           installed, Samba of the controller restarted, LDAPS tested (dc-cert.sh request | sign | install). Red: confirm_name = the controller,
#           because Samba restarts and logins fail for a moment. Runs as a background job. A controller on another server is renewed in the
#           terminal (hs dc cert request / sign / install: the request travels between the two servers).
# plan: exit 0 = allowed, 1 = refused. Output: status ok|refused, reason<TAB><text>, heading|step|note|warn|danger|command<TAB><line>,
#   confirm_name<TAB><instance> (renew), long<TAB>yes|no.
# start: the same checks (and the typed name for renew), then ca runs at once (done) and renew as a job (started + unit).
# Test knobs: HS_DC_CERT (stand-in for dc-cert.sh), HS_STATE_DIR, HS_INCUS, HS_DC.
set -euo pipefail
here=$(dirname "$0")
cert=${HS_DC_CERT:-$here/dc-cert.sh}
state=${HS_STATE_DIR:-/var/lib/hs}
inc=${HS_INCUS:-incus}

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

verb=${1:-}; action=${2:-}
case "$verb" in plan|start) ;; *) echo "usage: dc-change.sh plan|start ca | renew [--dc <instance>]" >&2; exit 1 ;; esac
case "$action" in ca|renew|renew-job) ;; *) refuse "unknown action (ca or renew)" ;; esac
shift 2 || true
dc="" confirm=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dc)      [ "$action" != ca ] || refuse "--dc is for renew"; [ $# -ge 2 ] || refuse "--dc needs a value"; dc=$2; shift 2 ;;
    --confirm) [ $# -ge 2 ] || refuse "--confirm needs a value"; confirm=$2; shift 2 ;;
    *) refuse "unknown option $1" ;;
  esac
done
[ -z "$dc" ] || [[ "$dc" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]] || refuse "'$dc' is not an instance name"

export HS_PLAIN=1 HS_LANG=en HS_CALLER=${HS_CALLER:-ui}
unset HS_GUIDED_TTY

# the actual renewal, run as a job: request in the controller, sign here, install in the controller
if [ "$action" = renew-job ]; then
  tmp=$(mktemp -d "${HS_RUN_DIR:-/run}/dc-renew.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
  args=(); [ -z "$dc" ] || args=(--dc "$dc")
  bash "$cert" request ${args[@]+"${args[@]}"} > "$tmp/req.csr"
  bash "$cert" sign "$tmp/req.csr" > "$tmp/bundle.pem"
  bash "$cert" install --cert "$tmp/bundle.pem" ${args[@]+"${args[@]}"} --yes
  exit 0
fi

case "$action" in
  ca)
    [ ! -s "$state/dc-ca.pem" ] || refuse "The CA exists already (a new one would make every certificate invalid)."
    if [ "$verb" = start ]; then
      bash "$cert" ca </dev/null >/dev/null 2>&1 || refuse "the CA could not be made (is the vault open? is this a domain server?)"
      printf 'status\tdone\n'
      exit 0
    fi
    printf 'status\tok\nheading\tmake the CA of this domain\n'
    printf 'step\tmake a CA key (stored in the vault) and a CA certificate (valid ten years, only for names inside the domain)\n'
    printf 'note\tDo this once, on the server that keeps the CA. Whoever holds the key can issue certificates for the domain.\n'
    printf 'command\ths dc cert ca\nlong\tno\n' ;;
  renew)
    [ -s "$state/dc-ca.pem" ] || refuse "There is no CA on this server yet: make it first."
    name=$dc
    if [ -z "$name" ]; then
      . "$here/lib/dc.sh"
      name=$(dc_name)
    fi
    "$inc" info "$name" >/dev/null 2>&1 || refuse "The domain controller '$name' does not run on this server: renew its certificate in the terminal there (hs dc cert request / sign / install)."
    if [ "$verb" = start ]; then
      [ "$confirm" = "$name" ] || refuse "type the name of the controller to confirm: $name"
      . "$here/lib/job.sh"
      unit=$(hs_job "dc-renew-$name" "renew the certificate of $name" -- bash "$here/dc-change.sh" start renew-job --dc "$name") || refuse "the job could not be started"
      printf 'status\tstarted\nunit\t%s\n' "$unit"
      exit 0
    fi
    printf 'status\tok\nheading\trenew the certificate of %s\n' "$name"
    printf 'step\tmake a new key inside %s and a certificate request for the domain name and its own name\n' "$name"
    printf 'step\tsign the request with the CA of this server\n'
    printf 'step\tput certificate, key and CA into Samba'"'"'s tls folder (the old files stay in tls.before-<date>), restart Samba, test LDAPS\n'
    printf 'danger\tSamba of %s restarts: logins and file shares fail for a moment.\n' "$name"
    printf 'command\ths dc cert request | sign | install\nconfirm_name\t%s\nlong\tyes\n' "$name" ;;
esac
exit 0
