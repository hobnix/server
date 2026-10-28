#!/usr/bin/env bash
# help: keep machine.toml in the layout of machine.toml.example (new options in their place), check it, or convert an old machine.nix
# help.de: hält die machine.toml im Aufbau von machine.toml.example (neue Optionen an ihrem Platz), prüft sie oder wandelt eine alte machine.nix um
# args: sync [--check] | check | migrate | --list
# Why: machine.toml is yours and not in git, but new versions of this repo learn new options. `sync` writes the file
# anew from machine.toml.example (same sections, order and comments) with the values you have set, so
# `diff machine.toml machine.toml.example` shows only your values. New options appear commented out; keys the example does
# not know are kept in a closing section. Your own comments inside the paragraphs are replaced by the example's.
#
#   hs config sync            rewrite the file in the layout of the example (copy: /var/lib/hs/machine.toml.before-sync)
#   hs config sync --check    only list the new options
#   hs config check           parse the file, unknown keys, wrong types, missing required options (exit 1 on an error)
#   hs config migrate         machine.nix -> machine.toml (the old file becomes machine.nix.migrated)
#   --list                    machine-readable: new<TAB>option<TAB>description per new option, nothing else
# Test knobs: HS_MACHINE_FILE, HS_MACHINE_EXAMPLE, HS_MACHINE_OLD (the old machine.nix), HS_STATE_DIR, HS_QUIET_OK=1.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/machine.sh"

machine=$(machine_file)
example=$(machine_example)
old=${HS_MACHINE_OLD:-$(dirname "$machine")/machine.nix}
state=${HS_STATE_DIR:-/var/lib/hs}

usage() { say "usage: hs config sync [--check] | check | migrate"; exit 1; }

cmd=${1:-sync}; [ $# -eq 0 ] || shift
[ -f "$example" ] || fail "$(t 'No %s.' "$example")"

# print the new options as a table (names and what they do)
show_new() {   # show_new <lines new<TAB>key<TAB>desc>
  { thead 'Option' 'What it is'
    awk -F'\t' '{ printf "%s\t%s\n", $2, $3 }' <<<"$1"; } | table
}

case "$cmd" in
  --list)
    [ -f "$machine" ] || exit 0
    machine_tool sync "$example" "$machine" --check | awk -F'\t' '$1 == "new"' ;;

  sync)
    check=false
    case "${1:-}" in "") ;; --check) check=true ;; *) usage ;; esac
    if [ ! -f "$machine" ]; then
      if [ -f "$old" ]; then note "$(t 'There is a %s but no %s yet. Convert it with: hs config migrate' "$old" "$machine")"
      else note "$(t 'No %s yet: copy %s to it first.' "$machine" "$example")"; fi
      exit 0
    fi
    mkdir -p "$state" 2>/dev/null || true
    # Options that became runtime settings (config/schema.toml store = "settings") move out of machine.toml first, so the sync
    # does not push them into the "not in the example" section. This also covers the first `hs update` after the change, which
    # still runs the OLD update.sh (it only calls this script from the new checkout).
    if ! $check && [ -f "$here/config.sh" ]; then
      HS_QUIET_OK=1 bash "$here/config.sh" migrate-settings 2>/dev/null || true
    fi
    args=(sync "$example" "$machine")
    $check && args+=(--check) || args+=(--backup "$state/machine.toml.before-sync")
    out=$(machine_tool "${args[@]}") || fail "$(t 'Could not sync %s; nothing changed.' "$machine")"
    new=$(awk -F'\t' '$1 == "new"' <<<"$out")
    unknown=$(awk -F'\t' '$1 == "unknown" { print $2 }' <<<"$out" | paste -sd' ')
    res=$(awk -F'\t' '$1 == "result" { print $2 }' <<<"$out")
    if [ -n "$new" ]; then
      step "New options for machine.toml"
      show_new "$new"
      if $check; then note "Add them to your file with: hs config sync"
      else
        ok "$(t 'Added %s option(s) in their place in %s (commented out).' "$(wc -l <<<"$new" | tr -d ' ')" "$machine")"
        note "$(t 'The old file: %s' "$state/machine.toml.before-sync")"
        note "To use one, remove the '# ' and run: hs rebuild"
      fi
    elif [ "$res" = changed ] && ! $check; then
      ok "$(t '%s now has the layout of the example.' "$machine")"
      note "$(t 'The old file: %s' "$state/machine.toml.before-sync")"
    elif [ -z "${HS_QUIET_OK:-}" ]; then
      ok "machine.toml has every option of the current example."
    fi
    [ -z "$unknown" ] || warn "$(t 'Not in the example (kept at the end of the file): %s' "$unknown")" ;;

  check)
    [ -f "$machine" ] || fail "$(t 'No %s.' "$machine")"
    out=$(machine_tool check "$example" "$machine") && rc=0 || rc=$?
    [ "$rc" -lt 2 ] || fail "$(t '%s does not parse; see the message above.' "$machine")"
    py=${HS_PYTHON:-python3}; command -v "$py" >/dev/null 2>&1 || py=python
    moved=$(PYTHONUTF8=1 "$py" "$here/schema-gen.py" settings 2>/dev/null | cut -f1 || true)
    while IFS=$'\t' read -r kind key text; do
      [ -n "$kind" ] || continue
      # an option that moved out of machine.toml (runtime setting): say where it lives now instead of "unknown option"
      if [ "$kind" = warn ] && grep -qx "$key" <<<"$moved"; then
        text="a runtime setting now (no rebuild): run hs config migrate-settings to move it out of machine.toml"
      fi
      if [ "$kind" = error ]; then paint "$c_red" "  ✗ $key: $text"; else warn "$key: $text"; fi
    done <<<"$out"
    [ "$rc" -eq 0 ] || exit 1
    [ -z "${HS_QUIET_OK:-}" ] && ok "machine.toml is fine." || true ;;

  migrate)
    if [ -f "$machine" ]; then
      note "$(t '%s exists already: nothing to convert.' "$machine")"
      exit 0
    fi
    [ -f "$old" ] || fail "$(t 'No %s to convert.' "$old")"
    command -v nix-instantiate >/dev/null 2>&1 || fail "nix-instantiate is needed to read the old machine.nix."
    json=$(mktemp); trap 'rm -f "$json"' EXIT
    nix-instantiate --eval --strict --json -E "import $old" > "$json" 2>/dev/null \
      || fail "$(t 'Could not read %s; fix it or convert it by hand (see %s).' "$old" "$example")"
    machine_tool sync "$example" "$machine" --from-json "$json" > /dev/null \
      || fail "$(t 'Could not write %s; nothing changed.' "$machine")"
    chown --reference="$old" "$machine" 2>/dev/null || true
    chmod --reference="$old" "$machine" 2>/dev/null || true
    machine_tool check "$example" "$machine" > /dev/null || warn "$(t 'The new file has problems: run hs config check')"
    mv "$old" "$old.migrated"
    ok "$(t 'Converted %s to %s.' "$old" "$machine")"
    note "$(t 'The old file is kept as %s.' "$old.migrated")"
    note "Compare with the example: diff $machine $example" ;;

  *) usage ;;
esac
