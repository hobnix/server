#!/usr/bin/env bash
# The option schema (config/schema.toml, docs/PLAN-modular-core.md step 1): what is derived from it is up to date, and
# the files that still carry their own key lists agree with it. No root, no server (needs python3 with tomllib).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
GEN="python3 $SCRIPTS/schema-gen.py"
SCHEMA_KEYS=$($GEN list | cut -f1 | sort)
T=$'\t'

echo "-- derived files"
check "machine.toml.example, config-keys.sh, defaults.nix and the web allowlist are up to date" $GEN check
check "the example parses" python3 -c "import tomllib,sys; tomllib.load(open(sys.argv[1],'rb'))" "$ROOT/machine.toml.example"

echo "-- every type in the schema matches the value in the example"
bad=$(python3 - "$ROOT/machine.toml.example" <<'EOF'
import importlib.util, os, sys, tomllib
types = {bool: 'bool', int: 'int', float: 'float', str: 'string', list: 'list', dict: 'table'}
spec = importlib.util.spec_from_file_location('sg', os.path.join(os.path.dirname(sys.argv[1]), 'scripts', 'schema-gen.py'))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
for it in m.options(m.load()):
    stmt = it['value']
    got = types[type(tomllib.loads(stmt)[it['key']])]
    if got != it['type']:
        print('%s: schema says %s, the example value is %s' % (it['key'], it['type'], got))
EOF
)
check_eq "no type disagrees" "" "$bad"

echo "-- the keys configuration.nix and install.nix read are in the schema"
read_keys=$(grep -ohE 'machine\.[A-Za-z]+' "$ROOT/configuration.nix" "$ROOT/install.nix" "$ROOT"/capabilities/*/module.nix | sed 's/^machine\.//' | grep -vxE 'nix|toml' | sort -u)
unknown=$(comm -23 <(printf '%s\n' "$read_keys") <(printf '%s\n' "$SCHEMA_KEYS") | tr '\n' ' ')
check_eq "no key is read that the schema does not know" "" "$unknown"

echo "-- the defaults live in the schema (config/defaults.nix), not in the Nix files"
# "key<TAB>expression" for every `machine.<key> or <expression>;` left in a Nix file
nix_defaults() { grep -ohE 'machine\.[A-Za-z]+ or [^;]+;' "$@" | sed -E 's/^machine\.([A-Za-z]+) or (.*);$/\1\t\2/' | sort -u; }
literal='^("[^"]*"|-?[0-9]+|true|false|null|\[[ 0-9a-z"-]*\])$'
plain=$($GEN defaults | tr -d $'\r' | awk -F"$T" -v re="$literal" '$2 ~ re { print $1 }' | sort | tr '\n' ' ')
inlist=$(sed -nE 's/^  ([A-Za-z]+) = .*;$/\1/p' "$ROOT/config/defaults.nix" | sort | tr '\n' ' ')
check_eq "defaults.nix has every default that is a plain value, and nothing else" "$plain" "$inlist"
computed=$($GEN defaults | tr -d $'\r' | awk -F"$T" -v re="$literal" '$2 !~ re' | sort)
left=$(nix_defaults "$ROOT/configuration.nix" "$ROOT/install.nix" "$ROOT"/capabilities/*/module.nix | tr -d $'\r')
check_eq "only defaults that refer to another setting are still an 'or' in the Nix files" "$computed" "$left"
check "configuration.nix reads machine = defaults // machine.toml" grep -q 'import ./config/defaults.nix //' "$ROOT/configuration.nix"
check "install.nix reads machine = defaults // machine.toml" grep -q 'import ./config/defaults.nix //' "$ROOT/install.nix"

echo "-- value rules (hs sys config set checks them)"
rule() { $GEN rule "$@" | tr -d $'\r'; }
check_eq "choices" "string${T}en de${T}${T}${T}" "$(rule language)"
check_eq "a number with choices and a minimum" "int${T}1 2 3 4 6 8 12 24${T}1${T}${T}" "$(rule syncEveryHours)"
check_out "a pattern with its hint" "a colour such as" $GEN rule webAccent
check "an unknown option has no rule" bash -c "! $GEN rule noSuchOption"
# every settable text option must have choices or a pattern, else any text would be accepted
bad_rules=$($GEN list | tr -d $'\r' | awk -F"$T" '$3 == "yes" && $2 == "string" {print $1}' | while read -r k; do
  rule "$k" | awk -F"$T" -v k="$k" '$2 == "" && $4 == "" {print k}'; done | tr '\n' ' ')
check_eq "no settable text option without a rule" "" "${bad_rules// /}"

echo "-- the settings pages (page, [settings]) are checked"
# every key has a page
check_eq "pages lists every key once" "$SCHEMA_KEYS" "$($GEN pages | cut -f1 | sort)"
# schema-gen.py runs from a copy so that a changed schema or manifest can be tried (ROOT is the folder above scripts/)
trial() {   # trial <python edit of the copy's files, as sed on config/schema.toml | manifest> -> exit code of `check`
  local d; d=$(mktemp -d)
  mkdir -p "$d/scripts/lib" "$d/config" "$d/web/src/settings"
  cp "$SCRIPTS/lib/registry.tsv" "$d/scripts/lib/"
  cp "$SCRIPTS/schema-gen.py" "$SCRIPTS/web-serve.py" "$d/scripts/"
  cp "$SCRIPTS/../config/schema.toml" "$d/config/"
  cp -r "$SCRIPTS/../capabilities" "$d/capabilities"
  "$@" "$d"
  python3 "$d/scripts/schema-gen.py" check >/dev/null 2>&1; local rc=$?
  rm -rf "$d"
  return $rc
}
edit_schema() { sed -i "$1" "$2/config/schema.toml"; }
sec_no_page() { edit_schema '/^title = "Storage"$/{n;d}' "$1"; }
adv_settable() { edit_schema '/^key = "syncEveryHours"$/a page = "advanced"' "$1"; }
bad_cap() { edit_schema '/^key = "syncEveryHours"$/a page = "cap:nothing-here"' "$1"; }
bad_settings_key() { printf '
[settings]
flavour = "x"
' >> "$1/capabilities/metrics/capability.toml"; }
bad_status() { printf '
[settings]
status = "gateway nothing"
' >> "$1/capabilities/metrics/capability.toml"; }
trial sec_no_page; rc=$?; check_eq "a section without page (and options without one) dies" 2 "$rc"
trial adv_settable; rc=$?; check_eq "advanced on a settable option dies" 2 "$rc"
trial bad_cap; rc=$?; check_eq "an unknown cap:<name> dies" 2 "$rc"
trial bad_settings_key; rc=$?; check_eq "an unknown [settings] key dies" 2 "$rc"
trial bad_status; rc=$?; check_eq "a [settings] status naming no sys row dies" 2 "$rc"
check_eq "the gateway page declares its status read" "gateway health" "$(python3 -c "import json;print(json.load(open('$SCRIPTS/../web/src/settings/layout.gen.json'))['caps']['gateway']['status'])")"
check_eq "advanced is only on options that are not settable" "" "$($GEN pages | awk -F"$T" '$2 == "advanced" {print $1}' | grep -Fxf <($GEN list | awk -F"$T" '$3 == "yes" {print $1}') | tr '
' ' ')"

echo "-- the web allowlist is exactly the settable options"
settable=$($GEN list | awk -F"$T" '$3 == "yes" {print $1}' | sort | tr '\n' ' ')
web=$(python3 - "$SCRIPTS/web-serve.py" <<'EOF'
import re, sys
t = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'CONFIG_KEYS = \((.*?)\)\n', t, re.S)
print(' '.join(sorted(re.sub(r'["\s]', '', m.group(1)).split('|'))) + ' ')
EOF
)
check_eq "web-serve.py CONFIG_KEYS" "$settable" "$web"

finish
