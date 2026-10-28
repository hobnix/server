#!/usr/bin/env bash
# Capabilities (docs/PLAN-modular-core.md step 3): every folder in capabilities/ has a valid manifest, every tag in
# the schema points at one, the Nix modules exist, and capability.sh reads the list Nix writes. No root, no server.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
GEN="python3 $SCRIPTS/schema-gen.py"

echo "-- manifests"
bad=$(python3 - "$ROOT" <<'EOF'
import os, re, sys, tomllib
root = sys.argv[1]
cdir = os.path.join(root, 'capabilities')
names = sorted(d for d in os.listdir(cdir) if os.path.isdir(os.path.join(cdir, d)))
for n in names:
    f = os.path.join(cdir, n, 'capability.toml')
    if not os.path.exists(f):
        print('%s: no capability.toml' % n); continue
    m = tomllib.load(open(f, 'rb'))
    if m.get('name') != n: print('%s: name is %r' % (n, m.get('name')))
    if not m.get('title') or not m.get('title_de'): print('%s: title and title_de needed' % n)
    if m.get('kind') not in ('feature', 'provider'): print('%s: kind must be feature or provider' % n)
    for k in ('requires', 'provides', 'needs'):
        if not isinstance(m.get(k, []), list): print('%s: %s must be a list' % (n, k))
    for r in m.get('requires', []):
        if r not in names: print('%s: requires unknown capability %s' % (n, r))
    for k in ('nix', 'notes'):
        if k in m and not os.path.exists(os.path.join(cdir, n, m[k])): print('%s: %s = %s is missing' % (n, k, m[k]))
    pdir = 'reverse-proxy' if n == 'gateway' else n   # the gateway proxy is the local slot of the reverse proxy: its variant lives beside zoraxy.sh
    for v in m.get('variants', []):
        if not os.path.exists(os.path.join(root, 'scripts', 'providers', pdir, v + '.sh')): print('%s: variant %s has no scripts/providers/%s/%s.sh' % (n, v, pdir, v))
    if 'extension' in m and not isinstance(m['extension'], bool): print('%s: extension must be true or false' % n)
    if m.get('extension') and not os.path.exists(os.path.join(cdir, n, 'commands.tsv')): print('%s: an extension package needs a commands.tsv' % n)
    if os.path.exists(os.path.join(cdir, n, 'commands.tsv')) and not m.get('extension'): print('%s: commands.tsv without extension = true' % n)
    if os.path.exists(os.path.join(cdir, n, 'module.nix')) and m.get('nix') != 'module.nix': print('%s: module.nix exists but the manifest does not say nix = "module.nix"' % n)
EOF
) || bad="the manifest check itself failed: $bad"
check_eq "every manifest is valid" "" "$bad"

echo "-- providers (private-access)"
check_eq "configuration.nix does not name a VPN interface" "0" "$(grep -c 'tailscale0' "$ROOT/configuration.nix" || true)"
check_eq "the module of the provider sets the interface list" "1" "$(grep -c 'hs.privateInterfaces = \[ "tailscale0" \]' "$ROOT/capabilities/tailscale/module.nix" || true)"
provides=$(python3 - "$ROOT" <<'EOF'
import os, sys, tomllib
root = sys.argv[1]
for n in sorted(os.listdir(root + '/capabilities')):
    f = root + '/capabilities/%s/capability.toml' % n
    if os.path.exists(f):
        m = tomllib.load(open(f, 'rb'))
        for p in m.get('provides', []):
            print('%s:%s:%s' % (n, p, m.get('kind')))
EOF
)
check_eq "who provides what (a provider has kind provider)" "dashboard:dashboard:provider docker:docker-manager:provider gateway:local-proxy:provider network:network:provider reverse-proxy:reverse-proxy:provider tailscale:private-access:provider" "$(printf '%s' "$provides" | paste -sd' ' | tr -cd '[:alnum:]: -')"

echo "-- tags point at a capability"
names=$(ls "$ROOT/capabilities" | while read -r d; do [ -d "$ROOT/capabilities/$d" ] && echo "$d"; done | sort)
tagged=$($GEN capabilities | tr -d $'\r' | cut -f2 | sort -u)
check_eq "every capability named in the schema has a folder" "" "$(comm -13 <(printf '%s\n' "$names") <(printf '%s\n' "$tagged"))"
reg=$(grep -v '^#' "$SCRIPTS/lib/registry.tsv" | grep -oE 'capability:[a-z0-9-]+' | sed 's/capability://' | sort -u)
check_eq "every capability named in the registry has a folder" "" "$(comm -13 <(printf '%s\n' "$names") <(printf '%s\n' "$reg"))"

echo "-- capability.sh"
export HS_CAPABILITIES_FILE=$WORK/capabilities
# shellcheck source=scripts/lib/capability.sh
. "$SCRIPTS/lib/capability.sh"
check "no file: nothing is on" bash -c '. "$1/lib/capability.sh"; ! capability_on metrics' _ "$SCRIPTS"
printf 'metrics\ntailscale\n' > "$HS_CAPABILITIES_FILE"
check "a listed name is on" capability_on metrics
check "a name that is only a prefix is not" bash -c '. "$1/lib/capability.sh"; ! capability_on metric' _ "$SCRIPTS"
check_eq "the list" "metrics tailscale" "$(capability_list | tr '\n' ' ' | sed 's/ $//')"

echo "-- a capability implied by a runtime setting (vps)"
export HS_STATE_DIR=$WORK/state HS_ETC_DIR=$WORK/etc; mkdir -p "$HS_STATE_DIR" "$HS_ETC_DIR"
: > "$HS_CAPABILITIES_FILE"
check "off while neither setting is set" bash -c '. "$1/lib/capability.sh"; ! capability_on vps' _ "$SCRIPTS"
setting_set vpsHost 10.0.0.9
check "on when vpsHost is set" capability_on vps
setting_unset vpsHost; setting_set proxyStatusUrl http://x:9740/
check "on when proxyStatusUrl is set" capability_on vps
setting_unset proxyStatusUrl
check "off again when it is removed" bash -c '. "$1/lib/capability.sh"; ! capability_on vps' _ "$SCRIPTS"
check_eq "implied_by names real runtime settings" "" "$(python3 - "$ROOT" <<'EOF'
import os, subprocess, sys, tomllib
root = sys.argv[1]
settings = {l.split('\t')[0] for l in subprocess.run([sys.executable, root + '/scripts/schema-gen.py', 'settings'], capture_output=True, text=True).stdout.splitlines()}
for n in sorted(os.listdir(root + '/capabilities')):
    f = root + '/capabilities/%s/capability.toml' % n
    if os.path.exists(f):
        for k in tomllib.load(open(f, 'rb')).get('implied_by', []):
            if k not in settings: print('%s: implied_by %s is not a runtime setting' % (n, k))
EOF
)"

echo "-- hs help leaves out the commands of a capability that is off"
helptext() { HS_LANG=en HS_PLAIN=1 bash "$SCRIPTS/lib/hs.sh" help "$@" 2>&1; }
check "off: hs vps key is not listed" bash -c '! HS_LANG=en HS_PLAIN=1 bash "$1/lib/hs.sh" help 2>&1 | grep -q "vps key"' _ "$SCRIPTS"
check_out "off: hs help --all still lists it" "vps key|sys vps plan" helptext --all
check_out "off: hs help vps key still explains it" "vps key" helptext vps key
setting_set vpsHost 10.0.0.9
check_out "on: it is listed" "vps key" helptext
setting_unset vpsHost

echo "-- the web server's list agrees"
web=$(HS_CAPABILITIES_FILE="$HS_CAPABILITIES_FILE" HS_SETTINGS_DIR="$HS_STATE_DIR/settings" python3 - "$SCRIPTS" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location('ws', sys.argv[1] + '/web-serve.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(' '.join(m.capabilities()))
EOF
)
check_eq "nothing on" "" "$web"
printf 'metrics\n' > "$HS_CAPABILITIES_FILE"; setting_set vpsHost h
web=$(HS_CAPABILITIES_FILE="$HS_CAPABILITIES_FILE" HS_SETTINGS_DIR="$HS_STATE_DIR/settings" python3 - "$SCRIPTS" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location('ws', sys.argv[1] + '/web-serve.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(' '.join(m.capabilities()))
EOF
)
check_eq "the file and the implied one" "metrics vps" "$web"
check_eq "the shell agrees" "metrics vps" "$(capability_list | tr '\n' ' ' | sed 's/ $//')"

finish
