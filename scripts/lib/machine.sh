# shellcheck shell=bash
# Reading and writing machine.toml. The one place that knows the file:
# scripts call these instead of grep/sed on the text. Needs python3 (stdlib tomllib).
#
#   machine_file                 path of the file (HS_MACHINE_FILE, default /etc/nixos/machine.toml)
#   machine_get <key>            value on stdout (a.b = inside a table; a list one item per line); 1 when not set
#   machine_get_json <key>       the same as JSON ("de", true, 4, ["nvidia","intel"])
#   machine_has <key>            true when the option is set (not commented out)
#   machine_set <key> <toml> [tag]   change one line, comments stay; copy in $HS_STATE_DIR/machine.toml.before-<tag>
#   machine_unset <key> [tag]    comment the line out
#   machine_example              path of machine.toml.example (HS_MACHINE_EXAMPLE)
# Test knobs: HS_MACHINE_FILE, HS_MACHINE_EXAMPLE, HS_STATE_DIR, HS_PYTHON.

machine_file() { echo "${HS_MACHINE_FILE:-/etc/nixos/machine.toml}"; }
# The scripts run from a copy in /nix/store (no machine.toml.example next to it): then the example is the one beside machine.toml (the checkout).
machine_example() {
  local e=${HS_MACHINE_EXAMPLE:-}
  [ -n "$e" ] || e=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/machine.toml.example
  [ -f "$e" ] || [ -n "${HS_MACHINE_EXAMPLE:-}" ] || e=$(dirname "$(machine_file)")/machine.toml.example
  echo "$e"
}
machine_tool() {   # machine_tool <args>: the python tool
  local py=${HS_PYTHON:-python3}
  command -v "$py" >/dev/null 2>&1 || py=python
  PYTHONUTF8=1 "$py" "$(dirname "${BASH_SOURCE[0]}")/../machine-toml.py" "$@"
}
machine_get() { [ -f "$(machine_file)" ] || return 1; machine_tool get "$(machine_file)" "$1"; }
machine_get_json() { [ -f "$(machine_file)" ] || return 1; machine_tool get "$(machine_file)" "$1" --json; }
machine_has() { machine_get_json "$1" >/dev/null 2>&1; }
_machine_backup() {   # _machine_backup <tag>: the --backup option for a change, when there is a state folder
  local state=${HS_STATE_DIR:-/var/lib/hs}
  mkdir -p "$state" 2>/dev/null && printf -- '--backup\n%s\n' "$state/machine.toml.before-$1"
}
machine_set() {
  local -a bk=(); mapfile -t bk < <(_machine_backup "${3:-config}")
  machine_tool set "$(machine_file)" "$1" "$2" "${bk[@]}"
}
machine_unset() {
  local -a bk=(); mapfile -t bk < <(_machine_backup "${2:-config}")
  machine_tool unset "$(machine_file)" "$1" "${bk[@]}"
}
