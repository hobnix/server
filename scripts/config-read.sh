#!/usr/bin/env bash
# help: the options of machine.toml for the interface (list) or the result of the check as plain text (check)
# help.de: die Optionen der machine.toml für die Oberfläche (list) oder das Ergebnis der Prüfung als reiner Text (check)
# args: list | check
# System command (hs sys config list|check), read only, plain, never translated, never asks.
#   list    one line per option of config/schema.toml, in the order of the schema, tab separated:
#             section  key  current  default  type  help  settable  store
#             section   name of the section header of the example (Server, Interface, Network, ...)
#             current   the value in machine.toml as written (strings plain, lists and tables as TOML); empty when the option is off;
#                       for notifyUrl, heartbeatUrl and sshKeys only "(set)" or "(not set)", never the value
#             default   the value after `# key = ` / `key = ` in the example (what you get when you switch it on); empty for the secrets
#             type      bool | number | string | list | table
#             help      the comment of the option's paragraph in the example, on one line (indented examples left out)
#             settable  yes | no: whether hs sys config plan|start set may change it (scripts/lib/config-keys.sh)
#             store     machine (machine.toml, needs hs rebuild) | settings (/var/lib/hs/settings, takes effect at once;
#                       "current" then comes from config-list.py, which reads the same files as scripts/lib/setting.sh; secrets show only "(set)" or "(not set)")
#   check   the lines of `hs config check` without colours: "error: <key>: <text>", "warning: <key>: <text>", then
#           "machine.toml is fine." (exit 0); exit 1 on an error, 2 when the file does not parse
# Test knobs: HS_MACHINE_FILE, HS_MACHINE_EXAMPLE, HS_PYTHON.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/machine.sh"
. "$here/lib/config-keys.sh"
machine=$(machine_file)
example=$(machine_example)
py=${HS_PYTHON:-python3}; command -v "$py" >/dev/null 2>&1 || py=python

case "${1:-}" in
  list) PYTHONUTF8=1 "$py" "$here/config-list.py" "$machine" ;;
  check)
    [ -f "$machine" ] || { echo "No $machine."; exit 2; }
    moved=$(PYTHONUTF8=1 "$py" "$here/schema-gen.py" settings 2>/dev/null | cut -f1 || true)
    rc=0; out=$(machine_tool check "$example" "$machine" 2>&1) || rc=$?
    if [ "$rc" -ge 2 ]; then printf '%s\n%s does not parse.\n' "$out" "$machine"; exit 2; fi
    while IFS=$'\t' read -r kind key text; do
      [ -n "$kind" ] || continue
      # an option that moved out of machine.toml (store = settings): still honoured by Nix, but say where it lives now
      if [ "$kind" = warn ] && grep -qx "$key" <<<"$moved"; then
        text="runtime setting now (no rebuild): run hs config migrate-settings to move it out of machine.toml"
      fi
      case "$kind" in error) printf 'error: %s: %s\n' "$key" "$text" ;; *) printf 'warning: %s: %s\n' "$key" "$text" ;; esac
    done <<<"$out"
    [ "$rc" -eq 0 ] || exit 1
    echo "machine.toml is fine." ;;
  *) echo "usage: config-read.sh list|check" >&2; exit 1 ;;
esac
