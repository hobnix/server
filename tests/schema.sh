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
# step data: a manifest [settings] with one step; the first line of each variant is the mistake
step_manifest() {   # step_manifest <dir> <apply line> <step body lines...>
  local d=$1 ap=$2; shift 2
  { printf '
[settings]
%s
[[settings.steps]]
' "$ap"; printf '%s
' "$@"; } >> "$d/capabilities/metrics/capability.toml"
}
step_dup_id() { step_manifest "$1" 'apply = "gateway setup"' 'id = "one"' 'title = "T"' 'text = "x"' 'keys = []' '[[settings.steps]]' 'id = "one"' 'title = "T"' 'text = "x"' 'keys = []'; }
step_bad_id() { step_manifest "$1" 'apply = "gateway setup"' 'id = "One"' 'title = "T"' 'text = "x"' 'keys = []'; }
step_bad_key() { step_manifest "$1" 'apply = "gateway setup"' 'id = "one"' 'title = "T"' 'text = "x"' 'keys = ["noSuchOption"]'; }
step_preset_val() { step_manifest "$1" 'apply = "gateway setup"' 'id = "one"' 'title = "T"' 'text = "x"' 'keys = ["syncEveryHours"]' 'question = "Q?"' '[[settings.steps.options]]' 'id = "o"' 'label = "O"' 'text = "t"' 'set = { syncEveryHours = 6 }'; }
step_no_apply() { step_manifest "$1" '' 'id = "one"' 'title = "T"' 'text = "x"' 'keys = []'; }
apply_no_steps() { printf '
[settings]
apply = "gateway setup"
' >> "$1/capabilities/metrics/capability.toml"; }
trial step_dup_id; rc=$?; check_eq "a step id twice dies" 2 "$rc"
trial step_bad_id; rc=$?; check_eq "a malformed step id dies" 2 "$rc"
trial step_bad_key; rc=$?; check_eq "a step key that is no option dies" 2 "$rc"
trial step_preset_val; rc=$?; check_eq "an option value that is no string dies" 2 "$rc"
trial step_no_apply; rc=$?; check_eq "steps without apply die" 2 "$rc"
trial apply_no_steps; rc=$?; check_eq "apply without steps dies" 2 "$rc"
step_opt_noq() { step_manifest "$1" 'apply = "gateway setup"' 'id = "one"' 'title = "T"' 'text = "x"' 'keys = ["language"]' '[[settings.steps.options]]' 'id = "o"' 'label = "O"' 'text = "t"' 'set = { language = "de" }'; }
step_presets() { step_manifest "$1" 'apply = "gateway setup"' 'id = "one"' 'title = "T"' 'text = "x"' 'keys = ["language"]' 'question = "Q?"' '[[settings.steps.presets]]' 'id = "p"' 'label = "P"' 'set = { language = "de" }'; }
step_opt_key() { step_manifest "$1" 'apply = "gateway setup"' 'id = "one"' 'title = "T"' 'text = "x"' 'keys = ["syncEveryHours"]' 'question = "Q?"' '[[settings.steps.options]]' 'id = "o"' 'label = "O"' 'text = "t"' 'set = { language = "de" }'; }
step_opt_choice() { step_manifest "$1" 'apply = "gateway setup"' 'id = "one"' 'title = "T"' 'text = "x"' 'keys = ["dockerSize"]' 'question = "Q?"' '[[settings.steps.options]]' 'id = "o"' 'label = "O"' 'text = "t"' 'set = { dockerSize = "xx" }'; }
step_opt_two_rec() { step_manifest "$1" 'apply = "gateway setup"' 'id = "one"' 'title = "T"' 'text = "x"' 'keys = ["language"]' 'question = "Q?"' '[[settings.steps.options]]' 'id = "o"' 'label = "O"' 'text = "t"' 'set = { language = "de" }' 'recommended = true' '[[settings.steps.options]]' 'id = "o2"' 'label = "O"' 'text = "t"' 'set = { language = "en" }' 'recommended = true'; }
step_opt_rec_str() { step_manifest "$1" 'apply = "gateway setup"' 'id = "one"' 'title = "T"' 'text = "x"' 'keys = ["language"]' 'question = "Q?"' '[[settings.steps.options]]' 'id = "o"' 'label = "O"' 'text = "t"' 'set = { language = "de" }' 'recommended = "yes"'; }
step_opt_notext() { step_manifest "$1" 'apply = "gateway setup"' 'id = "one"' 'title = "T"' 'text = "x"' 'keys = ["language"]' 'question = "Q?"' '[[settings.steps.options]]' 'id = "o"' 'label = "O"' 'set = { language = "de" }'; }
trial step_opt_noq; rc=$?; check_eq "options without a question die" 2 "$rc"
trial step_presets; rc=$?; check_eq "presets die (replaced by options)" 2 "$rc"
trial step_opt_key; rc=$?; check_eq "an option key outside the step keys dies" 2 "$rc"
trial step_opt_choice; rc=$?; check_eq "an option value outside the choices dies" 2 "$rc"
trial step_opt_two_rec; rc=$?; check_eq "two recommended options die" 2 "$rc"
trial step_opt_rec_str; rc=$?; check_eq "recommended that is no bool dies" 2 "$rc"
trial step_opt_notext; rc=$?; check_eq "an option without text dies" 2 "$rc"
# core pages: [[page]] appended to the schema; first the mistake, the good block passes
page_block() {   # page_block <dir> <id> <step lines...>
  local d=$1 id=$2; shift 2
  { printf '\n[[page]]\nid = "%s"\n' "$id"; printf '%s\n' "$@"; } >> "$d/config/schema.toml"
}
# page_strip <dir> <id>: drops the real [[page]] block of that id (it is the last one of its kind or followed by the next [[page]])
page_strip() {
  python3 - "$1/config/schema.toml" "$2" <<'PY'
import re, sys
p, i = sys.argv[1:]
t = open(p, encoding='utf-8', newline='').read()
t = re.sub(r'\[\[page\]\]\nid = "%s"\n.*?(?=\n\[\[page\]\]\n|\Z)' % re.escape(i), '', t, flags=re.S)
open(p, 'w', encoding='utf-8', newline='').write(t)
PY
}
PG_HEAD=('[[page.steps]]' 'id = "s"' 'title = "T"' 'text = "x"' 'keys = ["backupNewShares"]' 'question = "Q?"')
PG_OPT=('[[page.steps.options]]' 'id = "o"' 'label = "O"' 'text = "t"' 'set = { backupNewShares = "true" }')
PG_STEP=("${PG_HEAD[@]}" "${PG_OPT[@]}")
page_unknown() { page_block "$1" nowhere "${PG_STEP[@]}"; }
page_advanced() { page_block "$1" advanced "${PG_STEP[@]}"; }
page_twice() { page_block "$1" backups "${PG_STEP[@]}"; page_block "$1" backups "${PG_STEP[@]}"; }
page_other_key() { page_strip "$1" general; page_block "$1" general "${PG_STEP[@]}"; }
page_not_settable() { page_strip "$1" general; page_block "$1" general '[[page.steps]]' 'id = "s"' 'title = "T"' 'text = "x"' 'keys = ["bulkType"]'; }
page_apply() { page_block "$1" backups 'apply = "config apply"' "${PG_STEP[@]}"; }
page_when_key() { page_block "$1" backups "${PG_HEAD[@]}" 'when = { noSuchOption = "x" }' "${PG_OPT[@]}"; }
page_when_choice() { page_block "$1" backups "${PG_HEAD[@]}" 'when = { syncEveryHours = "5" }' "${PG_OPT[@]}"; }
# every core page is declared in the real schema now, so the good block replaces the real general page
page_good() { page_strip "$1" general; page_block "$1" general '[[page.steps]]' 'id = "s"' 'title = "T"' 'text = "x"' 'keys = ["timeZone"]' 'question = "Q?"' 'when = { bulkType = "zfs" }' '[[page.steps.options]]' 'id = "o"' 'label = "O"' 'text = "t"' 'set = { timeZone = "UTC" }'; }
trial page_unknown; rc=$?; check_eq "an unknown [[page]] id dies" 2 "$rc"
trial page_advanced; rc=$?; check_eq "[[page]] id advanced dies" 2 "$rc"
trial page_twice; rc=$?; check_eq "a [[page]] twice dies" 2 "$rc"
trial page_other_key; rc=$?; check_eq "a page step key of another page dies" 2 "$rc"
trial page_not_settable; rc=$?; check_eq "a page step key that is not settable dies" 2 "$rc"
trial page_apply; rc=$?; check_eq "apply in a [[page]] dies" 2 "$rc"
trial page_when_key; rc=$?; check_eq "when with an unknown key dies" 2 "$rc"
trial page_when_choice; rc=$?; check_eq "when with a value outside the choices dies" 2 "$rc"
# a good block passes `check` once layout.gen.json is regenerated: trial runs check only, so write first
page_good_write() { page_good "$1"; python3 "$1/scripts/schema-gen.py" write >/dev/null 2>&1; }
trial page_good_write; rc=$?; check_eq "a good [[page]] block passes" 0 "$rc"
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

echo "-- the scripts run from a copy without capabilities/ (as /nix/store on a server): hs sys config list still works"
copy=$(mktemp -d)
cp -r "$SCRIPTS" "$copy/scripts"
check "schema-gen loads the schema when there is no capabilities/ next to scripts/" env HS_SCHEMA="$ROOT/config/schema.toml" python3 "$copy/scripts/schema-gen.py" list
rm -rf "$copy"

echo "-- every option is rebuild (store machine) or live (store settings); a live option is never read by Nix (docs/adr/0002)"
check "every option has a class" bash -c '[ -z "$($1 list | awk -F"\t" "\$6 != \"machine\" && \$6 != \"settings\"")" ]' _ "$GEN"
bad_store=$(mktemp -d)
sed '0,/^key = "hostName"/s//store = "elsewhere"\nkey = "hostName"/' "$ROOT/config/schema.toml" > "$bad_store/schema.toml"
if HS_SCHEMA="$bad_store/schema.toml" python3 "$SCRIPTS/schema-gen.py" list >/dev/null 2>&1; then fail "a store that is neither machine nor settings was accepted"
else pass "a store that is neither machine nor settings is refused"; fi
rm -rf "$bad_store"
# Known violations: live options that configuration.nix still reads (it turns them into /etc/hs files or HS_WEB_* variables, so a change
# also needs a rebuild). Moving them out is open work on hobnix/server#252; the list may only shrink: a key that is clean is an error here.
NIX_READS_LIVE="backupNewShares heartbeatUrl icons language loginMessage notifyUrl proxyStatusUrl vpsHost"
bad=$(python3 - "$ROOT" "$NIX_READS_LIVE" <<'PYEOF'
import os, re, subprocess, sys
root, known = sys.argv[1], set(sys.argv[2].split())
out = subprocess.run(['python3', os.path.join(root, 'scripts', 'schema-gen.py'), 'list'], capture_output=True, text=True).stdout
live = [l.split('\t')[0] for l in out.splitlines() if l.split('\t')[5] == 'settings']
reads = set()
for d, dirs, files in os.walk(root):
    dirs[:] = [x for x in dirs if x not in ('.git', 'node_modules', '.work', 'web', '.claude')]
    for f in files:
        if not f.endswith('.nix') or (os.path.basename(d) == 'config' and f == 'defaults.nix'):
            continue
        for line in open(os.path.join(d, f), encoding='utf-8'):
            code = line.split('#')[0]
            for k in live:
                if re.search(r'\bmachine\.%s\b|\bmachine \? %s\b' % (k, k), code):
                    reads.add(k)
for k in sorted(reads - known):
    print('%s: a live option (store = "settings") is read by a Nix file' % k)
for k in sorted(known - reads):
    print('%s: no longer read by Nix, remove it from NIX_READS_LIVE' % k)
PYEOF
)
if [ -z "$bad" ]; then pass "no live option is read by a Nix file, except the listed ones"; else fail "$bad"; fi

finish
