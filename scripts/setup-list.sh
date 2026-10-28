#!/usr/bin/env bash
# help: the first-run checklist as data: what is set up and what is still open
# help.de: die Checkliste nach der Installation als Daten: was eingerichtet ist und was noch offen ist
# args: [--list]
# System command (hs sys setup list), read only, plain, never translated, never asks. One line per item, tab separated:
#   id  state  label  command  page
#   state    done | open
#   command  what to run in a terminal for an open item ("-" when done)
#   page     the page of the web interface where it is done
# The last line, id "finished", is done once a person said so (runtime setting setupDone; the web interface's Setup page sets it).
# Test knobs: HS_STATE_DIR, HS_MACHINE_FILE, HS_SETTINGS_DIR, HS_ETC_DIR, HS_SETUP_BULK (the mount point checked for storage),
# HS_VAULT_OPEN.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/machine.sh"
. "$here/lib/setting.sh"
. "$here/lib/vault.sh"
state=${HS_STATE_DIR:-/var/lib/hs}
etc=${HS_ETC_DIR:-/etc/hs}
bulk=${HS_SETUP_BULK:-/bulk}

row() {   # row <id> <label> <command> <page> <test...>
  local id=$1 label=$2 cmd=$3 page=$4; shift 4
  if "$@" >/dev/null 2>&1; then printf '%s\tdone\t%s\t-\t%s\n' "$id" "$label" "$page"
  else printf '%s\topen\t%s\t%s\t%s\n' "$id" "$label" "$cmd" "$page"; fi
}
set_nonempty() { [ -n "$(setting_get "$1" 2>/dev/null || true)" ]; }
has_share() { ls "$bulk/shares" 2>/dev/null | grep -q .; }
has_file() { [ -s "$1" ] || [ -L "$1" ]; }
has_notify() {
  has_file "$state/notify-url" || [ -s "$etc/notify-url" ] || [ "$(setting_get notifications 2>/dev/null || true)" = true ] ||
    grep -qx notifications "$etc/capabilities" 2>/dev/null
}
has_caps() { [ -s "$etc/capabilities" ]; }

row language      "Language"                   "hs config set language de"       /settings           set_nonempty language
row timezone      "Time zone"                  "hs config set timeZone Europe/Vienna" /settings      machine_has timeZone
row notifications "Set up notifications"       "hs config set notifications true" /operations/notifications has_notify
row storage       "Storage pool"               "hs pool bulk add"                /storage/bulk       mountpoint -q "$bulk"
row share         "A first share"              "hs share add <name>"             /storage/bulk/shares has_share
row backup        "Backup disk"                "hs backup init <device>"         /protection/backup  has_file "$state/restic-password"
if vault_configured; then row vault "Vault (secrets)" "hs unlock" /storage/vault vault_is_open; fi
row parts         "Optional parts (capabilities)" "hs config set capabilities ..." /settings         has_caps
row finished      "Setup finished"             "hs config set setupDone true"    /setup              bash -c '[ "$(. "$1/lib/setting.sh"; setting_get setupDone 2>/dev/null)" = true ]' _ "$here"
