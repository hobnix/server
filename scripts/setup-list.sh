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
# Test knobs: HS_STATE_DIR, HS_MACHINE_FILE, HS_SETTINGS_DIR, HS_ETC_DIR, HS_POOLS_ROOT and HS_MOUNTPOINT (see lib/pools.sh: where
# the pools are mounted and how that is checked), HS_VAULT_OPEN.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/machine.sh"
. "$here/lib/setting.sh"
. "$here/lib/vault.sh"
. "$here/lib/pools.sh"
state=${HS_STATE_DIR:-/var/lib/hs}
etc=${HS_ETC_DIR:-/etc/hs}

row() {   # row <id> <label> <command> <page> <test...>
  local id=$1 label=$2 cmd=$3 page=$4; shift 4
  if "$@" >/dev/null 2>&1; then printf '%s\tdone\t%s\t-\t%s\n' "$id" "$label" "$page"
  else printf '%s\topen\t%s\t%s\t%s\n' "$id" "$label" "$cmd" "$page"; fi
}
set_nonempty() { [ -n "$(setting_get "$1" 2>/dev/null || true)" ]; }
# storage: the data pools (all pools when there is no data pool) exist and are all mounted
pools_ready() {
  local set n
  set=$(pool_names data); [ -n "$set" ] || set=$(pool_names)
  [ -n "$set" ] || return 1
  while IFS= read -r n; do pool_mounted "$n" || return 1; done <<<"$set"
}
has_share() {
  local n
  for n in $(pool_names data); do ls "$(pool_root "$n")/shares" 2>/dev/null | grep -q . && return 0; done
  return 1
}
has_file() { [ -s "$1" ] || [ -L "$1" ]; }
has_notify() {
  has_file "$state/notify-url" || [ -s "$etc/notify-url" ] || [ "$(setting_get notifications 2>/dev/null || true)" = true ] ||
    grep -qx notifications "$etc/capabilities" 2>/dev/null
}
has_caps() { [ -s "$etc/capabilities" ]; }

main_pool=$(pool_default data 2>/dev/null || pool_default apps 2>/dev/null || true)
if [ -n "$main_pool" ]; then store_cmd="hs pool $main_pool add"; store_page=/storage/pools/$main_pool
else store_cmd="hs pool <name> add"; store_page=/storage/pools; fi
data_pool=$(pool_default data 2>/dev/null || true)
share_page=/storage/shares${data_pool:+?pool=$data_pool}

row language      "Language"                   "hs config set language de"       /settings           set_nonempty language
row timezone      "Time zone"                  "hs config set timeZone Europe/Vienna" /settings      machine_has timeZone
row notifications "Set up notifications"       "hs config set notifications true" /operations/notifications has_notify
row storage       "Storage pool"               "$store_cmd" "$store_page" pools_ready
row share         "A first share"              "hs share add <name>"             "$share_page" has_share
row backup        "Backup disk"                "hs backup init <device>"         /protection/backup  has_file "$state/restic-password"
if vault_configured; then row vault "Vault (secrets)" "hs unlock" /storage/vault vault_is_open; fi
row parts         "Optional parts (capabilities)" "hs config set capabilities ..." /settings         has_caps
if grep -qx gateway "$etc/capabilities" 2>/dev/null; then row gateway-dns "Wildcard DNS for the gateway proxy" "hs gateway check" /instances/services bash "$here/gateway.sh" --check-wildcard; fi
row finished      "Setup finished"             "hs config set setupDone true"    /setup              bash -c '[ "$(. "$1/lib/setting.sh"; setting_get setupDone 2>/dev/null)" = true ]' _ "$here"
