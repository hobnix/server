#!/usr/bin/env bash
# help: after the installation: language, notifications, and a checklist of what is still to set up
# help.de: nach der Installation: Sprache, Benachrichtigungen und eine Checkliste, was noch einzurichten ist
# args: [--language en|de] [--notify <url|none>] [--yes]
# Asks the two things that can be answered right away and shows the rest as a checklist with the command
# for each open item. HS_BIN points tests at a stand-in for the hs dispatcher.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/machine.sh"
. "$here/lib/vault.sh"
hsbin=${HS_BIN:-$here/lib/hs.sh}
cfg() { HS_CALLER="" bash "$hsbin" config "$@"; }

lang=""; notify=""; yes=false
while [ $# -gt 0 ]; do
  case "$1" in
    --language) [ $# -ge 2 ] || exit 1; lang=$2; shift 2 ;;
    --notify)   [ $# -ge 2 ] || exit 1; notify=$2; shift 2 ;;
    --yes)      yes=true; shift ;;
    *) say "usage: hs first-run [--language en|de] [--notify <url|none>] [--yes]"; exit 1 ;;
  esac
done

step "Language"
if [ -z "$lang" ] && [ -t 0 ] && ! $yes; then
  lang=$(choose "Language of the messages" en de) || lang=""
fi
if [ -n "$lang" ]; then cfg set language "$lang"; else note "Language unchanged."; fi

step "Notifications"
if [ -z "$notify" ] && [ -t 0 ] && ! $yes; then
  note "A push message tells you when a disk or a backup needs attention (ntfy.sh style address)."
  notify=$(ask "Address (empty to skip):" "")
fi
if [ -n "$notify" ]; then cfg set notifyUrl "$notify"; else note "Notifications unchanged."; fi

step "Core packages"
if "$hsbin" pkg install --core; then :; else warn "Some core packages could not be fetched; try again with: hs pkg install --core"; fi

step "What is still to do"
check() {   # check <label> <command to run when open> <test...>
  local label=$1 cmd=$2; shift 2
  if "$@" >/dev/null 2>&1; then printf '%s\t%s\t%s\n' "$label" "$(_tr 'done')" "-"; else printf '%s\t%s\t%s\n' "$label" "$(_tr 'open')" "$cmd"; fi
}
rows=$(
  check "Storage pools"        "hs pool bulk add"            mountpoint -q /bulk
  check "A first share"        "hs share add <name>"         bash -c 'ls /bulk/shares 2>/dev/null | grep -q .'
  check "Domain users"         "hs recipe domain"            machine_has adDomain
  check "Backup disk"          "hs backup init <device>"     bash -c '[ -s "$1" ] || [ -L "$1" ]' _ "${HS_STATE_DIR:-/var/lib/hs}/restic-password"
  # with a vault (secrets of this server) it has to be open for backup, UniFi and the like
  if vault_configured; then check "Vault (secrets)"  "hs unlock"                      vault_is_open; fi
  check "Notifications"       "hs config set notifyUrl <url>" test -s "${HS_STATE_DIR:-/var/lib/hs}/notify-url" -o -s /etc/hs/notify-url
)
open=$(awk -F'	' '$3 != "-"' <<<"$rows" | grep -c . || true)
if [ "$open" -eq 0 ]; then status_line "Setup" "Complete" ok; else status_line "Setup" "$(t '%s item(s) still open' "$open")" warn; fi
{ thead 'What' 'State' 'Command'; printf '%s
' "$rows"; } | table
note "Problems at any time: hs doctor"
