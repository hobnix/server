#!/usr/bin/env bash
# hs sys gateway plan|start setup (scripts/gateway-setup.sh): plan shapes, the refusals of capabilities/gateway/module.nix, the typed port,
# the copy that is put back (failed config check, failed rebuild). No root, no systemd: files in a temp folder, a fake rebuild.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en HS_CALLER=test
unset HS_GUIDED_TTY
T=$'\t'
export HS_STATE_DIR=$WORK/state HS_SETTINGS_DIR=$WORK/settings HS_ETC_DIR=$WORK/etc HS_MACHINE_EXAMPLE=$ROOT/machine.toml.example HS_MACHINE_FILE=$WORK/machine.toml
mkdir -p "$HS_STATE_DIR" "$HS_SETTINGS_DIR" "$HS_ETC_DIR"
echo incus > "$WORK/capabilities"; export HS_CAPABILITIES_FILE=$WORK/capabilities   # incus on: an empty gatewayTunnelFrom is fine
printf '#!/usr/bin/env bash\n[ -z "${FAKE_JOB:-}" ] || echo "hs-job-gateway-setup-120000.service loaded active running"\n' > "$WORK/systemctl"; chmod +x "$WORK/systemctl"; export HS_SYSTEMCTL=$WORK/systemctl
G=$SCRIPTS/gateway-setup.sh
fresh() {
  printf 'hostName = "homeserver"\nhostId = "deadbeef"\nwebTailscale = false\n' > "$HS_MACHINE_FILE"
  rm -rf "$HS_SETTINGS_DIR" "$HS_STATE_DIR/gateway-setup.before"; mkdir -p "$HS_SETTINGS_DIR"
}
run() { rc=0; out=$(timeout 60 bash "$G" "$@" </dev/null 2>&1) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }
refused() {   # refused "what" args...: plan is refused with a reason
  local what=$1; shift
  run plan setup "$@"
  check_eq "$what: exit 1" 1 "$rc"
  has "^status${T}refused$" && has "^reason${T}" && pass "$what: status refused with a reason" || fail "$what: $out"
}
fresh

echo "-- the lists agree with defaults.nix and web-serve.py"
keys=$(sed -n 's/^GW_KEYS="\(.*\)"/\1/p' "$G")
def=$(sed -n '/^gw_default()/,/^}/p' "$G")
for kv in gatewayTunnelPort=0 gatewayPublicHttps=0 gatewayPublicHttp=0 gatewayAcmeStaging=true gatewayUnknownHostLocal=404 gatewayUnknownHostPublic=drop; do
  k=${kv%%=*}; v=${kv#*=}
  nixv=$(sed -n "s/^ *$k = \"\\{0,1\\}\\([^\";]*\\)\"\\{0,1\\};.*/\\1/p" "$ROOT/config/defaults.nix" | head -n 1)
  check_eq "default of $k in defaults.nix" "$v" "$nixv"
  grep -q "$k" <<<"$def" && pass "default of $k is in gw_default" || fail "gw_default lacks $k"
done
alt=$(grep -A1 '^GW_SET = ' "$SCRIPTS/web-serve.py" | grep -o '[A-Za-z]*[|)]' | tr -d '|)' | grep -v '^r$' | tr '\n' ' ')
for k in webUi webTailscale; do   # the script reads these two with a default of its own
  nixv=$(sed -n "s/^ *$k = \\([a-z]*\\);.*/\\1/p" "$ROOT/config/defaults.nix" | head -n 1)
  var=$k; [ "$k" != webTailscale ] || var=webTs
  grep -q "^$var=\$(machine_get $k .*$var=\${$var:-$nixv}" "$G" && pass "$k falls back to $nixv like defaults.nix" || fail "$k default in the script is not $nixv"
done
check_eq "web-serve GW_SET names the same keys" "$(tr ' ' '\n' <<<"$keys" | sort | tr '\n' ' ')" "$(tr ' ' '\n' <<<"$alt" | grep . | sort | tr '\n' ' ')"

echo "-- plan: a tunnel"
run plan setup --set reverseProxy=traefik-public --set gatewayTunnelPort=8081
check_eq "exit 0" 0 "$rc"
has "^status${T}ok$" && has "^heading${T}" && has "^step${T}reverseProxy - -> traefik-public$" && has "^step${T}gatewayTunnelPort 0 -> 8081$" && pass "one step per changed key" || fail "steps: $out"
has "^command${T}hs rebuild$" && has "^long${T}yes$" && pass "command and long" || fail "command: $out"
has "^confirm_name${T}8081$" && has "^danger${T}" && pass "a tunnel port: danger and the port to type" || fail "tunnel confirm: $out"
check_eq "plan writes nothing" "no" "$(grep -q gatewayTunnelPort "$HS_MACHINE_FILE" && echo yes || echo no)"

echo "-- plan: a port forward (https wins over http and tunnel)"
run plan setup --set gatewayPublicHttps=443 --set gatewayPublicHttp=80 --set gatewayTunnelPort=8081
check_eq "exit 0" 0 "$rc"
has "^confirm_name${T}443$" && pass "the typed word is the https port" || fail "word: $out"
check_eq "a warn per opened port" 2 "$(grep -c "^warn${T}" <<<"$out")"
run plan setup --set gatewayPublicHttp=80
has "^confirm_name${T}80$" && pass "http alone: 80" || fail "http: $out"
run plan setup --set gatewayUnknownHostLocal=drop
check_eq "no port, no confirmation" 0 "$(grep -c "confirm_name\|^danger" <<<"$out")"
has "^step${T}gatewayUnknownHostLocal 404 -> drop$" && pass "plain step" || fail "plain: $out"
run plan setup --set gatewayAcmeStaging=false
has "^step${T}gatewayAcmeStaging true -> false$" && pass "default shows as the old value" || fail "default: $out"

echo "-- plan: refusals mirror module.nix"
refused "nothing changes" --set gatewayPublicHttps=0
refused "no --set"
refused "a key outside the steps" --set hostName=x
refused "a key twice" --set gatewayPublicHttp=80 --set gatewayPublicHttp=81
refused "no key=value" --set gatewayPublicHttp
refused "not a number" --set gatewayPublicHttp=abc
refused "not a port" --set gatewayPublicHttps=70000
refused "https on ssh" --set gatewayPublicHttps=22
refused "http on 443" --set gatewayPublicHttp=443
refused "same port twice" --set gatewayPublicHttps=4443 --set gatewayPublicHttp=4443
refused "tunnel on the web port" --set gatewayTunnelPort=8480
refused "tunnel on 443" --set gatewayTunnelPort=443
refused "email without https" --set gatewayAcmeEmail=me@example.org
refused "email that is none" --set gatewayPublicHttps=443 --set gatewayAcmeEmail=nonsense
refused "404 for unknown names without a certificate" --set gatewayPublicHttps=443 --set gatewayUnknownHostPublic=404
refused "unknown value" --set gatewayUnknownHostLocal=maybe
refused "bad reverseProxy" --set reverseProxy=nginx
refused "bad domain list" --set proxyDomains='A B'
run plan setup --set gatewayAcmeEmail=me@example.org; has "^reason${T}gatewayAcmeEmail needs gatewayPublicHttps" && pass "the module's message" || fail "message: $out"
run plan setup --set gatewayPublicHttps=443 --set gatewayAcmeEmail=me@example.org --set gatewayUnknownHostPublic=404
check_eq "https + email makes 404 allowed" 0 "$rc"
printf 'hostName = "homeserver"\nhostId = "deadbeef"\nwebUi = true\nwebTailscale = true\n' > "$HS_MACHINE_FILE"
refused "443 clashes with webTailscale" --set gatewayPublicHttps=443
printf 'hostName = "homeserver"\nhostId = "deadbeef"\nwebUi = true\nwebTailscale = false\nwebPort = 443\n' > "$HS_MACHINE_FILE"
refused "the web interface on a public port" --set gatewayPublicHttps=443
# no webUi / webTailscale / webPort lines: the defaults (both false) apply, the router preset plans fine
printf 'hostName = "homeserver"\nhostId = "deadbeef"\n' > "$HS_MACHINE_FILE"
run plan setup --set gatewayPublicHttps=443 --set gatewayPublicHttp=80 --set gatewayAcmeEmail=me@example.org
check_eq "router preset with a bare machine.toml" 0 "$rc"
echo > "$HS_CAPABILITIES_FILE"
refused "tunnel port, no gatewayTunnelFrom, no incus" --set gatewayTunnelPort=8081
run plan setup --set gatewayTunnelPort=8081; has "^reason${T}gatewayTunnelPort is set but gatewayTunnelFrom is empty" && pass "the module's message" || fail "tunnel from: $out"
printf 'hostName = "homeserver"\nhostId = "deadbeef"\ngatewayTunnelFrom = [ "10.99.0.2/32" ]\n' > "$HS_MACHINE_FILE"
run plan setup --set gatewayTunnelPort=8081; check_eq "gatewayTunnelFrom set: allowed" 0 "$rc"
echo incus > "$HS_CAPABILITIES_FILE"
run plan job-rebuild; check_eq "plan job-rebuild is refused" 1 "$rc"
fresh
rm -f "$HS_MACHINE_FILE"; refused "no machine.toml" --set gatewayPublicHttp=80
run plan setup --set reverseProxy=traefik-public; check_eq "a settings key needs no machine.toml" 0 "$rc"
fresh

echo "-- start"
export HS_GATEWAY_NO_JOB=1 HS_GATEWAY_REBUILD=$WORK/rebuild-ok
printf '#!/usr/bin/env bash\necho rebuilt >> "%s/rebuild.log"\n' "$WORK" > "$WORK/rebuild-ok"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/rebuild-bad"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/check-bad"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/check-ok"
export HS_CONFIG_CHECK=$WORK/check-ok   # the real check wants a complete machine.toml
run start setup --set gatewayPublicHttps=443 --set reverseProxy=traefik-public
check_eq "a port opening needs the typed port: refused" 1 "$rc"
has "^reason${T}type the port to confirm: 443" && pass "says which port" || fail "confirm: $out"
check_eq "nothing written" "no" "$(grep -q gatewayPublicHttps "$HS_MACHINE_FILE" && echo yes || echo no)"
run start setup --set gatewayPublicHttps=443 --confirm 80;  check_eq "the wrong word" 1 "$rc"
run start setup --set gatewayPublicHttps=443 --set reverseProxy=traefik-public --set gatewayUnknownHostLocal=drop --confirm 443
check_eq "start with the port: exit 0" 0 "$rc"
has "^status${T}done$" && pass "status done" || fail "start: $out"
check_eq "machine key written" "gatewayPublicHttps = 443" "$(grep '^gatewayPublicHttps' "$HS_MACHINE_FILE")"
check_eq "string key quoted" 'gatewayUnknownHostLocal = "drop"' "$(grep '^gatewayUnknownHostLocal' "$HS_MACHINE_FILE")"
check_eq "settings key in its file" "traefik-public" "$(cat "$HS_SETTINGS_DIR/reverseProxy")"
check_eq "the rebuild ran" "rebuilt" "$(cat "$WORK/rebuild.log")"
check_eq "a copy of machine.toml" "yes" "$(test -f "$HS_STATE_DIR/gateway-setup.before/machine.toml" && echo yes)"
run start setup --set gatewayPublicHttps= --set reverseProxy= --confirm 443 2>/dev/null
check_eq "switching off: exit 0" 0 "$rc"
check_eq "machine key removed" "" "$(grep '^gatewayPublicHttps' "$HS_MACHINE_FILE" || true)"
check_eq "settings file removed" "no" "$(test -e "$HS_SETTINGS_DIR/reverseProxy" && echo yes || echo no)"

echo "-- start: a gateway setup job that runs blocks a second one"
fresh
FAKE_JOB=1 run start setup --set gatewayUnknownHostLocal=drop
check_eq "refused while a job runs" 1 "$rc"
has "^reason${T}A gateway setup is still being applied" && pass "says why" || fail "job: $out"
check_eq "nothing written, no copy made" "no" "$(grep -q gatewayUnknownHostLocal "$HS_MACHINE_FILE" && echo yes || test -d "$HS_STATE_DIR/gateway-setup.before" && echo yes || echo no)"

echo "-- start: the config check fails, the copy is put back"
fresh
before=$(cat "$HS_MACHINE_FILE")
run start setup --set gatewayUnknownHostLocal=drop --set reverseProxy=traefik-public
HS_CONFIG_CHECK=$WORK/check-bad run start setup --set gatewayAcmeStaging=false --set proxyDomains=example.org
check_eq "refused" 1 "$rc"
has "^reason${T}.*put back" && pass "says it was put back" || fail "check: $out"
check_eq "machine.toml as before the change" "gatewayUnknownHostLocal = \"drop\"" "$(grep '^gatewayUnknownHostLocal' "$HS_MACHINE_FILE")"
check_eq "the new key is gone again" "" "$(grep '^gatewayAcmeStaging' "$HS_MACHINE_FILE" || true)"
check_eq "the new settings file is gone again" "no" "$(test -e "$HS_SETTINGS_DIR/proxyDomains" && echo yes || echo no)"
check_eq "the old settings file is kept" "traefik-public" "$(cat "$HS_SETTINGS_DIR/reverseProxy")"
: "$before"

echo "-- start: the rebuild fails, the job puts the copy back"
fresh
rm -f "$WORK/rebuild.log"
HS_GATEWAY_REBUILD=$WORK/rebuild-bad run start setup --set gatewayUnknownHostLocal=drop --set proxyDomains=example.org
check_eq "the failed rebuild is reported" 1 "$rc"
check_eq "machine.toml put back" "" "$(grep '^gatewayUnknownHostLocal' "$HS_MACHINE_FILE" || true)"
check_eq "settings file put back" "no" "$(test -e "$HS_SETTINGS_DIR/proxyDomains" && echo yes || echo no)"
out=$(HS_GATEWAY_REBUILD=$WORK/rebuild-bad bash "$G" start job-rebuild 2>&1 || true)
grep -q "put back" <<<"$out" && pass "the job says so" || fail "job text: $out"

echo "-- no reboot"
check_eq "no reboot in the script" 0 "$(grep -cE '^[^#]*(reboot|shutdown)' "$G")"

finish
