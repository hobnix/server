#!/usr/bin/env bash
# help: presets: ready-made choices for a server (list, show, apply; apply only fills what is not set yet)
# help.de: Vorlagen: fertige Entscheidungen für einen Server (list, show, apply; apply füllt nur, was noch nicht gesetzt ist)
# args: list | show <name> | apply <name> [--dry-run] [--yes]
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/machine.sh"
. "$here/lib/setting.sh"
py=${HS_PYTHON:-python3}
pre() { PYTHONUTF8=1 "$py" "$here/preset.py" "$@"; }

# A preset (presets/<name>.toml) is a list of choices: [machine] keys for machine.toml, [settings] for the runtime settings, recipes to read.
# `apply` fills the gaps: a key that is set already keeps its value (change it with hs config set), so it is safe on a running server.
# Test knobs: HS_PRESETS_DIR, HS_MACHINE_FILE, HS_SETTINGS_DIR, HS_PYTHON.
usage() {
  say "usage: hs preset list                    the presets"
  say "       hs preset show <name>             what a preset contains and what applying it would set here"
  say "       hs preset apply <name> [--dry-run] [--yes]   set what is not set yet (asks first)"
  exit 1
}

plan_rows() {   # plan_rows <name>: kind<TAB>key<TAB>value<TAB>state (set|kept)
  local kind key val cur st
  while IFS=$'\t' read -r kind key val; do
    st=set
    if [ "$kind" = machine ]; then
      if machine_has "$key"; then st=kept; fi
    else
      cur=$(setting_get "$key" 2>/dev/null || true)
      if [ -n "$cur" ]; then st=kept; fi
    fi
    printf '%s\t%s\t%s\t%s\n' "$kind" "$key" "$val" "$st"
  done < <(pre rows "$1")
}

show_plan() {
  local name=$1 rows
  rows=$(plan_rows "$name")
  if [ -z "$rows" ]; then note "This preset sets nothing."; return 0; fi
  { thead 'Where' 'Option' 'Value' 'Here'
    awk -F'\t' '{ printf "%s\t%s\t%s\t%s\n", $1, $2, $3, ($4 == "set" ? "will be set" : "already set, kept") }' <<<"$rows"
  } | table
}

cmd=${1:-}; shift || true
case "$cmd" in
  list)
    { thead 'Preset' 'What'; pre list "${hs_lang:-en}"; } | table ;;
  show)
    name=${1:-}; [ -n "$name" ] || usage
    meta=$(pre meta "$name" "${hs_lang:-en}") || exit 1
    kv "Preset" "$name"
    kv "About" "$(awk -F'\t' '$1 == "description" { print $2 }' <<<"$meta")"
    recipes=$(awk -F'\t' '$1 == "recipes" { print $2 }' <<<"$meta")
    [ -z "$recipes" ] || kv "Recipes" "$recipes"
    show_plan "$name" ;;
  apply)
    name=${1:-}; [ -n "$name" ] || usage; shift
    dry=false; yes=false
    for a in "$@"; do case "$a" in --dry-run) dry=true ;; --yes) yes=true ;; *) usage ;; esac; done
    pre meta "$name" >/dev/null || exit 1
    step "Preset: $name"
    rows=$(plan_rows "$name")
    show_plan "$name"
    todo=$(awk -F'\t' '$4 == "set"' <<<"$rows")
    [ -n "$todo" ] || { ok "Nothing to set: everything in this preset is set already."; exit 0; }
    $dry && { note "Dry run: nothing changed."; exit 0; }
    if ! $yes; then
      [ -t 0 ] && [ -t 1 ] || fail "Applying a preset asks first: run it in a terminal, or add --yes."
      confirm "Set these $(grep -c . <<<"$todo") option(s) now?" || { note "Nothing changed."; exit 0; }
    fi
    needs_rebuild=false
    while IFS=$'\t' read -r kind key val st; do
      [ "$st" = set ] || continue
      if [ "$kind" = machine ]; then
        [ -f "$(machine_file)" ] || fail "There is no machine.toml yet ($(machine_file))."
        machine_set "$key" "$val" preset >/dev/null || fail "$(t "'%s' could not be written to machine.toml. Nothing else was changed." "$key")"
        needs_rebuild=true
      else
        setting_set "$key" "$val"
      fi
      ok "$(t '%s is set' "$key")"
    done <<<"$todo"
    ! $needs_rebuild || note "machine.toml changed: hs rebuild applies it." ;;
  *) usage ;;
esac
