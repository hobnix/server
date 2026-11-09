#!/usr/bin/env bash
# help: -
# help.de: -
# args: <template.xml> [--name <app>] [--out <folder>]
# hs docker import-unraid: turn an Unraid Community Apps template (XML) into a compose draft for `hs docker import`.
# Without --out it only prints the plan: image, ports, volumes (only appdata maps), environment NAMES, the WebUI address and everything the
# draft could not carry over (network, privileged, ExtraParams, other host paths, devices but /dev/dri). With --out <folder> it writes
# docker-compose.yml (and app.env with the NAMES of secrets, empty values) into a NEW folder and starts nothing: the install is the compose
# importer's job (`hs docker import`), with its own plan and typed name. Never overwrites. The XML is read by scripts/lib/unraid_import.py.
# UNVERIFIED against real Community Apps templates beyond the fixtures in tests/fixtures/unraid/.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/ui.sh"

usage() { fail "$(t 'Usage: hs docker import-unraid <template.xml> [--name <app>] [--out <folder>]')"; }

src= name= out=
while [ $# -gt 0 ]; do
  case "$1" in
    --name) [ $# -ge 2 ] || usage; name=$2; shift 2 ;;
    --out) [ $# -ge 2 ] || usage; out=$2; shift 2 ;;
    -h|--help) usage ;;
    -*) fail "$(t 'Unknown option: %s' "$1")" ;;
    *) [ -z "$src" ] || usage; src=$1; shift ;;
  esac
done
[ -n "$src" ] || usage
[ -f "$src" ] && [ -r "$src" ] || fail "$(t 'Cannot read the template: %s' "$src")"
if [ -n "$name" ] && ! [[ "$name" =~ ^[a-z0-9][a-z0-9_-]{0,40}$ ]]; then
  fail "$(t 'The app name is not valid: lower case letters, digits, - and _.')"
fi
if [ -n "$out" ] && [ -e "$out" ]; then fail "$(t 'The folder exists already, nothing is overwritten: %s' "$out")"; fi

errf=$(mktemp); trap 'rm -f "$errf"' EXIT
args=("$src"); [ -z "$name" ] || args+=(--name "$name")
json=$(python3 -I "$here/lib/unraid_import.py" "${args[@]}" 2>"$errf") || {
  warn "$(t 'The template could not be read: %s' "$(head -n1 "$errf")")"
  exit 1
}
# rows: kind, level, where, text (tab separated; the helper's JSON has no tabs in them)
rows=$(printf '%s' "$json" | python3 -I -c 'import json,sys
d=json.load(sys.stdin)
print("name\t-\t-\t"+d["name"])
for r in d["rows"]: print("\t".join(x.replace("\t"," ").replace("\n"," ") for x in r))')
app=$(awk -F'\t' '$1 == "name" { print $4 }' <<<"$rows")

show() {   # show <heading> <kind>
  local h=$1 kind=$2 k lv where text first=1
  while IFS=$'\t' read -r k lv where text; do
    [ "$k" = "$kind" ] || continue
    if [ "$first" = 1 ]; then step "$h"; first=0; fi
    if [ "$lv" = warn ]; then warn "$text ($where)"; else kv "$where" "$text"; fi
  done <<<"$rows"
}
step "$(t 'Plan for the Unraid template %s' "$app")"
show "$(t 'Service')" service
show "$(t 'Ports')" port
show "$(t 'Volumes and devices')" volume
show "$(t 'Environment (names only)')" env
show "$(t 'Web address')" webui
show "$(t 'Not carried over')" unmapped
n=$(awk -F'\t' '$1 == "unmapped"' <<<"$rows" | wc -l)
[ "$n" -eq 0 ] || note "$(t '%s items need your decision before the app is the same as on Unraid.' "$n")"

if [ -z "$out" ]; then
  ok "$(t 'Preview only: nothing was written. Add --out <folder> to write the draft.')"
  exit 0
fi

mkdir -p "$out"
printf '%s' "$json" | python3 -I -c 'import json,sys
d=json.load(sys.stdin); o=sys.argv[1]
open(o+"/docker-compose.yml","x").write(d["compose"])
if d["env"]: open(o+"/app.env","x").write(d["env"])' "$out"
ok "$(t 'Draft written to %s. Nothing was started.' "$out")"
note "$(t 'UNVERIFIED: the draft was checked against test templates only. Read it before you import it.')"
if [ -f "$out/app.env" ]; then
  next_step "hs docker import $out/docker-compose.yml --name $app --env-file $out/app.env (fill in app.env first)"
else
  next_step "hs docker import $out/docker-compose.yml --name $app"
fi
