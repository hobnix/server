#!/usr/bin/env bash
# help: create and edit containers/VMs and their storage (fast volumes, bulk shares) in a full-screen interface
# help.de: Container/VMs und ihren Speicher (fast-Volumes, bulk-Freigaben) anlegen und ändern, in einer Vollbild-Oberfläche
# args: [--plain]
set -euo pipefail

# Everything the interface (the web interface, Instances) does goes through this script:
#   --list                                   instances, tab separated (name, type, state, address, ram, cpu, autostart, mac pinned, docker, disk,
#                                            snapshots, last snapshot, memory in use, cpu time, bindings, last start (UTC))
#   <name> --storage                         disk devices of an instance, tab separated
#   --create <name> [--vm] [--docker] [--ram MB] [--cpu N] [--disk GB] [--ip <address>] [--profile <vlan>]
#   --profiles                               network profiles to create on: name, network or bridge, description
#   <name> --users                           users that run services inside: name, uid, gid, commands
#   <name> --add-storage <fast|shares|sensitive> <storage-name> <path> [--readonly] [--as <uid>:<gid>]
#   <name> --snapshots                       snapshots: name, date
#   <name> --snapshot [label] | --restore <snapshot> | --delete-snapshot <snapshot>
#   <name> --update                          snapshot, then update the software inside
#   <name> --remove-storage <device>
#   <name> --set key=value ...               ram, cpu, disk (number or "none"), autostart, docker (yes/no),
#                                            ip (fixed address, reserved in UniFi: hs net setup)
#   <name> --start | --stop | --restart | --delete
# Add --dry-run to any change to print the commands instead of running them; --yes skips the typed name of --delete (jobs).

here=$(dirname "$0")
. "$here/lib/ui.sh"
usage() {
  say "usage: hs ct list [--plain]"
  say "       (the options used by the interface are listed at the top of scripts/manage-ct.sh)"
  exit 1
}

dry=false
plain=false
yes=false
args=()
for a in "$@"; do
  case "$a" in
    --dry-run) dry=true ;;
    --plain)   plain=true ;;
    --yes)     yes=true ;;   # a background job asks nothing (the interface checked the typed name)
    *)         args+=("$a") ;;
  esac
done
set -- "${args[@]}"

# run a command, or only print it with --dry-run
run() {
  if $dry; then
    printf '  %s' "$1"; printf ' %q' "${@:2}"; echo
  else
    "$@"
  fi
}

# Reserve a fixed address for an instance in UniFi and restart it so it takes it.
# In a dry run the instance may not exist yet; the checks (address free, outside
# the DHCP range) still run, against a placeholder MAC.
fix_ip() {   # fix_ip <instance> <ip>
  local mac=""
  mac=$(incus query "/1.0/instances/$1" 2>/dev/null | jq -r '.expanded_devices.eth0.hwaddr // empty' || true)
  if $dry; then
    bash "$here/unifi.sh" set-ip "${mac:-00:00:00:00:00:00}" "$2" "$1" --dry-run
    echo "  incus restart $1"
    return
  fi
  [ -n "$mac" ] || fail_fix "$(t "'%s' has no pinned MAC yet, can't reserve an address." "$1")" "hs mac $1"
  bash "$here/unifi.sh" set-ip "$mac" "$2" "$1"
  incus restart "$1"
}

valid_name() { [[ "$1" =~ ^[a-z][a-z0-9-]*$ ]] || fail "$(t "invalid name '%s' (lowercase letters, digits, -)" "$1")"; }
number()     { [[ "$2" =~ ^[0-9]+$ ]] || fail "$(t "%s must be a number, got '%s'" "$1" "$2")"; }

list() {
  incus list -f json | jq -r '.[] | [
    .name,
    (if .type == "virtual-machine" then "vm" else "ct" end),
    .status,
    ((.state.network // {}) | (.eth0 // .enp5s0 // {}) | (.addresses // [])
       | map(select(.family == "inet")) | .[0].address // "-"),
    (.config["limits.memory"] // "-"),
    (.config["limits.cpu"] // "-"),
    (.config["boot.autostart"] // "false"),
    ((.expanded_devices.eth0.hwaddr // "") | if . == "" then "no" else "yes" end),
    (.config["security.nesting"] // "false"),
    (.expanded_devices.root.size // "-"),
    ((.snapshots // []) | length),
    ((.snapshots // []) | last | .created_at // "-" | .[0:10]),
    (.state.memory.usage // 0),
    (.state.cpu.usage // 0),
    ([.expanded_devices | to_entries[] | select(.value.type == "disk" and (.value.path // "") != "/")] | length),
    ((.last_used_at // "") | if . == "" or startswith("0001") then "-" else .[0:19] | sub("T"; " ") end)
  ] | @tsv'
}

# Users with running processes inside, without root and the system's own daemons:
# these are the candidates for "which user of the app should be able to write".
users() {
  incus exec "$1" -- ps -eo user:32,uid,gid,comm --no-headers 2>/dev/null |
    awk '$2 != 0 && $1 !~ /^(systemd-|messagebus|polkitd|_apt|nobody|syslog|sshd|Debian-exim|postfix|chrony|_chrony|ntp)/ {
           key = $1 "\t" $2 "\t" $3
           if (!(key in seen)) { seen[key] = $4; order[++n] = key }
           else if (index(seen[key], $4) == 0) seen[key] = seen[key] ", " $4
         }
         END { for (i = 1; i <= n; i++) print order[i] "\t" seen[order[i]] }'
}

storage() {
  incus query "/1.0/instances/$1" | jq -r '.expanded_devices | to_entries[]
    | select(.value.type == "disk" and .value.path != "/")
    | [ .key,
        (if (.value.pool // "") != "" then "fast"
         elif (.value.source // "" | startswith("/bulk/shares/")) then "shares"
         elif (.value.source // "" | startswith("/bulk/sensitive/")) then "sensitive"
         else "other" end),
        (if (.value.pool // "") != "" then "volume " + .value.source else .value.source end),
        .value.path,
        (if .value.readonly == "true" then "read" else "write" end)
      ] | @tsv' |
    # last column: upload cache of the share (on, off, emptying), "-" where there is none.
    # Shown only; it is switched per share in hs share <share> perm.
    while IFS=$'\t' read -r dev kind source path access; do
      cache=-
      case "$kind" in
        shares|sensitive)
          cache=$(bash "$here/share-cache.sh" --state "$source" 2>/dev/null | cut -f1 || true)
          [ "${cache:-unsupported}" != unsupported ] || cache=- ;;
      esac
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$dev" "$kind" "$source" "$path" "$access" "$cache"
    done
}

if [ $# -eq 0 ] || [ "$1" = --list ]; then
  if $plain || [ $# -eq 0 ]; then
    # without the last two columns (memory in use, CPU time), which only the interface reads
    { thead 'Name' 'Type' 'State' 'IPv4' 'RAM' 'CPU' 'Autostart' 'MAC pinned' 'Docker' 'Disk' 'Snapshots' 'Last'; list | cut -f1-12; } | table
  else
    list
  fi
  exit 0
fi


# ── network profiles an instance can be created on (the interface's create dialog): name, network or bridge, description ──
if [ "$1" = --profiles ]; then
  incus profile list -f json | jq -r '.[] | (.devices // {}) as $d | ([$d[] | select(.type == "nic")] | first) as $nic | select($nic != null)
    | [.name, ($nic.network // $nic.parent // "-"), ((.description // "-") | gsub("[\t\n]"; " "))] | @tsv'
  exit 0
fi

# ── create ──
if [ "$1" = --create ]; then
  [ $# -ge 2 ] || usage
  name="$2"; shift 2
  valid_name "$name"
  vm=false; docker=false; ram=""; cpu=""; disk=""; ip=""; profile=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --vm)     vm=true; shift ;;
      --docker) docker=true; shift ;;
      --ram)    number RAM "$2"; ram="$2"; shift 2 ;;
      --cpu)    number CPU "$2"; cpu="$2"; shift 2 ;;
      --disk)   number Disk "$2"; disk="$2"; shift 2 ;;
      --ip)     ip="$2"; shift 2 ;;
      --profile) profile="$2"; shift 2 ;;      # the profile of another VLAN than the default one
      *) usage ;;
    esac
  done
  if incus info "$name" >/dev/null 2>&1; then fail "$(t "'%s' already exists." "$name")"; fi

  opts=(-c boot.autostart=true)
  if $vm; then
    # a VM gets its memory and disk reserved, so it needs explicit sizes
    opts+=(--vm)
    ram=${ram:-2048}; cpu=${cpu:-2}; disk=${disk:-20}
    $docker && note "Docker runs in a VM without extra settings."
  elif $docker; then
    opts+=(-c security.nesting=true -c security.syscalls.intercept.mknod=true -c security.syscalls.intercept.setxattr=true)
  fi
  [ -z "$ram" ]  || opts+=(-c "limits.memory=${ram}MiB")
  [ -z "$cpu" ]  || opts+=(-c "limits.cpu=$cpu")
  if [ -n "$profile" ]; then
    incus profile show "$profile" >/dev/null 2>&1 || fail "$(t "There is no network (profile) called '%s'. Known: %s" "$profile" "$(incus profile list -f csv -c n | tr '\n' ' ')")"
    opts+=(--profile "$profile")
  fi

  # fail on a taken or unsuitable address before anything is created
  if [ -n "$ip" ] && ! $dry; then
    bash "$here/unifi.sh" set-ip 00:00:00:00:00:00 "$ip" "$name" --dry-run >/dev/null
  fi
  # Created first, started last: the disk size has to be set before the first
  # start (a VM formats its disk then; the root disk comes from the profile,
  # so it is overridden for this instance), and the MAC of a VM can only be
  # pinned while it is stopped.
  run incus init images:debian/13 "$name" "${opts[@]}"
  [ -z "$disk" ] || run incus config device override "$name" root "size=${disk}GiB"
  run bash "$here/mac.sh" "$name"
  run incus start "$name"
  if [ -n "$ip" ]; then
    fix_ip "$name" "$ip"
  else
    $dry || { ok "$(t "'%s' is created and running." "$name")"
              next_step "$(t "give it a fixed IP (hs ct %s ip, or by hand in UniFi), then restart '%s'." "$name" "$name")"; }
  fi
  exit 0
fi

# ── everything else works on one existing instance ──
ct="$1"; shift
[ $# -ge 1 ] || usage
incus info "$ct" >/dev/null 2>&1 || fail_fix "$(t "'%s' does not exist." "$ct")" "hs ct list"
is_vm=false
[ "$(incus query "/1.0/instances/$ct" | jq -r .type)" = virtual-machine ] && is_vm=true

case "$1" in
  --storage)
    storage "$ct" ;;

  --users)
    users "$ct" ;;

  --snapshots)
    incus query "/1.0/instances/$ct/snapshots?recursion=1" |
      jq -r '.[] | [ (.name | sub(".*/"; "")), (.created_at | .[0:16] | sub("T"; " ")) ] | @tsv' ;;

  --snapshot)
    label="${2:-manual-$(date +%Y%m%d-%H%M)}"
    run incus snapshot create "$ct" "$label" ;;

  --restore)
    [ $# -ge 2 ] || usage
    # ZFS can only go back to the newest snapshot: newer ones have to go first
    newer=$(incus query "/1.0/instances/$ct/snapshots?recursion=1" |
      jq -r --arg t "$2" '[.[] | .name | sub(".*/"; "")] | (index($t)) as $i
        | if $i == null then error("no snapshot " + $t) else .[$i + 1:][] end') ||
      fail "$(t "'%s' has no snapshot called '%s'." "$ct" "$2")"
    for n in $newer; do
      $dry && echo "  (newer snapshot, must be deleted to go back further:)"
      run incus snapshot delete "$ct" "$n"
    done
    run incus snapshot restore "$ct" "$2"
    $dry || ok "$(t "'%s' is back at '%s'. Attached storage (shares, volumes) is not part of a snapshot." "$ct" "$2")" ;;

  --delete-snapshot)
    [ $# -ge 2 ] || usage
    run incus snapshot delete "$ct" "$2" ;;

  --update)
    label="before-update-$(date +%Y%m%d-%H%M)"
    run incus snapshot create "$ct" "$label"
    # a container with its own `update` command uses it; otherwise update the system packages
    if incus exec "$ct" -- sh -c 'command -v update' >/dev/null 2>&1; then
      run incus exec "$ct" -- update
    else
      run incus exec "$ct" -- sh -c 'apt-get update && apt-get -y full-upgrade'
    fi
    $dry || note "$(t "If something broke: restore the snapshot '%s'." "$label")" ;;

  --add-storage)
    [ $# -ge 4 ] || usage
    kind="$2"; sname="$3"; path="$4"; readonly=false; as=""
    shift 4
    while [ $# -gt 0 ]; do
      case "$1" in
        --readonly) readonly=true; shift ;;
        --as)       [ $# -ge 2 ] || usage; as="$2"; shift 2 ;;
        *) usage ;;
      esac
    done
    [ -z "$as" ] || [[ "$as" =~ ^[0-9]+:[0-9]+$ ]] || fail "$(t "--as expects <uid>:<gid>, got '%s'" "$as")"
    [[ "$sname" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "$(t "invalid storage name '%s'" "$sname")"
    [[ "$path" == /* ]] || fail "$(t "the path in the container must start with / (got '%s')" "$path")"
    if incus config device get "$ct" "$sname" type >/dev/null 2>&1; then
      fail "$(t "'%s' already has a device called '%s'." "$ct" "$sname")"
    fi
    case "$kind" in
      fast)
        # a volume on the SSD pool: survives the instance, can be snapshotted on its own
        incus storage volume show default "$sname" >/dev/null 2>&1 || run incus storage volume create default "$sname"
        run incus storage volume attach default "$sname" "$ct" "$sname" "$path"
        ;;
      shares|sensitive)
        if $is_vm; then
          fail "Bulk folders can't be passed into a VM this way. Mount the Samba share inside the VM instead."
        fi
        share_args=("$sname")
        [ "$kind" = sensitive ] && share_args+=(--sensitive)
        share_args+=(--ct "$ct" "$path")
        [ -z "$as" ] || share_args+=(--as "$as")
        before=$(incus config get "$ct" raw.idmap)
        run bash "$here/create-share.sh" "${share_args[@]}"
        # a changed user mapping only takes effect after a restart
        if $dry; then
          [ -z "$as" ] || echo "  incus restart $ct        (if the user mapping changed)"
        elif [ "$before" != "$(incus config get "$ct" raw.idmap)" ]; then
          incus restart "$ct"
        fi
        ;;
      *) fail "$(t "unknown kind '%s' (fast, shares, sensitive)" "$kind")" ;;
    esac
    $readonly && run incus config device set "$ct" "$sname" readonly=true
    exit 0 ;;

  --remove-storage)
    [ $# -ge 2 ] || usage
    run incus config device remove "$ct" "$2"
    $dry || ok "Detached. The data itself was not deleted."
    ;;

  --set)
    shift
    [ $# -ge 1 ] || usage
    for kv in "$@"; do
      key=${kv%%=*}; val=${kv#*=}
      case "$key" in
        ram)
          if [ "$val" = none ]; then run incus config unset "$ct" limits.memory
          else number RAM "$val"; run incus config set "$ct" "limits.memory=${val}MiB"; fi ;;
        cpu)
          if [ "$val" = none ]; then run incus config unset "$ct" limits.cpu
          else number CPU "$val"; run incus config set "$ct" "limits.cpu=$val"; fi ;;
        disk)
          number Disk "$val"
          if incus config device get "$ct" root size >/dev/null 2>&1 && [ -n "$(incus config device show "$ct" | grep -A0 '^root:' || true)" ]; then
            run incus config device set "$ct" root "size=${val}GiB"
          else
            run incus config device override "$ct" root "size=${val}GiB"
          fi ;;
        ip)
          fix_ip "$ct" "$val" ;;
        autostart)
          run incus config set "$ct" "boot.autostart=$([ "$val" = yes ] && echo true || echo false)" ;;
        docker)
          if $is_vm; then note "A VM needs no Docker setting."; continue; fi
          for k in security.nesting security.syscalls.intercept.mknod security.syscalls.intercept.setxattr; do
            if [ "$val" = yes ]; then run incus config set "$ct" "$k=true"; else run incus config unset "$ct" "$k"; fi
          done
          $dry || note "$(t "Restart '%s' for the Docker setting to take effect." "$ct")" ;;
        *) fail "$(t "unknown setting '%s'" "$key")" ;;
      esac
    done ;;

  --start)   run incus start "$ct" ;;
  --stop)    run incus stop "$ct" ;;
  --restart) run incus restart "$ct" ;;

  --delete)
    if $dry; then
      echo "Delete '$ct' with all its snapshots. Attached storage stays:"
      storage "$ct" | awk -F'\t' '{ printf "  %s -> %s\n", $3, $4 }'
      echo "  incus delete -f $ct"; exit 0
    fi
    warn "$(t "Delete '%s' with all its snapshots. Attached storage stays:" "$ct")"
    while IFS=$'\t' read -r _ _ src dpath _; do note "$src -> $dpath"; done < <(storage "$ct")
    if ! $yes; then
      danger "$(t "'%s' and its snapshots are deleted for good." "$ct")"
      confirm_name "$ct" "the instance" || fail "cancelled"
    fi
    mac=$(incus query "/1.0/instances/$ct" | jq -r '.expanded_devices.eth0.hwaddr // empty')
    incus delete -f "$ct"
    # give its address back, if UniFi is connected
    if [ -n "$mac" ] && [ -r /var/lib/hs/unifi ]; then bash "$here/unifi.sh" clear-ip "$mac" || true
    elif [ -L /var/lib/hs/unifi ]; then warn "The vault is closed: run hs unlock"; note "The fixed IP in UniFi was not given back; remove it in UniFi by hand"; fi
    ok "Deleted. Remove its fixed IP in UniFi and any Zoraxy rule that pointed to it."
    ;;

  *) usage ;;
esac
