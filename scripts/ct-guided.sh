#!/usr/bin/env bash
# help: guided dialogues for containers and VMs: add, edit, snapshots, storage, fixed address
# help.de: geführte Dialoge für Container und VMs: anlegen, ändern, Schnappschüsse, Speicher, feste Adresse
# args: add | edit <ct> | snapshot <ct> [label] | storage <ct> | ip <ct> [address]
# Every dialogue runs bare and asks for what is missing; every answer can also be given as an option
# (tests, scripts). The work is done by manage-ct.sh. Stand-ins for tests: HS_MANAGE_CT, HS_MANAGE_SHARES,
# HS_NET_IP, HS_INCUS.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
mct=${HS_MANAGE_CT:-$here/manage-ct.sh}
msh=${HS_MANAGE_SHARES:-$here/manage-shares.sh}
nip=${HS_NET_IP:-$here/net-ip.sh}
incus=${HS_INCUS:-incus}

usage() {
  say "usage: hs ct add [--kind empty|docker|vm] [--name <n>] [--ram MB] [--cpu N] [--disk GB] [--ip <address>] [--profile <vlan>] [--yes]"
  say "       hs ct <ct> edit [--ram MB|none] [--cpu N|none] [--disk GB] [--autostart yes|no] [--docker yes|no] [--yes]"
  say "       hs ct <ct> snapshot [label]            (without a label: a menu)"
  say "       hs ct <ct> storage [--kind fast|shares|sensitive] [--source <share>] [--name <n>] [--path </x>] [--readonly] [--as uid:gid] [--yes]"
  say "       hs ct <ct> ip [<address>]"
  exit 1
}

interactive() { [ -t 0 ] && [ -t 1 ] && [ -z "${HS_CALLER:-}" ] || [ -n "${HS_GUIDED_TTY:-}" ]; }
need() {   # need <what>: a value was not given and there is nobody to ask
  interactive || fail "$(t 'Missing: %s (give it as an option)' "$1")"
}
ct_exists() { "$incus" info "$1" >/dev/null 2>&1 || fail_fix "$(t "No instance called '%s'." "$1")" "hs ct list"; }
run_plan() {   # run_plan <yes> <command...>: show it, confirm, run
  local yes=$1; shift
  note "$ $*"
  if [ "$yes" != true ]; then interactive || fail "Nothing is changed without --yes when there is no terminal."; confirm "Do it?" || fail "cancelled"; fi
  "$@"
}

verb=${1:-}; [ $# -eq 0 ] || shift
case "$verb" in
# ───────────────────────────────────────────────────────────────────────────── add
add)
  kind=""; name=""; ram=""; cpu=""; disk=""; ip=""; profile=""; yes=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind) kind=$2; shift 2 ;; --name) name=$2; shift 2 ;; --ram) ram=$2; shift 2 ;; --cpu) cpu=$2; shift 2 ;;
      --disk) disk=$2; shift 2 ;; --ip) ip=$2; shift 2 ;; --profile) profile=$2; shift 2 ;; --yes) yes=true; shift ;;
      --docker) kind=docker; shift ;; --vm) kind=vm; shift ;;          # the old manage-ct form
      -*) usage ;;
      *) name=$1; shift ;;                                              # hs ct add <name> ...
    esac
  done
  # a name given on the command line is a decision: do not ask the rest, use the defaults
  [ -z "$name" ] || [ -n "$kind" ] || kind=empty
  if [ -z "$kind" ]; then
    need "--kind"
    kind=$(choose "What kind of instance?" "empty (Debian container)" "docker (container for Docker)" "vm (virtual machine)") || exit 1
    kind=${kind%% *}
  fi
  case "$kind" in empty|docker|vm) ;; *) usage ;; esac
  if [ -z "$name" ]; then need "--name"; name=$(ask "Name of the instance (lowercase letters, digits, dashes):" ""); fi
  [[ "$name" =~ ^[a-z][a-z0-9-]*$ ]] || fail "$(t "'%s' is not a good name: lowercase letters, digits and dashes, starting with a letter." "$name")"
  "$incus" info "$name" >/dev/null 2>&1 && fail "$(t "'%s' exists already." "$name")"
  def_ram=1024; [ "$kind" = vm ] && def_ram=2048
  if [ -z "$ram" ]; then if interactive; then ram=$(ask "Memory in MB:" "$def_ram"); else ram=$def_ram; fi; fi
  if [ -z "$cpu" ] && interactive; then cpu=$(ask "CPU cores (empty = no limit):" ""); fi
  if [ -z "$disk" ] && interactive; then disk=$(ask "Disk size in GB (empty = default):" ""); fi
  if [ -z "$ip" ] && interactive; then ip=$(ask "Fixed address (empty = later):" ""); fi
  args=(--create "$name" --ram "$ram")
  [ "$kind" = docker ] && args+=(--docker)
  [ "$kind" = vm ] && args+=(--vm)
  [ -z "$cpu" ] || args+=(--cpu "$cpu")
  [ -z "$disk" ] || args+=(--disk "$disk")
  [ -z "$ip" ] || args+=(--ip "$ip")
  [ -z "$profile" ] || args+=(--profile "$profile")
  run_plan "$yes" bash "$mct" "${args[@]}"
  note "$(t 'Next time without questions: hs ct add --kind %s --name %s --ram %s' "$kind" "$name" "$ram")" ;;

# ───────────────────────────────────────────────────────────────────────────── edit
edit)
  [ $# -ge 1 ] || usage
  ct=$1; shift; ct_exists "$ct"
  ram=""; cpu=""; disk=""; auto=""; docker=""; yes=false; given=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --ram) ram=$2; given=true; shift 2 ;; --cpu) cpu=$2; given=true; shift 2 ;; --disk) disk=$2; given=true; shift 2 ;;
      --autostart) auto=$2; given=true; shift 2 ;; --docker) docker=$2; given=true; shift 2 ;; --yes) yes=true; shift ;; *) usage ;;
    esac
  done
  if ! $given; then
    need "an option such as --ram"
    cur_ram=$("$incus" config get "$ct" limits.memory 2>/dev/null | sed 's/MiB$//' || true)
    cur_cpu=$("$incus" config get "$ct" limits.cpu 2>/dev/null || true)
    cur_auto=$("$incus" config get "$ct" boot.autostart 2>/dev/null || true)
    cur_dock=$("$incus" config get "$ct" security.nesting 2>/dev/null || true)
    cur_disk=$("$incus" config device get "$ct" root size 2>/dev/null | sed 's/GiB$//' || true)
    new=$(ask "Memory in MB (none = no limit):" "${cur_ram:-none}"); [ "$new" = "${cur_ram:-none}" ] || ram=$new
    new=$(ask "CPU cores (none = no limit):" "${cur_cpu:-none}"); [ "$new" = "${cur_cpu:-none}" ] || cpu=$new
    new=$(ask "Disk size in GB:" "${cur_disk:-}"); [ "$new" = "${cur_disk:-}" ] || disk=$new
    d=no; [ "$cur_auto" = true ] && d=yes
    new=$(ask "Start with the server (yes/no):" "$d"); [ "$new" = "$d" ] || auto=$new
    d=no; [ "$cur_dock" = true ] && d=yes
    new=$(ask "Docker inside (yes/no):" "$d"); [ "$new" = "$d" ] || docker=$new
  fi
  sets=()
  [ -z "$ram" ] || sets+=("ram=$ram"); [ -z "$cpu" ] || sets+=("cpu=$cpu"); [ -z "$disk" ] || sets+=("disk=$disk")
  [ -z "$auto" ] || sets+=("autostart=$auto"); [ -z "$docker" ] || sets+=("docker=$docker")
  [ ${#sets[@]} -gt 0 ] || { note "Nothing to change."; exit 0; }
  run_plan "$yes" bash "$mct" "$ct" --set "${sets[@]}" ;;

# ───────────────────────────────────────────────────────────────────────────── snapshot
snapshot)
  [ $# -ge 1 ] || usage
  ct=$1; shift; ct_exists "$ct"
  action=""; target=""; yes=false
  if [ $# -ge 1 ] && [[ "$1" != --* ]]; then action=create; target=$1; shift; fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --create) action=create; target=${2:-}; shift; [ $# -eq 0 ] || shift ;; --restore) action=restore; target=$2; shift 2 ;;
      --delete) action=delete; target=$2; shift 2 ;; --yes) yes=true; shift ;; *) usage ;;
    esac
  done
  if [ -z "$action" ]; then
    need "an action"
    snaps=$(bash "$mct" "$ct" --snapshots || true)
    [ -z "$snaps" ] || { { thead 'Snapshot' 'Created'; printf '%s\n' "$snaps"; } | table; }
    action=$(choose "What now?" create restore delete cancel) || exit 1
    case "$action" in
      cancel) exit 0 ;;
      create) target=$(ask "Label (empty = automatic):" "") ;;
      restore|delete)
        mapfile -t names < <(cut -f1 <<<"$snaps")
        [ ${#names[@]} -gt 0 ] && [ -n "${names[0]}" ] || fail "This instance has no snapshots."
        target=$(choose "Which snapshot?" "${names[@]}") || exit 1 ;;
    esac
  fi
  case "$action" in
    create)  run_plan true bash "$mct" "$ct" --snapshot ${target:+"$target"} ;;
    restore) danger "Everything since this snapshot is lost, and newer snapshots are deleted (ZFS can only go back to the newest one). Attached storage is not part of a snapshot."
             if [ "$yes" != true ]; then
               interactive || fail "Nothing is changed without --yes when there is no terminal."
               confirm_name "$ct" "the instance" || fail "cancelled"
             fi
             run_plan true bash "$mct" "$ct" --restore "$target" ;;
    delete)  run_plan "$yes" bash "$mct" "$ct" --delete-snapshot "$target" ;;
  esac ;;

# ───────────────────────────────────────────────────────────────────────────── storage
storage)
  [ $# -ge 1 ] || usage
  ct=$1; shift; ct_exists "$ct"
  kind=""; source_=""; sname=""; path=""; ro=false; as=""; yes=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind) kind=$2; shift 2 ;; --source) source_=$2; shift 2 ;; --name) sname=$2; shift 2 ;; --path) path=$2; shift 2 ;;
      --readonly) ro=true; shift ;; --as) as=$2; shift 2 ;; --yes) yes=true; shift ;; *) usage ;;
    esac
  done
  if [ -z "$kind" ]; then
    need "--kind"
    step "$(t 'Storage of %s' "$ct")"
    { thead 'Device' 'Kind' 'Source'; bash "$mct" "$ct" --storage | cut -f1-3 || true; } | table
    kind=$(choose "What to attach?" "shares (a folder of a share, read/write)" "sensitive (a folder under /bulk/sensitive)" "fast (a volume on the SSD pool)") || exit 1
    kind=${kind%% *}
  fi
  case "$kind" in fast|shares|sensitive) ;; *) usage ;; esac
  if [ -z "$sname" ]; then
    if [ "$kind" = fast ]; then need "--name"; sname=$(ask "Name of the volume:" "$ct-data")
    else
      src=$source_
      if [ -z "$src" ]; then
        need "--source"
        mapfile -t shares < <(bash "$msh" --list | awk -F'\t' -v k="$kind" 'k == "shares" ? $2 != "sensitive" : $2 == "sensitive" { print $1 }')
        [ ${#shares[@]} -gt 0 ] || fail "No shares found."
        src=$(choose "Which share?" "${shares[@]}") || exit 1
      fi
      sname=$src
    fi
  fi
  if [ -z "$path" ]; then need "--path"; path=$(ask "Path inside the instance:" "/mnt/$sname"); fi
  if [ -z "$as" ] && [ "$kind" != fast ] && interactive; then
    mapfile -t users < <(bash "$mct" "$ct" --users | awk -F'\t' '{ printf "%s (%s:%s)\n", $1, $2, $3 }')
    if [ ${#users[@]} -gt 0 ]; then
      u=$(choose "Which user inside the instance writes there? (esc = none)" "${users[@]}" 2>/dev/null || true)
      [ -z "$u" ] || as=$(sed -E 's/.*\(([0-9]+:[0-9]+)\)$/\1/' <<<"$u")
    fi
    confirm "Read-only?" && ro=true || true
  fi
  args=("$ct" --add-storage "$kind" "$sname" "$path")
  $ro && args+=(--readonly)
  [ -z "$as" ] || args+=(--as "$as")
  run_plan "$yes" bash "$mct" "${args[@]}" ;;

# ───────────────────────────────────────────────────────────────────────────── ip
ip)
  [ $# -ge 1 ] || usage
  ct=$1; shift; ct_exists "$ct"
  addr=${1:-}
  if [ -z "$addr" ]; then
    need "an address"
    bash "$nip" "$ct" show || true
    addr=$(ask "New fixed address (empty = leave as it is):" "")
    [ -n "$addr" ] || { note "Unchanged."; exit 0; }
  fi
  [[ "$addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "$(t "'%s' is not an IPv4 address." "$addr")"
  run_plan true bash "$mct" "$ct" --set "ip=$addr" ;;

*) usage ;;
esac
