# shellcheck shell=bash
# Shared steps of the recipes; sourced, not run (hs recipe skips files that
# start with "_"). Expects $scripts (the scripts/ folder), $state and $ct.
# The lines a recipe prints (step, spin, ok, warn, fail, box) come from
# scripts/lib/ui.sh, the same helper the other hs commands use.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/ui.sh"
. "$(dirname "${BASH_SOURCE[0]}")/../lib/secret.sh"   # secrets (unifi, grafana-admin) may live in the vault
. "$(dirname "${BASH_SOURCE[0]}")/../lib/machine.sh"   # machine.toml (adDomain, metrics, ...)
. "$(dirname "${BASH_SOURCE[0]}")/../lib/dc.sh"        # dc_name: the domain controller instance (dc1, dc2)
. "$(dirname "${BASH_SOURCE[0]}")/../lib/capability.sh"   # capability_on: is the Docs page there (docs_hint)
. "$(dirname "${BASH_SOURCE[0]}")/../lib/setting.sh"   # setting_get: which providers are set up (reverseProxy, dashboard)
. "$(dirname "${BASH_SOURCE[0]}")/../lib/network.sh"   # network_provider / network_run: the router connection
. "$(dirname "${BASH_SOURCE[0]}")/../lib/internal-link.sh"   # link_get, link_overlaps: the internal link of Incus (internal_link)
# the recipe's own German texts: <package folder>/i18n/<lang>.tsv (the run.sh that sourced this file is BASH_SOURCE[1]); the texts of this file and of
# the shared helpers are in the core catalog
if [ "${hs_lang:-en}" != en ] && [ -n "${BASH_SOURCE[1]:-}" ]; then _i18n_read "$(dirname "${BASH_SOURCE[1]}")/i18n/$hs_lang.tsv"; fi

# ── Preferences ──
# A recipe asks a few things the first time it sets a container up: which
# network, how much memory, which port its web page gets, which address.
# Every question shows its default in brackets and enter keeps it. The answers
# are remembered per container ($state/recipe-<name>.conf), so running the
# recipe again asks nothing; `hs recipe <name> --ask` asks again.
# Without a terminal the defaults are used. Each one can be given up front:
#   sudo RECIPE_PORT=8080 RECIPE_RAM=2048 RECIPE_IP=10.10.95.25 hs recipe <name>
# A name of its own for the container (a second one of the same recipe): `hs recipe <name> --name <container>` (= RECIPE_NAME).
conf="$state/recipe-$ct.conf"
ASK=false
for a in "$@"; do [ "$a" != --ask ] || ASK=true; done
existed=false
if incus info "$ct" >/dev/null 2>&1; then existed=true; fi
interactive() { [ -t 0 ] && [ -t 1 ]; }
preferences_shown=false

# answer <KEY>: an answer given up front (by the web interface or the caller): RECIPE_<KEY> in the environment, else the file
# $HS_SECRETS_DIR/<KEY> (a secret: the job runner writes it root-only and removes the folder when the job ends). Prints nothing when there is none.
answer() {
  local env="RECIPE_$1"
  if [ -n "${!env:-}" ]; then printf '%s' "${!env}"; return 0; fi
  if [ -n "${HS_SECRETS_DIR:-}" ] && [ -s "$HS_SECRETS_DIR/$1" ]; then head -n1 "$HS_SECRETS_DIR/$1"; fi
  return 0
}

# setting <KEY> <question> <default> [what an install made before this question existed has] [pattern] [a value that is not allowed]
# Sets the variable <KEY>. Order: RECIPE_<KEY> from the environment, what was
# chosen last time, then the question (first setup or --ask), then the default.
setting() {
  local key=$1 question=$2 default=$3 legacy=${4:-$3} pattern=${5:-.+} not=${6:-} env="RECIPE_$1" saved value shown
  saved=$(sed -n "s/^$key=//p" "$conf" 2>/dev/null | tail -n1 || true)
  shown=${saved:-$default}
  if $existed && [ -z "$saved" ]; then shown=$legacy; fi
  if [ -n "${!env:-}" ]; then
    value=${!env}
    [[ "$value" =~ ^($pattern)$ ]] && [ "$value" != "$not" ] || fail "$(t "%s='%s' does not fit: %s" "$env" "$value" "$question")"
  elif { [ -n "$saved" ] || $existed; } && ! $ASK; then
    value=$shown
  elif interactive; then
    $preferences_shown || { step "Preferences (enter keeps the value in brackets)"; preferences_shown=true; }
    while :; do
      value=$(ask "$question" "$shown")
      [[ "$value" =~ ^($pattern)$ ]] && [ "$value" != "$not" ] && break
      warn "$(t "'%s' does not fit here, try again." "$value")"
    done
  else
    value=$shown
  fi
  printf -v "$key" '%s' "$value"
  mkdir -p "$state" 2>/dev/null || true
  # remembered for the next run (not possible without root: then it is asked again)
  { { grep -v "^$key=" "$conf" 2>/dev/null || true; echo "$key=$value"; } > "$conf.tmp" && mv "$conf.tmp" "$conf"; } 2>/dev/null || true
}

a_port='[1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5]'
a_number='[1-9][0-9]*'
a_name='[A-Za-z0-9][A-Za-z0-9._-]*'
a_fqdn='([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}'

# The port of the app's web page. A container has its own address, so 80 is
# free and saves typing a port in the browser. $2: the port an install from
# before this question has.
port_setting() {   # port_setting <what the page is, e.g. "Grafana"> <legacy port> [default]
  setting PORT "$(t 'Port of the web page of %s' "$1")" "${3:-80}" "$2" "$a_port"
}

# "http://<ip>" or "http://<ip>:<port>"
web() { if [ "${PORT:-80}" = 80 ]; then echo "http://$ip"; else echo "http://$ip:$PORT"; fi; }

# Let programs that don't run as root listen on ports below 1024 (inside the container only).
low_ports() {
  [ "${PORT:-80}" -lt 1024 ] || return 0
  incus exec "$ct" -- sh -c 'echo "net.ipv4.ip_unprivileged_port_start=0" > /etc/sysctl.d/90-hs-ports.conf; sysctl -q -p /etc/sysctl.d/90-hs-ports.conf' </dev/null
}

# A shell snippet inside the container, behind one line.
in_ct() {   # in_ct <title> <snippet> [args for the snippet: $1 $2 ...]
  local title=$1 snippet=$2
  shift 2
  spin "$title" incus exec "$ct" -- bash -c "set -euo pipefail; export DEBIAN_FRONTEND=noninteractive; $snippet" bash "$@"
}

# The IPv4 address of an instance, empty while it has none.
address() {   # address <instance>
  incus query "/1.0/instances/$1?recursion=1" |
    jq -r '((.state.network // {}) | (.eth0 // .enp5s0 // {}) | .addresses // []) | map(select(.family == "inet")) | .[0].address // empty'
}

# wait until the instance has an address (any, or exactly <want>): the waiting itself, for spin
wait_address='for _ in $(seq 1 "$3"); do
  a=$(incus query "/1.0/instances/$1?recursion=1" | jq -r "((.state.network // {}) | (.eth0 // .enp5s0 // {}) | .addresses // []) | map(select(.family == \"inet\")) | .[0].address // empty")
  if [ -n "$a" ] && { [ -z "$2" ] || [ "$a" = "$2" ]; }; then exit 0; fi
  sleep 2
done
exit 1'

# Create the container unless it exists, start it, wait for an address.
# Sets $ip.
ensure_container() {   # ensure_container <name> <ram-MB> [more options of manage-ct.sh --create, e.g. --docker, --vm]
  local networks create=() cur
  if ! $existed; then
    # more than one network: which one? ("default" is the one marked default in machine.toml)
    networks=$(incus profile list -f csv -c n | grep -vx default | tr '\n' ' ')
    VLAN=default
    if [ "$(wc -w <<<"$networks")" -gt 1 ]; then
      setting VLAN "$(t "Network (VLAN) for '%s': default, or one of: %s" "$1" "$networks")" default default "default|${networks// /|}"
    fi
    setting RAM "Memory limit in MB" "$2" "$2" "$a_number"
    create=(--ram "$RAM")
    [ "$VLAN" = default ] || create+=(--profile "$VLAN")
  fi
  step "$([[ " $* " == *" --vm "* ]] && _tr "Virtual machine" || _tr "Container")"
  if incus info "$1" >/dev/null 2>&1; then
    ok "$(t "'%s' exists already, keeping it" "$1")"
    [ "$(incus query "/1.0/instances/$1" | jq -r .status)" = Running ] || spin "$(t "Starting '%s'" "$1")" incus start "$1"
    if $ASK; then
      # --ask offers the memory limit again; a change is applied to the instance at once (a virtual machine takes it at its next start)
      cur=$(incus config get "$1" limits.memory 2>/dev/null || true)
      if [[ "$cur" =~ ^[0-9]+GiB$ ]]; then cur=$(( ${cur%GiB} * 1024 )); elif [[ "$cur" =~ ^[0-9]+MiB$ ]]; then cur=${cur%MiB}; else cur=""; fi
      setting RAM "Memory limit in MB" "${cur:-$2}" "${cur:-$2}" "$a_number"
      if [ "$RAM" != "$cur" ]; then
        incus config set "$1" "limits.memory=${RAM}MiB"
        ok "$(t "Memory limit of '%s' is %s MB now" "$1" "$RAM")"
        [ "$(incus query "/1.0/instances/$1" | jq -r .type)" != virtual-machine ] || note "A virtual machine takes the new memory limit at its next start."
      fi
    fi
  else
    spin "$(t "Creating '%s'" "$1")" bash "$scripts/manage-ct.sh" --create "$1" "${create[@]}" "${@:3}"
  fi
  spin "Waiting for its address" bash -c "$wait_address" _ "$1" "" 60 ||
    fail "$(t "'%s' got no address. Check the network (hs ct list)." "$1")"
  ip=$(address "$1")
}

# Give the container a fixed address: the one UniFi has reserved for it, or
# the first free one in a range (default .40 to .99; the plan of this setup:
# .10-.19 access from outside, .20-.29 apps, .30-.39 games, .40-.49 tools). The container is restarted until it
# has that address: right after a reservation the router often still hands
# out the old one. Without UniFi it only says so. Updates $ip.
fixed_address() {   # fixed_address <name> [first] [last]
  local first=${2:-40} last=${3:-99}
  step "Fixed address"
  # a closed vault is not "UniFi is not connected": say so and stop (nothing was changed yet)
  local np rc=0
  np=$(network_provider)
  if [ -n "$np" ]; then network_run ready || rc=$?; fi
  if [ "$rc" = 3 ]; then vault_locked_note >&2; exit 1; fi
  if [ -z "$np" ] || [ "$rc" != 0 ]; then
    warn "$(t 'UniFi is not connected (hs net setup), so the address %s is not fixed.' "$ip")"
    note "$(t "Reserve it for '%s' in UniFi by hand. If the address ever changes, run this recipe again." "$1")"
    return
  fi
  local mac want base n try
  mac=$(incus query "/1.0/instances/$1" | jq -r '.expanded_devices.eth0.hwaddr // empty')
  [ -n "$mac" ] || { bash "$scripts/mac.sh" "$1" >/dev/null; mac=$(incus query "/1.0/instances/$1" | jq -r '.expanded_devices.eth0.hwaddr // empty'); }
  [ -n "$mac" ] || fail "$(t "'%s' has no pinned MAC (hs mac %s), can't reserve an address." "$1" "$1")"

  want=$(network_run reserved "$mac")
  if [ -z "$want" ]; then
    local suggestion="" answer refused
    base=${ip%.*}
    for n in $(seq "$first" "$last") $(seq 50 99); do
      if [ -z "$(network_run used "$base.$n")" ]; then suggestion="$base.$n"; break; fi
    done
    [ -n "$suggestion" ] || fail "$(t 'No free address between %s and %s.' "$base.$first" "$base.99")"
    if [ -n "${RECIPE_IP:-}" ]; then
      spin "$(t 'Reserving %s in UniFi' "$RECIPE_IP")" bash "$scripts/providers/network/$np.sh" set-ip "$mac" "$RECIPE_IP" "$1"
      want=$RECIPE_IP
    elif interactive; then
      # UniFi decides whether an address can be used: taken, or inside the DHCP range, is refused
      note "$(t '%s is the first free address in the range for this kind of service.' "$suggestion")"
      while [ -z "$want" ]; do
        answer=$(ask "$(t "Fixed address for '%s'" "$1")" "$suggestion")
        if [[ ! "$answer" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
          warn "$(t "'%s' is not an address like %s." "$answer" "$suggestion")"
        elif refused=$(network_run set-ip "$mac" "$answer" "$1" 2>&1); then
          ok "$(t "%s is reserved for '%s' in UniFi" "$answer" "$1")"
          want=$answer
        else
          # say why, then ask again
          warn "$(t "%s can't be used:" "$answer")"
          tail -n 3 <<<"$refused" | sed 's/^/      /'
        fi
      done
    else
      spin "$(t 'Reserving %s in UniFi' "$suggestion")" bash "$scripts/providers/network/$np.sh" set-ip "$mac" "$suggestion" "$1"
      want=$suggestion
    fi
  else
    ok "$(t "%s is reserved for '%s' in UniFi" "$want" "$1")"
  fi

  if [ "$ip" != "$want" ]; then
    for try in 1 2 3 4 5; do
      spin "$(t "Restarting '%s' so it takes %s" "$1" "$want")$([ $try -eq 1 ] || t ' (try %s of 5)' "$try")" incus restart "$1"
      if bash -c "$wait_address" _ "$1" "$want" 15; then break; fi
      sleep 5      # give the router a moment before the next try
    done
    ip=$(address "$1")
    [ "$ip" = "$want" ] || fail "$(t "'%s' still has %s instead of %s after five restarts. Check the reservation in UniFi, then run the recipe again." "$1" "${ip:-$(_tr 'no address')}" "$want")"
  fi
  ok "$(t "'%s' has the fixed address %s" "$1" "$ip")"
}

# After an address change the router can take a moment to pass traffic for
# the new address; installing before that looks like a hang. If nothing gets
# through, one restart of the container usually settles it.
wait_internet() {   # wait_internet <name>
  step "$(t "Internet connection of '%s'" "$1")"
  local probe='for _ in $(seq 1 "$2"); do
    if incus exec "$1" -- sh -c "getent hosts deb.debian.org >/dev/null && timeout 5 bash -c \"exec 3<>/dev/tcp/deb.debian.org/80\"" </dev/null 2>/dev/null; then exit 0; fi
    sleep 3
  done
  exit 1'
  if SPIN_SOFT=1 spin "Waiting for the connection" bash -c "$probe" _ "$1" 15; then return; fi
  spin "$(t "Restarting '%s'" "$1")" incus restart "$1"
  spin "Waiting for the connection" bash -c "$probe" _ "$1" 45 ||
    fail "$(t "'%s' has no internet connection. Check its address and the UniFi firewall, then run the recipe again." "$1")"
}

# Pass the server's NVIDIA card into the container. Returns 1 (and leaves the
# container as it was) when there is none or it does not work.
# How: Incus' `nvidia.runtime` mounts the driver's libraries from the server
# into the container at every start, so they always match the driver. On NixOS
# that hook can't refresh the container's library list, so a small unit inside
# does it at every boot. (The other way, a CDI id like nvidia.com/gpu=0, fails
# here with "Failed to detect requested GPU device".)
nvidia_gpu() {   # nvidia_gpu <name>
  local pci
  pci=$(incus query /1.0/resources | jq -r '[.gpu.cards[] | select(.driver == "nvidia")][0].pci_address // empty')
  [ -n "$pci" ] || return 1
  incus config set "$1" nvidia.runtime=true nvidia.driver.capabilities=all
  incus config device add "$1" gpu gpu "pci=$pci" >/dev/null
  incus exec "$1" -- sh -c 'cat > /etc/systemd/system/hs-nvidia-libs.service <<UNIT
[Unit]
Description=Make the NVIDIA libraries of the server known (hs recipe)
DefaultDependencies=no
After=local-fs.target
Before=sysinit.target

[Service]
Type=oneshot
ExecStart=/sbin/ldconfig

[Install]
WantedBy=sysinit.target
UNIT
systemctl enable -q hs-nvidia-libs.service' </dev/null
  spin "$(t "Restarting '%s' with the NVIDIA card" "$1")" incus restart "$1"
  spin "Waiting for the container" bash -c "$wait_address" _ "$1" "" 30
  if incus exec "$1" -- sh -c 'test -e /dev/nvidia0 && ldconfig -p | grep -q libnvidia-encode' </dev/null 2>/dev/null; then
    return 0
  fi
  incus config device remove "$1" gpu >/dev/null 2>&1 || true
  incus config unset "$1" nvidia.runtime
  incus config unset "$1" nvidia.driver.capabilities
  incus exec "$1" -- sh -c 'systemctl disable -q hs-nvidia-libs.service; rm -f /etc/systemd/system/hs-nvidia-libs.service' </dev/null 2>/dev/null || true
  spin "$(t "Restarting '%s' without it" "$1")" incus restart "$1"
  spin "Waiting for the container" bash -c "$wait_address" _ "$1" "" 30
  return 1
}

# Let Docker inside the container use the NVIDIA card that nvidia_gpu passed in
# (docker run --gpus all, compose "driver: nvidia"). Returns 1 when it does not work.
# How: NVIDIA's container toolkit in CDI mode. Its classic mode asks /proc/driver/nvidia/gpus
# and the cgroup, neither exists in a container. CDI instead describes the devices and
# libraries Incus has put into the container; that description (/etc/cdi/nvidia.yaml) is
# written again at every boot by a unit, so it follows a driver update of the server.
nvidia_docker() {
  step "NVIDIA container toolkit for Docker"
  in_ct "Adding the NVIDIA package source" '
    curl -fsSL -m 60 https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL -m 60 https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list |
      sed "s#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g" > /etc/apt/sources.list.d/nvidia-container-toolkit.list
    $1 update -qq' "$apt_quick" || return 1
  in_ct "Installing the NVIDIA container toolkit" '$1 install -y -qq nvidia-container-toolkit' "$apt_quick" || return 1
  in_ct "Setting Docker up for the card" '
    cat > /etc/systemd/system/hs-nvidia-cdi.service <<UNIT
[Unit]
Description=Describe the NVIDIA card for Docker (hs recipe)
After=hs-nvidia-libs.service local-fs.target
Before=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

[Install]
WantedBy=multi-user.target
UNIT
    mkdir -p /etc/cdi
    systemctl daemon-reload
    systemctl enable -q hs-nvidia-cdi.service
    systemctl start hs-nvidia-cdi.service
    nvidia-ctk runtime configure --runtime=docker
    nvidia-ctk config --in-place --set nvidia-container-runtime.mode=cdi
    systemctl restart docker' || return 1
  in_ct "Testing the card inside Docker" '
    docker run --rm --gpus all debian:bookworm-slim sh -c "test -e /dev/nvidia0 && ldconfig -p | grep -q libcuda.so.1 && ldconfig -p | grep -q libnvidia-encode"' || return 1
}

# Docker from its own package source, inside the container.
install_docker() {
  step "Install Docker"
  if incus exec "$ct" -- sh -c 'docker compose version' >/dev/null 2>&1 </dev/null; then
    ok "installed already"
    return
  fi
  in_ct "Updating the package lists" '$1 update -qq' "$apt_quick"
  in_ct "Installing curl" '$1 install -y -qq curl ca-certificates gnupg' "$apt_quick"
  in_ct "Adding the Docker package source" '
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL -m 60 https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $VERSION_CODENAME stable" > /etc/apt/sources.list.d/docker.list
    $1 update -qq' "$apt_quick"
  in_ct "Installing Docker" '$1 install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin' "$apt_quick"
}

# apt that gives up on a dead connection after seconds, not minutes; for use inside a container
apt_quick='apt-get -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 -o Acquire::Retries=2 -o Acquire::ForceIPv4=true'

# ── Database dumps for the backup (the standard: scripts/lib/backup-dump.sh) ──
# A recipe with a database ends its setup with:
#   install_dump_tool [sqlite]                  # puts /usr/local/sbin/hs-dump into the container (sqlite: also the sqlite3 program)
#   backup_with_dump <name> "hs-dump postgres-compose ..."   # declares the dump and puts the container in the nightly backup
# Idempotent: run again, the tool is replaced and the dump command called <name> is replaced, not doubled.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/backup-dump.sh"

install_dump_tool() {   # install_dump_tool [sqlite]
  if [ "${1:-}" = sqlite ]; then
    in_ct "Installing the dump tool (sqlite3)" '$1 update -qq && $1 install -y -qq sqlite3' "$apt_quick"
  fi
  spin "Installing the dump command" incus file push -q --mode 0755 "$scripts/recipes/files/hs-dump" "$ct/usr/local/sbin/hs-dump"
}

declare_dump() {   # declare_dump <name> <command inside the container>
  dump_declare "${state}/backup-dump/$ct" "$1" "$2" 2>/dev/null || { warn "Could not write the backup dump command."; return 1; }
}

backup_with_dump() {   # backup_with_dump <name> <command inside the container, or "" for a container without a database>
  if [ -n "$2" ]; then declare_dump "$1" "$2" || return 0; fi
  bash "$scripts/backup.sh" ct "$ct" on >/dev/null 2>&1 || warn "$(t "Could not add '%s' to the backup. Later: hs backup ct %s on" "$ct" "$ct")"
}

# One line for the closing text of a recipe that points at its guide: the page in the web interface (the Docs page, capability docs)
# when it is on, else where the file is. A recipe's closing text holds only the few clicks that cannot wait; everything else belongs
# in the guide. $1: the page's slug (scripts/lib/docs-index.py).
docs_hint() {   # docs_hint <slug of the guide: a core guide (containers-and-apps) or the name of a package that has a guide.md (arr)>
  local host port
  if capability_on docs; then
    host=$(machine_get hostName 2>/dev/null || true); port=$(machine_get webPort 2>/dev/null || true)
    t 'Guide: http://%s.local:%s/docs/en/%s' "${host:-$(hostname)}" "${port:-8480}" "$1"
  else
    say "Guide: the file in docs/ of the repository (the web interface shows it as its Docs page: webUi = true)."
  fi
}

# ── The same frame for every recipe ──
# Every recipe opens with a heading that names it (the text before the first colon of its
# "# recipe:" line, in the server's language) and closes with the same few facts and a box:
#   recipe_facts [web]   the container, its address and the web page, as `kv` rows
#   box                  only the clicks that cannot wait, then $(docs_hint <guide slug>)
recipe_title() {
  local d=""
  [ "${hs_lang:-en}" = en ] || d=$(sed -n "s/^# recipe.$hs_lang: //p" "$0" 2>/dev/null | head -n1)
  [ -n "$d" ] || d=$(sed -n 's/^# recipe: //p' "$0" 2>/dev/null | head -n1)
  d=${d%%:*}
  echo "${d:-$ct}"
}
if [[ " $* " != *" --dry-run "* && " $* " != *" --refresh "* ]]; then step "$(t 'Recipe: %s' "$(recipe_title)")"; fi

# What the recipe says about the service it set up (docs/PLAN-modular-core.md step 4): a descriptor for `hs services`, from which the dashboard
# tile and the reverse-proxy route come. declare_service <name> <title> <icon> [exposure] [group] [description] [port]
#   exposure: private-ok (default), or never-public for an admin page (never asks about a public name).
#   SERVICE_STATS=<lines> (optional): the live numbers of the tile, see below
#   SERVICE_PUBLIC_NAME=<full name> (set by a recipe whose person typed a public host name): the service gets that fqdn, becomes public-ok
#   and wants the reverse proxy; the route is still made by `hs services apply` (typed host name on a public proxy). It overrides the questions.
#   SERVICE_NO_DASHBOARD=1: no dashboard question and no tile (the start page itself).
# Questions per provider that is set up (asked like the other preferences, remembered in recipe-<ct>.conf, --ask asks again):
# "show it on the dashboard?" (default yes), "make it public?" (default no) and, on yes, "public name?" (default <name>.<first proxyDomains>;
# RECIPE_PUBLIC_<KEY>, RECIPE_PUBLIC_NAME_<KEY> preset them). The answers go into the service's `want`;
# a service that exists keeps what a person set (exposure, names, wants); the facts the recipe knows (port, title, icon) are refreshed.
# What the service needs on a PUBLIC proxy is said BEFORE declare_service with these helpers (api level 2; a recipe that uses them sets
# requires_core = ">=2"); declare_service passes them on and forgets them, so a recipe with two services does not leak one into the other:
#   service_path public  /api/webhooks/trigger    may be public while the root stays private (a never-public service asks once,
#                                                 "make the public paths reachable from the internet?", default no)
#   service_path blocked /if/admin/               never reachable from the internet, even when the root is public
#   service_path open    /api                     skips the forward auth
#   service_auth authentik                        offers forward auth (a person switches it off: hs services edit <name> --auth none)
#   service_header request  X-Forwarded-Proto https         set on the request to the service
#   service_header response Access-Control-Expose-Headers User-Agent   set on the answer (headers are NOT secrets: the descriptor is 0644)
# Public paths, auth and exposure are offers (a person's choice stays); blocked paths, skips and headers are the recipe's facts, replaced each run.
_svc_public=(); _svc_blocked=(); _svc_open=(); _svc_auth=""; _svc_reqh=(); _svc_resh=()
service_path() {
  local kind=${1:-} p=${2:-}
  case "$kind" in public|blocked|open) ;; *) fail "$(t "service_path: '%s' is not public, blocked or open" "$kind")" ;; esac
  [[ "$p" =~ ^/[A-Za-z0-9._/-]*$ ]] && [[ "$p" != *..* ]] || fail "$(t "service_path: '%s' is not a path (it starts with / and has no ..)" "$p")"
  case "$kind" in
    public) _svc_public+=("$p") ;;
    blocked) _svc_blocked+=("$p") ;;
    open) _svc_open+=("$p") ;;
  esac
}
service_auth() {
  [ "${1:-}" = authentik ] || fail "$(t "service_auth: '%s' is not a known login (authentik)" "${1:-}")"
  _svc_auth=authentik
}
service_header() {
  local kind=${1:-} hname=${2:-} hval
  hval="${*:3}"
  case "$kind" in request|response) ;; *) fail "$(t "service_header: '%s' is not request or response" "$kind")" ;; esac
  [[ "$hname" =~ ^[A-Za-z0-9-]{1,64}$ ]] || fail "$(t "service_header: '%s' is not a header name" "$hname")"
  case "${hname,,}" in host|content-length|transfer-encoding|connection) fail "$(t "service_header: %s may not be set" "$hname")" ;; esac
  # printable ASCII only, 1 to 200 characters, no line break
  { local LC_ALL=C; [ -n "$hval" ] && [ "${#hval}" -le 200 ] && [[ "$hval" != *[!\ -~]* ]]; } || fail "$(t "service_header: the value of %s must be printable ASCII, 1 to 200 characters" "$hname")"
  if [ "$kind" = request ]; then _svc_reqh+=("$hname: $hval"); else _svc_resh+=("$hname: $hval"); fi
}
declare_service() {
  local name=$1 title=$2 icon=$3 exposure=${4:-private-ok} group=${5:-Apps} desc=${6:-} port=${7:-${PORT:-}} key var want="" out
  # take what the helpers collected and forget it at once, whichever way this function ends
  local s_public=("${_svc_public[@]+"${_svc_public[@]}"}") s_blocked=("${_svc_blocked[@]+"${_svc_blocked[@]}"}") s_open=("${_svc_open[@]+"${_svc_open[@]}"}")
  local s_reqh=("${_svc_reqh[@]+"${_svc_reqh[@]}"}") s_resh=("${_svc_resh[@]+"${_svc_resh[@]}"}") s_auth=$_svc_auth
  _svc_public=(); _svc_blocked=(); _svc_open=(); _svc_auth=""; _svc_reqh=(); _svc_resh=()
  [ -f "$scripts/services.sh" ] && [ -n "$port" ] || return 0
  # a container with a name of its own (hs recipe <name> --name <ct>) is a service of its own: the descriptor must not replace the first one's
  if [ -n "${RECIPE_NAME:-}" ] && [ "$ct" != "$name" ]; then name=$ct; title="$title ($ct)"; fi
  key=${name//-/_}; key=${key^^}
  step "Service"
  if [ "${SERVICE_NO_DASHBOARD:-}" != 1 ] && [ -n "$(setting_get dashboard 2>/dev/null || true)" ]; then
    setting "DASH_$key" "$(t "Show '%s' on the dashboard?" "$title")" yes yes 'yes|no'
    var=DASH_$key; [ "${!var}" != yes ] || want+=dashboard,
  fi
  local pub="" dom pvar nvar
  if [ -n "${SERVICE_PUBLIC_NAME:-}" ]; then
    pub=$SERVICE_PUBLIC_NAME
  elif { [ "$exposure" != never-public ] || [ "${#s_public[@]}" -gt 0 ]; } && [ -n "$(setting_get reverseProxy 2>/dev/null || true)" ]; then
    if [ "$exposure" = never-public ]; then   # an admin page: only its public paths would go on the internet
      setting "PUBLIC_$key" "$(t "Make the public paths of '%s' reachable from the internet (%s)?" "$title" "$(IFS=,; echo "${s_public[*]}")")" no no 'yes|no'
    else
      setting "PUBLIC_$key" "$(t "Make '%s' public?" "$title")" no no 'yes|no'
    fi
    pvar=PUBLIC_$key
    if [ "${!pvar}" = yes ]; then
      dom=$(setting_get proxyDomains 2>/dev/null | tr -d ' ' | cut -d, -f1 || true)
      setting "PUBLIC_NAME_$key" "$(t 'Public name?')" "${dom:+$name.$dom}" "${dom:+$name.$dom}" "$a_fqdn"
      nvar=PUBLIC_NAME_$key; pub=${!nvar}
      [[ "$pub" =~ ^($a_fqdn)$ ]] || { warn "$(t "'%s' stays private: there is no public name (hs config set proxyDomains, or RECIPE_PUBLIC_NAME_%s)" "$title" "$key")"; pub=""; }
    fi
  fi
  [ -z "$pub" ] || want+=reverse-proxy,
  # the gateway proxy (capability gateway) is private: its local name is wanted without a question, also for an admin page
  if capability_on gateway; then want+=local-proxy,; fi
  # SERVICE_STATS (optional, one stat per line, 'kind|label|path|pointer|reduce|where|secret|auth|unit|format'): a number on the tile;
  # a secret named stat-<service> holds the app's API key (hs services key <service>), it is never given here
  local stat_args=() sline
  while IFS= read -r sline; do
    [ -z "$sline" ] || stat_args+=(--stat "$sline")
  done <<<"${SERVICE_STATS:-}"
  # what the helpers collected, as declare options
  local px=() x
  for x in ${s_public[@]+"${s_public[@]}"}; do px+=(--public-path "$x"); done
  for x in ${s_blocked[@]+"${s_blocked[@]}"}; do px+=(--blocked-path "$x"); done
  for x in ${s_open[@]+"${s_open[@]}"}; do px+=(--auth-skip "$x"); done
  for x in ${s_reqh[@]+"${s_reqh[@]}"}; do px+=(--request-header "$x"); done
  for x in ${s_resh[@]+"${s_resh[@]}"}; do px+=(--response-header "$x"); done
  [ -z "$s_auth" ] || px+=(--auth "$s_auth")
  [ "$exposure" != never-public ] || px+=(--admin)
  # shellcheck disable=SC2086
  if out=$(bash "$scripts/services.sh" declare "$name" --container "$ct" --port "$port" --title "$title" --icon "$icon" --exposure "$exposure" \
        --group "$group" ${desc:+--description "$desc"} ${want:+--want "${want%,}"} ${pub:+--public-name "$pub"} \
        ${px[@]+"${px[@]}"} ${stat_args[@]+"${stat_args[@]}"} 2>&1); then
    ok "$(t "Service '%s' is %s (hs services list)" "$name" "$out")"
    note "$(t 'Next: hs services apply (a public name is decided there: exposure public-ok)')"
    if capability_on gateway; then
      SPIN_SOFT=1 spin "$(t 'Local name for %s' "$name")" bash "$scripts/services.sh" apply --proxy local --adds-only
      . "$scripts/lib/localdomain.sh"
      local ld
      ld=$(local_domain)
      [ -z "$ld" ] || note "$(t 'Local address: http://%s.%s' "$name" "$ld")"
    fi
  else
    warn "$(t "The service '%s' could not be described: %s" "$name" "$out")"
  fi
}

# ct_tailscale: Tailscale inside the container ($ct): the tun device (Incus gives containers /dev/net/tun itself; adding it on top fails),
# the package, and the sign-in (a link when a person is at a terminal, else the command to run). Sets $ts_ip (empty until signed in).
ct_tailscale() {
  step "Tailscale"
  if ! incus exec "$ct" -- test -c /dev/net/tun </dev/null 2>/dev/null; then
    spin "Adding the network device /dev/net/tun and restarting" bash -c 'incus config device add "$1" tun unix-char path=/dev/net/tun </dev/null && incus restart "$1" </dev/null' _ "$ct"
    wait_internet "$ct"
  fi
  if incus exec "$ct" -- sh -c 'command -v tailscale >/dev/null' </dev/null 2>/dev/null; then
    ok "installed already"
  else
    in_ct "Installing Tailscale" '
      $1 update -qq && $1 install -y -qq --no-install-recommends ca-certificates curl
      curl -fsSL https://tailscale.com/install.sh | sh' "$apt_quick"
  fi
  if incus exec "$ct" -- tailscale ip -4 </dev/null >/dev/null 2>&1; then
    ok "Signed in to Tailscale already"
  elif interactive; then
    note "Open the link below in a browser to sign the container in:"
    incus exec "$ct" -- tailscale up --hostname="$ct" --accept-dns=false ||
      warn "$(t 'Sign-in did not finish. Run: incus exec %s -- tailscale up --hostname=%s --accept-dns=false' "$ct" "$ct")"
  else
    note "$(t 'Sign it in with: incus exec %s -- tailscale up --hostname=%s --accept-dns=false' "$ct" "$ct")"
  fi
  ts_ip=$(incus exec "$ct" -- tailscale ip -4 </dev/null 2>/dev/null | head -n1 || true)
}

# internal_link: a second network card (device $HS_LINK_DEVICE, $HS_LINK_NIC) on the Incus network of the internal link (capabilities/incus/NOTES.md)
# with the fixed address $link_peer and no default route. Sets $link_url (http://<host address>:<gatewayTunnelPort>, empty while the tunnel port is
# off) and $link_host/$link_peer. Returns 1 (and says why) when the server has no internal link (incus off, or hs rebuild not run yet).
internal_link() {
  local name subnet tun from etc=${HS_ETC_DIR:-/etc/hs} hits line
  link_url=""; link_host=$(link_get host); link_peer=$(link_get peer); name=$(link_get name); subnet=$(link_get subnet)
  step "Internal link"
  if [ -z "$name" ] || [ -z "$link_peer" ]; then warn "This server has no internal link yet: run sudo hs rebuild, then this recipe again."; return 1; fi
  incus network show "$name" >/dev/null 2>&1 </dev/null || { warn "$(t 'The Incus network %s is missing: run sudo hs rebuild, then this recipe again.' "$name")"; return 1; }
  if hits=$(link_overlaps "$subnet"); then
    while IFS= read -r line; do note "$line"; done <<<"$hits"
    fail "$(t 'The internal link (%s) overlaps a network of this server; set incusInternalSubnet in machine.toml and rebuild.' "$subnet")"
  fi
  if [ "$(incus config device get "$ct" "$HS_LINK_DEVICE" network 2>/dev/null </dev/null || true)" != "$name" ]; then
    spin "Adding a network card on the internal link" incus config device add "$ct" "$HS_LINK_DEVICE" nic network="$name" name="$HS_LINK_NIC"
  fi
  if incus exec "$ct" -- systemctl is-enabled -q systemd-networkd </dev/null 2>/dev/null; then
    ensure_file /etc/systemd/network/10-$HS_LINK_DEVICE.network "the network file of the internal link" <<NET
[Match]
Name=$HS_LINK_NIC

[Link]
RequiredForOnline=no

[Network]
Address=$link_peer/29
LinkLocalAddressing=no
IPv6AcceptRA=no
ConfigureWithoutCarrier=yes
NET
    in_ct "Applying the address" 'networkctl reload && networkctl reconfigure "$1"' "$HS_LINK_NIC"
  elif incus exec "$ct" -- grep -qs '^source /etc/network/interfaces.d' /etc/network/interfaces </dev/null; then
    ensure_file /etc/network/interfaces.d/$HS_LINK_DEVICE "the network file of the internal link" <<NET
auto $HS_LINK_NIC
iface $HS_LINK_NIC inet static
    address $link_peer/29
NET
    in_ct "Applying the address" 'ifdown "$1" 2>/dev/null || true; ifup "$1"' "$HS_LINK_NIC"
  else
    fail "$(t "'%s' uses neither systemd-networkd nor ifupdown: give %s the address %s/29 by hand, without a gateway." "$ct" "$HS_LINK_NIC" "$link_peer")"
  fi
  spin "Waiting for the address on the link" bash -c 'for _ in $(seq 1 10); do incus exec "$1" -- ip -4 -o addr show dev "$3" </dev/null | grep -q " $2/" && exit 0; sleep 1; done; exit 1' _ "$ct" "$link_peer" "$HS_LINK_NIC" ||
    fail "$(t "'%s' did not take %s on %s. Look at: incus exec %s -- ip addr show %s" "$ct" "$link_peer" "$HS_LINK_NIC" "$ct" "$HS_LINK_NIC")"
  if incus exec "$ct" -- ip -4 route show default </dev/null | grep -q "dev $HS_LINK_NIC"; then
    fail "$(t "'%s' has a default route on the internal link; remove it (a network file inside that matches %s)." "$ct" "$HS_LINK_NIC")"
  fi
  ok "$(t "'%s' has %s on the internal link (the server is %s)" "$ct" "$link_peer" "$link_host")"
  tun=$(sed -n 's/^tunnel=//p' "$etc/gateway-public" 2>/dev/null | head -n 1 || true)
  [ -n "$tun" ] && [ "$tun" != 0 ] || return 0
  link_url="http://$link_host:$tun"
  from=" $(cat "$etc/gateway-tunnel-from" 2>/dev/null || true) "; from=${from//$'\n'/ }
  if [[ "$from" == *" $link_peer/32 "* || "$from" == *" $link_peer "* ]]; then
    SPIN_SOFT=1 spin "Checking the tunnel port over the link" incus exec "$ct" -- timeout 5 bash -c "exec 3<>/dev/tcp/$link_host/$tun" ||
      warn "$(t 'The gateway does not answer on %s yet (is Traefik running? hs gateway status).' "$link_url")"
  else
    warn "$(t 'gatewayTunnelFrom does not name %s/32, so the server refuses the link. Remove the gatewayTunnelFrom line in /etc/nixos/machine.toml (or add the address), then sudo hs rebuild.' "$link_peer")"
  fi
}

# wait_page <title> <what to look at when it does not answer, run as: incus exec <ct> -- ...> [options]
# Waits until the web page of the container answers at $(web) and fails with where to look. Without options: any HTTP answer counts, a
# refused connection does not, for up to 4 minutes (120 tries, 2 seconds apart).
#   --path <p>      ask <p> instead of /            --url <base>   another base than $(web)
#   --ok            the answer must be a success (HTTP < 400)         --status <n>   the answer must be exactly this status
#   --match <text>  the answer must be a success and its body must contain <text>
#   --tries <n> --every <seconds>   how long to wait          --plain   the shorter text (no "the first start prepares its files")
# RECIPE_WAIT_TRIES overrides --tries (for the tests).
wait_page() {
  local title=$1 hint=$2 base path=/ mode=any want="" tries=120 every=2 plain=false
  shift 2
  base=$(web)
  while [ $# -gt 0 ]; do
    case "$1" in
      --path) path=$2; shift 2 ;;
      --url) base=$2; shift 2 ;;
      --ok) mode=ok; shift ;;
      --status) mode=status; want=$2; shift 2 ;;
      --match) mode=match; want=$2; shift 2 ;;
      --tries) tries=$2; shift 2 ;;
      --every) every=$2; shift 2 ;;
      --plain) plain=true; shift ;;
      *) fail "wait_page: unknown option $1" ;;
    esac
  done
  tries=${RECIPE_WAIT_TRIES:-$tries}
  local label
  if $plain; then label=$(t 'Waiting for %s to answer' "$title"); else label=$(t 'Waiting for %s to answer (the first start prepares its files)' "$title"); fi
  spin "$label" bash -c '
    url=$1; tries=$2; every=$3; mode=$4; want=$5
    for _ in $(seq 1 "$tries"); do
      case $mode in
        any)    [ "$(curl -s -m 3 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)" != 000 ] && exit 0 ;;
        ok)     curl -fsS -m 3 -o /dev/null "$url" 2>/dev/null && exit 0 ;;
        match)  curl -fsS -m 3 "$url" 2>/dev/null | grep -q -- "$want" && exit 0 ;;
        status) [ "$(curl -s -m 3 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)" = "$want" ] && exit 0 ;;
      esac
      sleep "$every"
    done
    exit 1' _ "${base%/}$path" "$tries" "$every" "$mode" "$want" ||
    fail "$(t '%s does not answer at %s. Look at: incus exec %s -- %s' "$title" "$base" "$ct" "$hint")"
}

recipe_facts() {   # recipe_facts [web]: "web" adds the address of the web page
  step "Summary"
  kv "Container" "$ct"
  kv "Address" "${ip:-?}"
  [ "${1:-}" != web ] || kv "Web page" "$(web)"
}

# ── Pieces: do only what changed (docs/PLAN-packages.md, "Smart updates") ──
# A piece is one thing a recipe puts on the server: a downloaded release, an image tag, a generated config. The recipe names the
# version it WANTS (a pin, never "latest") and the piece is skipped when the stamp of the last run says the same. Stamps live in
# $state/recipe-<ct>.stamps (key=value lines). `hs recipe <name> --check` runs only the questions "is it current?": it prints one
# line per piece and changes nothing; end such a recipe with `check_done`.
#   piece <key> <wanted> <label>       0 = current (skip it), 1 = would update; in --check mode also prints the line
#   piece_done <key> <wanted>          remember it after a successful install
#   fetch_pinned <key> <url> <sha256> <dest> [version]   download unless current, verify the checksum, remember (host side; sha256 "-" = unchecked)
#   ensure_file <path-in-ct> <label>   reads the new content on stdin; writes it into the container only when it differs (keeps a copy of
#                                      a hand-edited file: <path>.before-recipe once)
#   check_done                         in --check mode: exit 0 (all current) or 1 (something would update); otherwise nothing
CHECK=false
for a in "$@"; do [ "$a" != --check ] || CHECK=true; done
CHECK_STALE=false
stamps="$state/recipe-$ct.stamps"
stamp_get() { sed -n "s/^$1=//p" "$stamps" 2>/dev/null | tail -n1 || true; }
stamp_set() {
  mkdir -p "$(dirname "$stamps")"
  { grep -v "^$1=" "$stamps" 2>/dev/null || true; echo "$1=$2"; } > "$stamps.new"
  mv "$stamps.new" "$stamps"
}
piece() {   # piece <key> <wanted> <label>
  local have; have=$(stamp_get "$1")
  if [ "$have" = "$2" ]; then
    ! $CHECK || say "current        $3 ($2)"
    return 0
  fi
  CHECK_STALE=true
  ! $CHECK || say "would update   $3 (${have:--} -> $2)"
  return 1
}
piece_done() { stamp_set "$1" "$2"; }
fetch_pinned() {   # fetch_pinned <key> <url> <sha256> <dest> [version]
  local key=$1 url=$2 sum=$3 dest=$4 want=${5:-$3}
  if piece "$key" "$want" "$key" && [ -e "$dest" ]; then ok "$(t '%s is current (%s)' "$key" "$want")"; return 0; fi
  ! $CHECK || return 0
  spin "$(t 'Downloading %s %s' "$key" "$want")" curl -fsSL -o "$dest.new" "$url"
  if [ "$sum" != - ] && [ "$(sha256sum "$dest.new" | cut -d' ' -f1)" != "$sum" ]; then
    rm -f "$dest.new"; fail "$(t 'The checksum of %s does not match the pin; nothing was installed' "$key")"
  fi
  mv "$dest.new" "$dest"
  piece_done "$key" "$want"
}
ensure_file() {   # ensure_file <path in the container> <label>: new content on stdin
  local path=$1 label=$2 new cur
  new=$(cat)
  cur=$(incus exec "$ct" -- cat "$path" 2>/dev/null </dev/null || true)
  if [ "$cur" = "$new" ]; then ! $CHECK || say "current        $label"; return 0; fi
  CHECK_STALE=true
  ! $CHECK || { say "would update   $label"; return 0; }
  if [ -n "$cur" ] && ! incus exec "$ct" -- test -e "$path.before-recipe" </dev/null; then
    incus exec "$ct" -- cp "$path" "$path.before-recipe" </dev/null
    note "$(t 'Your previous %s is kept as %s.before-recipe' "$label" "$path")"
  fi
  printf '%s\n' "$new" | incus exec "$ct" -- tee "$path" >/dev/null
  ok "$(t '%s written' "$label")"
}
check_done() { if $CHECK; then ! $CHECK_STALE; exit; fi; }
