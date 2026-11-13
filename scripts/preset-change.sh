#!/usr/bin/env bash
# help: apply a preset without asking anything: what would happen (plan), then do it (start); only fills what is not set yet
# help.de: eine Vorlage ohne Rückfragen anwenden: was passieren würde (plan), dann ausführen (start); füllt nur, was noch nicht gesetzt ist
# args: plan|start apply <name>
# System command (hs sys preset plan|start): for the interface and tests. It never asks and prints plain key<TAB>value lines like dc-change.sh.
# The work is preset.sh's (apply --yes). plan: exit 0 = allowed, 1 = refused. Output: status ok|refused, reason<TAB><text>,
#   heading|step|note<TAB><line>, long<TAB>no. start: answers status done.
# Test knobs: HS_PRESETS_DIR, HS_MACHINE_FILE, HS_SETTINGS_DIR, HS_PYTHON.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/machine.sh"
. "$here/lib/setting.sh"
py=${HS_PYTHON:-python3}
pre() { PYTHONUTF8=1 "$py" "$here/preset.py" "$@"; }

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

verb=${1:-}; action=${2:-}; name=${3:-}
case "$verb" in plan|start) ;; *) echo "usage: preset-change.sh plan|start apply <name>" >&2; exit 1 ;; esac
[ "$action" = apply ] || refuse "unknown action (apply)"
[[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || refuse "No preset called '$name'."
meta=$(pre meta "$name" 2>/dev/null) || refuse "No preset called '$name'."
title=$(awk -F'\t' '$1 == "title" { print $2 }' <<<"$meta")

export HS_PLAIN=1 HS_LANG=en HS_CALLER=${HS_CALLER:-ui}

if [ "$verb" = start ]; then
  HS_CALLER=ui bash "$here/preset.sh" apply "$name" --yes >/dev/null 2>&1 || refuse "the preset could not be applied"
  printf 'status\tdone\n'
  exit 0
fi

plan_rows() {   # same as preset.sh plan_rows: kind<TAB>key<TAB>value<TAB>state (set|kept)
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
  done < <(pre rows "$name")
}

rows=$(plan_rows) || refuse "the preset could not be read"
printf 'status\tok\nheading\tapply the preset %s\n' "$title"
todo=0 machine=0
while IFS=$'\t' read -r kind key val st; do
  [ -n "$kind" ] || continue
  if [ "$st" = set ]; then
    printf 'step\tset %s = %s\n' "$key" "$val"
    todo=1
    [ "$kind" != machine ] || machine=1
  else
    printf 'note\t%s is set already and is kept\n' "$key"
  fi
done <<<"$rows"
[ "$todo" = 1 ] || printf 'note\teverything in this preset is set already\n'
[ "$machine" = 0 ] || printf 'note\tmachine.toml changes; hs rebuild applies them\n'
printf 'long\tno\n'
