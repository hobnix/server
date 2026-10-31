#!/usr/bin/env bash
# help: change the gateway setup (ports, domains, certificates, unknown names) in one go: what would happen (plan), then do it (start)
# help.de: das Gateway-Setup (Ports, Domains, Zertifikate, unbekannte Namen) in einem Zug ändern: was passieren würde (plan), dann ausführen (start)
# args: plan|start setup --set <key>=<value>... [--confirm <port>]
# System command (hs sys gateway plan|start setup), for the interface and tests. It never asks and prints plain key<TAB>value lines like
# config-change.sh and disk-change.sh. The keys are the ones of the steps in capabilities/gateway/capability.toml (GW_KEYS below); an empty
# value switches the option off again (the default applies). Options of machine.toml are written there, the others (store = settings)
# to the settings files.
#   plan: exit 0 = allowed, 1 = refused. Output: status ok|refused, reason<TAB><text> | heading|step|note|warn|danger|command<TAB><line>,
#     confirm_name<TAB><port> and long<TAB>yes. Refused with the message of the matching assertion in capabilities/gateway/module.nix
#     (a port that is used already, gatewayAcmeEmail without gatewayPublicHttps, ...).
#   A port that is opened or a changed tunnel port has a danger line and confirm_name = that port (public https > public http > tunnel);
#     start then needs --confirm <port>.
#   start: the same checks; a copy of machine.toml and of the settings files goes to $HS_STATE_DIR/gateway-setup.before/, the keys are written,
#     `hs config check` runs (the copy is put back when it reports an error), then hs rebuild runs as a background job (status started,
#     unit). When the rebuild fails the job puts the copy back and says so (it does not rebuild again). No reboot.
# Test knobs: HS_MACHINE_FILE, HS_MACHINE_EXAMPLE, HS_SETTINGS_DIR, HS_STATE_DIR, HS_PYTHON, HS_CONFIG_CHECK (script that stands in for
# config-read.sh check), HS_GATEWAY_REBUILD (stands in for rebuild.sh), HS_GATEWAY_NO_JOB (run the rebuild at once, no systemd-run).
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/machine.sh"
. "$here/lib/setting.sh"

# the keys of the gateway steps (capability.toml); web-serve.py GW_SET lists the same ones (tests/gateway-setup.sh compares)
GW_KEYS="reverseProxy gatewayTunnelPort gatewayPublicHttps gatewayPublicHttp proxyDomains gatewayDirectDomains gatewayAcmeEmail gatewayAcmeStaging gatewayUnknownHostLocal gatewayUnknownHostPublic"
# what applies when a key is not set (config/defaults.nix; tests/gateway-setup.sh compares); reverseProxy and the domain lists: empty
gw_default() {
  case "$1" in
    gatewayTunnelPort|gatewayPublicHttps|gatewayPublicHttp) echo 0 ;;
    gatewayAcmeStaging) echo true ;;
    gatewayUnknownHostLocal) echo 404 ;;
    gatewayUnknownHostPublic) echo drop ;;
    *) echo "" ;;
  esac
}

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

verb=${1:-}; action=${2:-}
case "$verb" in plan|start) ;; *) echo "usage: gateway-setup.sh plan|start setup --set <key>=<value>... [--confirm <port>]" >&2; exit 1 ;; esac
[ "$action" = setup ] || [ "$action" = job-rebuild ] || refuse "unknown action (setup)"
[ "$action" != job-rebuild ] || [ "$verb" = start ] || refuse "unknown action (setup)"   # job-rebuild is what the background job runs, never a plan
shift 2

machine=$(machine_file)
state=${HS_STATE_DIR:-/var/lib/hs}
before=$state/gateway-setup.before

# put the copy back (machine.toml, the settings files of the gateway keys; a settings file that did not exist is removed again)
restore_before() {
  local k
  [ -d "$before" ] || return 0
  [ ! -f "$before/machine.toml" ] || cp -p "$before/machine.toml" "$machine"
  for k in $GW_KEYS; do
    if [ -f "$before/settings/$k" ]; then cp -p "$before/settings/$k" "$(setting_path "$k")"
    elif [ -f "$before/settings-absent/$k" ]; then rm -f "$(setting_path "$k")"; fi
  done
}

if [ "$action" = job-rebuild ]; then
  . "$here/lib/ui.sh"
  rebuild=${HS_GATEWAY_REBUILD:-$here/rebuild.sh}
  step "Apply the gateway setup"
  if bash "$rebuild"; then ok "The gateway setup is applied."; exit 0; fi
  restore_before
  warn "The rebuild failed: machine.toml and the gateway settings were put back as they were before. Nothing was rebuilt again; run hs rebuild when you are ready."
  exit 1
fi

# ---- arguments ----------------------------------------------------------------------------------
declare -A new=(); order=()
confirm=""
while [ $# -gt 0 ]; do
  case "$1" in
    --set)
      [ $# -ge 2 ] || refuse "--set needs key=value"
      [[ "$2" == *=* ]] || refuse "--set needs key=value"
      k=${2%%=*}
      case " $GW_KEYS " in *" $k "*) ;; *) refuse "'$k' is not part of the gateway setup." ;; esac
      [ -z "${new[$k]+x}" ] || refuse "'$k' is given twice."
      new[$k]=${2#*=}; order+=("$k"); shift 2 ;;
    --confirm) [ $# -ge 2 ] || refuse "--confirm needs a value"; confirm=$2; shift 2 ;;
    *) refuse "unexpected argument '$1'" ;;
  esac
done
[ ${#order[@]} -gt 0 ] || refuse "Nothing to change: give at least one --set key=value."

py=${HS_PYTHON:-python3}; command -v "$py" >/dev/null 2>&1 || py=python
list=$(bash "$here/config-read.sh" list 2>/dev/null || true)
col() { awk -F'\t' -v k="$1" -v c="$2" '$2 == k && !f { print $c; f = 1 }' <<<"$list"; }

# the value that applies now: machine.toml or the settings file, else the default
cur() {
  local v
  if [ "$(col "$1" 8)" = settings ]; then v=$(setting_get "$1" 2>/dev/null || true); [ -r "$(setting_path "$1")" ] || v=$(gw_default "$1")
  elif machine_has "$1"; then v=$(machine_get "$1" 2>/dev/null || true)
  else v=$(gw_default "$1"); fi
  printf '%s' "$v"
}

# value rules from the schema (choices, minimum, pattern), the type of the option; effective new values
declare -A old=() val=() toml=() off=()
for k in $GW_KEYS; do old[$k]=$(cur "$k"); val[$k]=${old[$k]}; done
for k in "${order[@]}"; do
  v=${new[$k]}
  type=$(col "$k" 5)
  [ -n "$type" ] || refuse "'$k' is not an option of machine.toml.example."
  if [ -z "$v" ]; then
    off[$k]=1; val[$k]=$(gw_default "$k"); continue
  fi
  case "$type" in
    bool) case "$v" in true|false) toml[$k]=$v ;; *) refuse "'$k' must be true or false." ;; esac ;;
    number)
      [[ "$v" =~ ^[0-9]{1,6}$ ]] || refuse "'$k' must be a whole number."
      toml[$k]=$v ;;
    string)
      [[ "$v" != *[\"\\]* ]] || refuse "Quotes and backslashes are not allowed in a value."
      toml[$k]="\"$v\"" ;;
    *) refuse "'$k' is a list or table: edit machine.toml on the server." ;;
  esac
  rule=$(PYTHONUTF8=1 "$py" "$here/schema-gen.py" rule "$k" 2>/dev/null || true)
  r_choices=$(cut -f2 <<<"$rule"); r_min=$(cut -f3 <<<"$rule"); r_pattern=$(cut -f4 <<<"$rule"); r_hint=$(cut -f5 <<<"$rule")
  if [ -n "${r_choices:-}" ]; then case " $r_choices " in *" $v "*) ;; *) refuse "'$k' must be one of: $r_choices." ;; esac; fi
  if [ -n "${r_min:-}" ] && [ "$v" -lt "$r_min" ] 2>/dev/null; then refuse "'$k' must be $r_min or more."; fi
  if [ -n "${r_pattern:-}" ] && ! grep -Eq -- "$r_pattern" <<<"$v"; then refuse "'$k' must be ${r_hint:-valid}."; fi
  val[$k]=$v
done
for k in gatewayTunnelPort gatewayPublicHttps gatewayPublicHttp; do
  [ "${val[$k]}" -le 65535 ] 2>/dev/null || refuse "$k = ${val[$k]} is not a port (0 to 65535)."
done

# the keys that really change; machine.toml needed for the ones stored there
changed=()
for k in "${order[@]}"; do
  [ "${val[$k]}" != "${old[$k]}" ] || continue
  changed+=("$k")
  if [ "$(col "$k" 8)" != settings ]; then [ -f "$machine" ] || refuse "There is no machine.toml on this server."; fi
done
[ ${#changed[@]} -gt 0 ] || refuse "Nothing changes: the gateway has these values already."

# ---- the assertions of capabilities/gateway/module.nix ------------------------------------------
pubS=${val[gatewayPublicHttps]}; pubH=${val[gatewayPublicHttp]}; tun=${val[gatewayTunnelPort]}
email=${val[gatewayAcmeEmail]}; unkPublic=${val[gatewayUnknownHostPublic]}
webPort=$(machine_get webPort 2>/dev/null || true); webPort=${webPort:-8480}
webUi=$(machine_get webUi 2>/dev/null || true); webUi=${webUi:-false}      # config/defaults.nix (tests/gateway-setup.sh compares)
webTs=$(machine_get webTailscale 2>/dev/null || true); webTs=${webTs:-false}
in_list() { local x=$1; shift; local y; for y in "$@"; do [ "$x" = "$y" ] && return 0; done; return 1; }
if [ "$webUi" = true ]; then
  in_list "$webPort" 80 443 "$pubS" "$pubH" && [ "$webPort" != 0 ] && refuse "The gateway proxy owns port 80 (and the public ports); the web interface needs its own port: webPort = 8480."
fi
[ "$pubS" = 0 ] || ! in_list "$pubS" 80 22 139 445 8443 9740 "$webPort" || refuse "gatewayPublicHttps = $pubS is a port the server already uses; suggested 443 (or 4443 behind a router that translates ports)."
[ "$pubH" = 0 ] || ! in_list "$pubH" 443 22 139 445 8443 9740 "$webPort" || refuse "gatewayPublicHttp = $pubH is a port the server already uses; suggested 80 (or 8008 behind a router that translates ports)."
if [ "$pubS" = 443 ] && [ "$webUi" = true ] && [ "$webTs" = true ]; then
  refuse "gatewayPublicHttps = 443 clashes with webTailscale (tailscale serve holds 443): set webTailscale = false, or use another port behind a router that translates ports."
fi
if [ "$tun" != 0 ] && [ -f "$machine" ]; then   # tunFrom empty is only fine with the incus capability (the container on the internal link)
  . "$here/lib/capability.sh"
  from=$(machine_get_json gatewayTunnelFrom 2>/dev/null || true)
  case "${from//[[:space:]]/}" in
    ""|"[]") capability_on incus || refuse "gatewayTunnelPort is set but gatewayTunnelFrom is empty: set gatewayTunnelFrom in machine.toml to the address of the cloudflared container, e.g. [ \"10.99.0.2/32\" ] (with the incus capability on, an empty list means the container on the internal link)." ;;
  esac
fi
{ [ "$pubS" != "$pubH" ] || [ "$pubS" = 0 ]; } || refuse "gatewayPublicHttps and gatewayPublicHttp must be different ports."
[ "$tun" = 0 ] || ! in_list "$tun" 80 443 22 139 445 8443 9740 "$webPort" "$pubS" "$pubH" || refuse "gatewayTunnelPort = $tun is a port the server already uses; suggested 8081."
{ [ -z "$email" ] || [ "$pubS" != 0 ]; } || refuse "gatewayAcmeEmail needs gatewayPublicHttps = 443 (the router forwards 443 to this server)."
{ [ -z "$email" ] || [[ "$email" =~ ^[^@\ ]+@[^@\ ]+\.[^@\ ]+$ ]]; } || refuse "gatewayAcmeEmail is not an e-mail address."
acme=false; { [ -n "$email" ] && [ "$pubS" != 0 ]; } && acme=true
{ [ "$unkPublic" = drop ] || [ "$pubS" = 0 ] || $acme; } || refuse "gatewayUnknownHostPublic = \"404\" on the public HTTPS port needs a certificate (gatewayAcmeEmail); use \"drop\" for now."

# ---- the confirmation word: an opened port or a changed tunnel port ------------------------------
opened=()      # warn lines
word=""
is_changed() { in_list "$1" "${changed[@]}"; }
for k in gatewayPublicHttps gatewayPublicHttp; do
  if is_changed "$k" && [ "${val[$k]}" != 0 ]; then opened+=("$k ${val[$k]}"); fi
done
if [ ${#opened[@]} -gt 0 ]; then
  if is_changed gatewayPublicHttps && [ "$pubS" != 0 ]; then word=$pubS; else word=$pubH; fi
elif is_changed gatewayTunnelPort; then
  word=$tun
  [ "$word" != 0 ] || word=${old[gatewayTunnelPort]}
fi

if [ "$verb" = start ]; then
  [ -z "$word" ] || [ "$confirm" = "$word" ] || refuse "type the port to confirm: $word"
fi

# ---- plan -----------------------------------------------------------------------------------------
if [ "$verb" = plan ]; then
  printf 'status\tok\nheading\tchange the gateway setup\n'
  for k in "${changed[@]}"; do printf 'step\t%s %s -> %s\n' "$k" "${old[$k]:--}" "${val[$k]:--}"; done
  for o in "${opened[@]}"; do
    printf 'warn\tPort %s (%s) will accept connections from the internet when the router forwards it.\n' "${o#* }" "${o% *}"
  done
  if [ -n "$word" ]; then
    printf 'danger\tThis changes which ports of this server take connections from the network. A wrong value can make the gateway or the web interface unreachable until it is fixed on the server.\n'
  fi
  printf 'step\tcheck machine.toml afterwards and put the old files back if the check fails\n'
  printf 'step\tapply it: hs rebuild (a background job)\n'
  printf 'note\tIf the rebuild fails, machine.toml and the settings are put back as they were, but nothing is rebuilt again. The old copy is kept in %s.\n' "$before"
  printf 'command\ths rebuild\n'
  [ -z "$word" ] || printf 'confirm_name\t%s\n' "$word"
  printf 'long\tyes\n'
  exit 0
fi

# ---- start ----------------------------------------------------------------------------------------
# a job that runs already holds the .before copy: never overwrite it
if "${HS_SYSTEMCTL:-systemctl}" list-units 'hs-job-gateway-setup-*.service' --state=active,activating --no-legend --no-pager 2>/dev/null | grep -q .; then
  refuse "A gateway setup is still being applied (hs job running). Wait until it has finished."
fi
rm -rf "$before"; mkdir -p "$before/settings" "$before/settings-absent"
[ ! -f "$machine" ] || cp -p "$machine" "$before/machine.toml"
for k in $GW_KEYS; do
  if [ -f "$(setting_path "$k")" ]; then cp -p "$(setting_path "$k")" "$before/settings/$k"
  else : > "$before/settings-absent/$k"; fi
done

bad=""
for k in "${changed[@]}"; do
  if [ "$(col "$k" 8)" = settings ]; then
    if [ -n "${off[$k]+x}" ]; then setting_unset "$k"; else setting_set "$k" "${new[$k]}"; fi
  elif [ -n "${off[$k]+x}" ]; then
    machine_has "$k" && { machine_unset "$k" gateway-setup >/dev/null || bad=$k; }
  else
    machine_set "$k" "${toml[$k]}" gateway-setup >/dev/null || bad=$k
  fi
  [ -z "$bad" ] || break
done
if [ -n "$bad" ]; then restore_before; refuse "$bad could not be written (the files were put back)."; fi
check=${HS_CONFIG_CHECK:-$here/config-read.sh}
if [ -n "${HS_CONFIG_CHECK:-}" ]; then bash "$check" >/dev/null 2>&1 || bad=1; else bash "$check" check >/dev/null 2>&1 || bad=1; fi
if [ -n "$bad" ]; then
  restore_before
  refuse "machine.toml would have problems after that change (hs config check); it was put back."
fi

if [ "${HS_GATEWAY_NO_JOB:-}" = 1 ]; then
  bash "$(cd "$here" && pwd)/gateway-setup.sh" start job-rebuild >/dev/null 2>&1 || refuse "the rebuild failed (the files were put back)"
  printf 'status\tdone\n'
  exit 0
fi
. "$here/lib/job.sh"
unit=$(hs_job gateway-setup "apply the gateway setup (hs rebuild)" -- bash "$(cd "$here" && pwd)/gateway-setup.sh" start job-rebuild) || { restore_before; refuse "the job could not be started"; }
printf 'status\tstarted\nunit\t%s\n' "$unit"
