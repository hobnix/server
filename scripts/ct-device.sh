#!/usr/bin/env bash
# help: pass host hardware (USB, GPU, PCI) into an instance, and list what an instance has
# help.de: Hardware des Servers (USB, GPU, PCI) an eine Instanz durchreichen und anzeigen, was eine Instanz hat
# args: --hardware | <ct> --list | <ct> --add usb|gpu|pci <id> [--name <device>] | <ct> --remove <device> [--table] [--dry-run] [--yes]
set -euo pipefail

# Everything the interface (the web interface, Instances > Devices) does for hardware goes through this script:
#   ct-device.sh --hardware [--table]
#       host devices an instance can be given, tab separated, 11 fields, one line per device (usb, then gpu, then pci, each sorted by id):
#       kind (usb|gpu|pci), id (usb vvvv:pppp, pci 0000:01:00.0), vvvv:pppp, vendor, product, driver, iommu group, vm, ct, used by, count
#       vm / ct: "ok" or one reason word:
#         host-disk host-network boot-display host-system nvidia-host no-iommu group-shared nvidia-recipe no-driver vm-only
#       An empty field is written "-". USB root hubs and hubs, and PCI bridges, are left out (adding one is refused: host-system).
#   ct-device.sh <ct> --list [--table]
#       the usb/gpu/pci devices of an instance, tab separated: name, kind, id, present (yes|no), product, from (instance|profile), with
#   ct-device.sh <ct> --add usb <vvvv:pppp> [--name <device>] [--dry-run] [--yes]
#   ct-device.sh <ct> --add gpu|pci <[dddd:]bb:ss.f> [--name <device>] [--dry-run] [--yes]
#   ct-device.sh <ct> --remove <device> [--dry-run]
# --dry-run prints the plan as plain lines: "  incus ..." commands, "step: ...", "note: ...", "warn: ...", "danger: ..." and, only for a VM
# gpu/pci add, "confirm: <pci address>" (the word to type). Exit 0 = allowed; a refusal is a normal failure (exit 1).
# --yes skips the typed PCI address (a background job asks nothing: the interface checked it).
# Knob for tests: HS_SYSFS (default /sys).

here=$(dirname "$0")
. "$here/lib/ui.sh"
SYS=${HS_SYSFS:-/sys}

usage() {
  say "usage: hs ct hardware"
  say "       hs ct <ct> device list | add usb <vendor:product> | add gpu|pci <pci address> | remove <device>"
  exit 1
}

dry=false
yes=false
table=false
args=()
for a in "$@"; do
  case "$a" in
    --dry-run) dry=true ;;
    --yes)     yes=true ;;   # a background job asks nothing (the interface checked the typed address)
    --table)   table=true ;;
    *)         args+=("$a") ;;
  esac
done
set -- "${args[@]}"

# run a command, or only print it with --dry-run
run() {
  if $dry; then
    printf '  %s' "$1"; printf ' %q' "${@:2}"; printf '\n'
  else
    "$@"
  fi
}

# a line of the plan: with --dry-run a plain "kind: text" line (read by ct-change.sh), else the ui.sh line
emit() {   # emit step|note|warn|danger <text>
  if $dry; then printf '%s: %s\n' "$1" "$2"; else "$1" "$2"; fi
}

# ── hardware ──

HW=""        # the --hardware lines
USED=""      # key <TAB> instance <TAB> status <TAB> type (container|virtual-machine), one line per passed-through device in an instance
RES=""       # incus query /1.0/resources
DISKS=""     # resolved sysfs paths of the host's block devices and network interfaces (each ends in /)
NETS=""
USBNETS=""   # vendor:product of USB devices with a network interface below them
USBDISKS=""  # vendor:product of USB devices with a block device below them

# normalise a PCI address for jq: lowercase, "0000:" in front when it has only bus:slot.function
JQ_PCI='ascii_downcase | if length == 7 then "0000:" + . else . end'

pci_class() { cat "$SYS/bus/pci/devices/$1/class" 2>/dev/null || printf '0x000000'; }

# the first reason in pci_basic: a disk controller, a network card or the server's screen (R empty = none)
pci_basic() {   # pci_basic <addr>
  local a=$1 c
  c=$(pci_class "$a")
  R=
  case "$c" in 0x01*) R=host-disk; return 0 ;; esac
  case "$DISKS" in *"/$a/"*) R=host-disk; return 0 ;; esac
  case "$c" in 0x02*) R=host-network; return 0 ;; esac
  case "$NETS" in *"/$a/"*) R=host-network; return 0 ;; esac
  case "$c" in 0x06*|0x0c05*) R=host-system; return 0 ;; esac   # a bridge, the ISA/LPC bridge, SMBus
  if [ "$(cat "$SYS/bus/pci/devices/$a/boot_vga" 2>/dev/null || true)" = 1 ]; then R=boot-display; fi
  return 0
}

has_iommu() {   # has_iommu <addr>
  [ -n "$(ls -A "$SYS/kernel/iommu_groups" 2>/dev/null || true)" ] && [ -L "$SYS/bus/pci/devices/$1/iommu_group" ]
}

iommu_group() {   # iommu_group <addr>: the group number, "-" when there is none
  if [ -L "$SYS/bus/pci/devices/$1/iommu_group" ]; then basename "$(readlink -f "$SYS/bus/pci/devices/$1/iommu_group")"; else printf -- '-'; fi
}

pci_driver() {   # pci_driver <addr>: the host driver from the hardware scan, "-" when there is none
  jq -r --arg a "$1" '[ (.pci.devices // [])[] | select((.pci_address | ascii_downcase) == $a) | (.driver // "") | if . == "" then "-" else . end ] | first // "-"' <<<"$RES"
}

# why one PCI function cannot go into a VM (no look at its siblings): R is the reason word or "ok", RARG the other device of a shared IOMMU group
pci_vm_one() {   # pci_vm_one <addr> <driver>
  local a=$1 m grp c
  R=; RARG=
  pci_basic "$a"; [ -z "$R" ] || return 0
  if [ "$2" = nvidia ]; then R=nvidia-host; return 0; fi
  if ! has_iommu "$a"; then R=no-iommu; return 0; fi
  grp=$(iommu_group "$a")
  for m in "$SYS/kernel/iommu_groups/$grp/devices/"*; do
    [ -e "$m" ] || continue
    m=$(basename "$m")
    [ "${m%.*}" != "${a%.*}" ] || continue            # a function of the same bus:slot goes along
    c=$(pci_class "$m")
    case "$c" in 0x0604*) continue ;; esac            # a bridge
    R=group-shared; RARG=$m; return 0
  done
  R=ok
}

# why a PCI device cannot go into a VM: the device and every other function of its slot (they all go along) get the same checks
pci_vm_reason() {   # pci_vm_reason <addr> <driver>
  local a=$1 s
  pci_vm_one "$a" "$2"; [ "$R" = ok ] || return 0
  for s in "$SYS/bus/pci/devices/${a%.*}."*; do
    [ -e "$s" ] || continue
    s=$(basename "$s")
    [ "$s" != "$a" ] || continue
    pci_vm_one "$s" "$(pci_driver "$s")"; [ "$R" = ok ] || return 0
  done
  R=ok
}

used_by() {   # used_by <key>: instances that have it, comma joined, "-" for none
  local u
  u=$(awk -F'\t' -v k="$1" '$1 == k { print $2 }' <<<"$USED" | sort -u | paste -sd, -)
  printf '%s' "${u:--}"
}

# read the hardware once: fills HW, USED, RES, DISKS, NETS
hw_load() {
  local insts p usb_lines gpu_lines="" pci_lines="" a vidpid vendor product drv cls kind iommu vmr ctr row
  RES=$(incus query /1.0/resources 2>/dev/null) || fail "$(t "Could not read the hardware from Incus.")"
  insts=$(incus query '/1.0/instances?recursion=1' 2>/dev/null) || fail "$(t "Could not read the instances from Incus.")"
  USED=$(jq -r '
    .[] | .name as $n | (.status // "-") as $s | (.type // "-") as $ty | (.expanded_devices // {}) | to_entries[] | .value
    | (if .type == "usb" and .vendorid and .productid then "\(.vendorid | ascii_downcase):\(.productid | ascii_downcase)"
       elif .type == "gpu" and .pci then (.pci | '"$JQ_PCI"')
       elif .type == "pci" and .address then (.address | '"$JQ_PCI"')
       else empty end) as $k
    | [$k, $n, $s, $ty] | @tsv' <<<"$insts") || fail "$(t "Could not read the instances from Incus.")"
  for p in "$SYS"/block/*; do [ -e "$p" ] || continue; DISKS+="$(readlink -f "$p")/"$'\n'; done
  for p in "$SYS"/class/net/*; do [ -e "$p" ] || continue; NETS+="$(readlink -f "$p")/"$'\n'; done
  for p in "$SYS"/bus/usb/devices/*; do   # a USB device with a network interface below it (a USB network adapter)
    [ -f "$p/idVendor" ] || continue
    case "$NETS" in *"$(readlink -f "$p")/"*) USBNETS+="$(tr 'A-Z' 'a-z' <"$p/idVendor"):$(tr 'A-Z' 'a-z' <"$p/idProduct")"$'\n' ;; esac
    case "$DISKS" in *"$(readlink -f "$p")/"*) USBDISKS+="$(tr 'A-Z' 'a-z' <"$p/idVendor"):$(tr 'A-Z' 'a-z' <"$p/idProduct")"$'\n' ;; esac
  done

  usb_lines=$(jq -r '
    def clean: (. // "" | tostring | gsub("[\t\n\r]"; " ") | if . == "" then "-" else . end);
    [ (.usb.devices // [])[]
      | select((.vendor_id // "") != "1d6b")
      | select(((.interfaces // []) | length) == 0 or ((.interfaces // []) | any(.class_id != 9))) ]
    | group_by((.vendor_id | ascii_downcase) + ":" + (.product_id | ascii_downcase))[]
    | .[0] as $f
    | (($f.vendor_id | ascii_downcase) + ":" + ($f.product_id | ascii_downcase)) as $id
    | ([ .[] | (.interfaces // [])[] | .driver // empty ] | unique | join(",")) as $drv
    | [$id, ($f.vendor | clean), ($f.product | clean), (if $drv == "" then "-" else $drv end),
       (if ($drv | test("(^|,)(usb-storage|uas|rtsx_usb|ums[-_][a-z0-9_-]*)(,|$)")) or ([ .[] | (.interfaces // [])[] | .class_id ] | any(. == 8)) then "host-disk" else "ok" end), length] | @tsv' <<<"$RES")
  HW=""
  while IFS=$'\t' read -r a vendor product drv vmr cls; do
    [ -n "$a" ] || continue
    if [ "$vmr" = ok ]; then
      case ",$drv," in *,r8152,*|*,cdc_ether,*|*,cdc_ncm,*|*,rndis_host,*|*,asix,*|*,ax88179_178a,*|*,cdc_eem,*|*,smsc95xx,*|*,lan78xx,*) vmr=host-network ;; esac
      case "$USBNETS" in *"$a"*) vmr=host-network ;; esac
      case "$USBDISKS" in *"$a"*) vmr=host-disk ;; esac
    fi
    HW+=$(printf 'usb\t%s\t%s\t%s\t%s\t%s\t-\t%s\t%s\t%s\t%s' "$a" "$a" "$vendor" "$product" "$drv" "$vmr" "$vmr" "$(used_by "$a")" "$cls")$'\n'
  done <<<"$usb_lines"

  while IFS=$'\t' read -r a vidpid vendor product drv; do
    [ -n "$a" ] || continue
    cls=$(pci_class "$a")
    case "$cls" in 0x06*) continue ;; esac     # bridges are never listed
    iommu=$(iommu_group "$a")
    pci_vm_reason "$a" "$drv"; vmr=$R
    case "$cls" in
      0x03*) kind=gpu
             if [ "$drv" = nvidia ]; then ctr=nvidia-recipe; elif [ "$drv" = - ]; then ctr=no-driver; else ctr=ok; fi ;;
      *)     kind=pci; ctr=vm-only ;;
    esac
    row=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t1' "$kind" "$a" "$vidpid" "$vendor" "$product" "$drv" "$iommu" "$vmr" "$ctr" "$(used_by "$a")")
    if [ "$kind" = gpu ]; then gpu_lines+="$row"$'\n'; else pci_lines+="$row"$'\n'; fi
  done < <(jq -r '
    def clean: (. // "" | tostring | gsub("[\t\n\r]"; " ") | if . == "" then "-" else . end);
    [ (.pci.devices // [])[] ] | sort_by(.pci_address)[]
    | [ (.pci_address | ascii_downcase), ((.vendor_id // "0000" | ascii_downcase) + ":" + (.product_id // "0000" | ascii_downcase)),
        (.vendor | clean), (.product | clean), (.driver | clean) ] | @tsv' <<<"$RES")
  HW+="$gpu_lines$pci_lines"
}

hw_row() {   # hw_row <id>: the --hardware line of a device, empty when there is none
  awk -F'\t' -v k="$1" '$2 == k { print; exit }' <<<"$HW"
}
field() {   # field <line> <n>
  awk -F'\t' -v n="$2" '{ print $n }' <<<"$1"
}

hardware() {
  hw_load
  if ! $table; then
    [ -z "$HW" ] || printf '%s' "$HW"
    return 0
  fi
  { thead 'Kind' 'ID' 'Vendor' 'Product' 'Driver' 'VM' 'Container' 'Used by'
    printf '%s' "$HW" | awk -F'\t' 'NF { print $1 "\t" $2 "\t" $4 "\t" $5 "\t" $6 "\t" $8 "\t" $9 "\t" $10 }'
  } | table
  if awk -F'\t' '$8 == "no-iommu" { f = 1 } END { exit !f }' <<<"$HW"; then
    warn "$(t "IOMMU is off, so no PCI device can go into a VM. Switch on VT-d (Intel) or AMD-Vi/IOMMU (AMD) in the firmware setup; Intel also needs the kernel option intel_iommu=on")"
  fi
}

# ── one instance ──

inst_json() {   # inst_json <ct>: sets INST, the instance as Incus has it
  INST=$(incus query "/1.0/instances/$1" 2>/dev/null) || fail_fix "$(t "There is no instance called '%s'." "$1")" "hs ct list"
}

list_devices() {   # list_devices <ct>
  local ct=$1 lines name kind id from present product row
  inst_json "$ct"
  hw_load
  lines=$(jq -r '
    (.devices // {}) as $own
    | (.expanded_devices // {}) | to_entries | sort_by(.key)[]
    | select(.value.type == "usb" or .value.type == "gpu" or .value.type == "pci")
    | [ .key, .value.type,
        (if .value.type == "usb" then (if .value.vendorid and .value.productid then "\(.value.vendorid | ascii_downcase):\(.value.productid | ascii_downcase)" else "-" end)
         elif .value.type == "gpu" then (if .value.pci then (.value.pci | '"$JQ_PCI"') else "-" end)
         else (if .value.address then (.value.address | '"$JQ_PCI"') else "-" end) end),
        (if $own[.key] then "instance" else "profile" end) ] | @tsv' <<<"$INST")
  local rows=""
  while IFS=$'\t' read -r name kind id from; do
    [ -n "$name" ] || continue
    present=no; product=-
    if [ "$id" != - ]; then
      row=$(hw_row "$id")
      if [ "$kind" = usb ]; then
        [ -z "$row" ] || present=yes
      elif [ -e "$SYS/bus/pci/devices/$id" ]; then
        present=yes
      fi
      [ -z "$row" ] || product=$(field "$row" 5)
    fi
    rows+=$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$name" "$kind" "$id" "$present" "$product" "$from")$'\n'
  done <<<"$lines"
  # the "with" column: a pci device <main>-f<n> in the slot of the main device
  rows=$(awk -F'\t' -v OFS='\t' '
    NF { n++; name[n] = $1; kind[n] = $2; id[n] = $3; line[n] = $0; byname[$1] = n }
    END {
      for (i = 1; i <= n; i++) {
        w = "-"
        if (kind[i] == "pci" && match(name[i], /-f[0-9]+$/)) {
          main = substr(name[i], 1, RSTART - 1)
          if ((main in byname) && kind[byname[main]] != "usb" && id[byname[main]] != "-" && id[i] != "-") {
            a = id[byname[main]]; b = id[i]; sub(/\.[0-7]$/, "", a); sub(/\.[0-7]$/, "", b)
            if (a == b) w = main
          }
        }
        print line[i], w
      }
    }' <<<"${rows%$'\n'}")
  if ! $table; then
    [ -z "$rows" ] || printf '%s\n' "$rows"
    return 0
  fi
  { thead 'Device' 'Kind' 'ID' 'Plugged in' 'Product' 'From'; printf '%s\n' "$rows" | awk -F'\t' 'NF { print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 }'; } | table
}

# ── refusals ──

# refuse <word> [arg]: the failure text and fix of a reason word
refuse() {
  local msg fix=""
  case "$1" in
    host-disk)     msg=$(t "the server's disks hang on it (the system disk, a pool or the backup disk)"); fix="hs ct $ct storage add" ;;
    host-system)   msg=$(t "it is a part of the server itself (a bridge, a hub or a board controller)") ;;
    host-network)  msg=$(t "it is a network card of the server") ;;
    boot-display)  msg=$(t "it is the server's screen (the console would go dark)") ;;
    nvidia-host)   msg=$(t "the server's NVIDIA driver and the containers use this card"); fix=$(t "take nvidia out of gpu in machine.toml, hs rebuild, reboot") ;;
    no-iommu)      msg=$(t "IOMMU is off, so no PCI device can go into a VM. Switch on VT-d (Intel) or AMD-Vi/IOMMU (AMD) in the firmware setup; Intel also needs the kernel option intel_iommu=on"); fix=$(t "see the guide: Pass hardware to an instance") ;;
    group-shared)  msg=$(t "its IOMMU group also holds %s; the board does not separate them" "${2:-?}") ;;
    nvidia-recipe) msg=$(t "the NVIDIA card goes into a container through a recipe that sets up its libraries (jellyfin, immich, tdarr)"); fix="hs recipe <name>" ;;
    no-driver)     msg=$(t "the server has no driver for it, so a container cannot use it") ;;
    vm-only)       msg=$(t "only a VM can take a PCI device") ;;
    *)             msg=$1 ;;
  esac
  msg=$(t "%s cannot be passed in: %s" "$id" "$msg")
  if [ -n "$fix" ]; then fail_fix "$msg" "$fix"; fi
  fail "$msg"
}

# ── add ──

valid_device_name() { [[ "$1" =~ ^[a-z][a-z0-9-]{0,40}$ ]] || fail "$(t "invalid device name '%s' (lowercase letters, digits, -)" "$1")"; }

# normalise the id into $id, and fix the default device name
normalise() {   # normalise <kind> <id> <name>
  local v=${2,,} d b s f
  case "$1" in
    usb)
      [[ "$v" =~ ^[0-9a-f]{4}:[0-9a-f]{4}$ ]] || fail "$(t "invalid USB id '%s' (vendor:product, for example 04f9:0042)" "$2")"
      id=$v; name=${3:-usb-${v%%:*}-${v##*:}} ;;
    gpu|pci)
      if [[ "$v" =~ ^[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]]; then v=0000:$v; fi
      [[ "$v" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] || fail "$(t "invalid PCI address '%s' (for example 0000:01:00.0)" "$2")"
      id=$v
      d=${v%%:*}; b=${v#*:}; s=${b#*:}; b=${b%%:*}; f=${s#*.}; s=${s%%.*}
      if [ "$d" = 0000 ]; then name=${3:-$1-$b-$s-$f}; else name=${3:-$1-$d-$b-$s-$f}; fi ;;
    *) fail "$(t "unknown kind '%s' (usb, gpu or pci)" "$1")" ;;
  esac
  valid_device_name "$name"
}

added=()          # devices added so far, for the rollback
restart_vm=false  # the VM runs and has to be stopped for a PCI device

rollback() {
  local d
  $dry && return 0
  for d in "${added[@]}"; do incus config device remove "$ct" "$d" >/dev/null 2>&1 || true; done
  ! $restart_vm || incus start "$ct" >/dev/null 2>&1 || true
}

add_device() {   # add_device <kind> <id> <name>: the device and the plan go through the globals set by add()
  run incus config device add "$ct" "$@" || { rollback; fail "$(t "Incus could not add the device '%s'." "$1")"; }
  added+=("$1")
}

add() {
  local kind=$1 row p word other inst status utype x user_lines gpus gid="" product sib sibs=() sibname drv
  local is_vm=false running=false
  normalise "$kind" "$2" "${3:-}"
  inst_json "$ct"
  [ "$(jq -r '.type' <<<"$INST")" != virtual-machine ] || is_vm=true
  [ "$(jq -r '.status // ""' <<<"$INST")" != Running ] || running=true
  if [ "$kind" = pci ] && ! $is_vm; then refuse vm-only; fi

  if incus config device get "$ct" "$name" type >/dev/null 2>&1; then
    fail "$(t "'%s' already has a device called '%s'." "$ct" "$name")"
  fi

  hw_load
  row=$(hw_row "$id")
  product=-
  if [ "$kind" = usb ] && jq -e --arg id "$id" '
       [ (.usb.devices // [])[] | select(((.vendor_id // "" | ascii_downcase) + ":" + (.product_id // "" | ascii_downcase)) == $id)
         | (.vendor_id // "" | ascii_downcase) == "1d6b" or ((.interfaces // []) | any(.class_id == 9)) ] | any' <<<"$RES" >/dev/null; then
    refuse host-system   # a hub or root hub is not in the list, so it would count as "not plugged in"
  fi
  if [ -z "$row" ]; then
    if [ "$kind" != usb ]; then
      [ -e "$SYS/bus/pci/devices/$id" ] || fail_fix "$(t "There is no PCI device %s on this server." "$id")" "hs ct hardware"
    fi
  else
    product=$(field "$row" 5)
  fi

  # every function of the slot that would be passed: the device and, for a VM, its siblings
  local passes_pci=false
  if $is_vm && [ "$kind" != usb ]; then passes_pci=true; fi
  if $passes_pci; then
    for p in "$SYS/bus/pci/devices/${id%.*}."*; do
      [ -e "$p" ] || continue
      p=$(basename "$p")
      [ "$p" != "$id" ] || continue
      sibs+=("$p")
    done
  fi

  # a gpu device is a display function; its audio function goes along by itself (or is added with pci)
  if [ "$kind" = gpu ]; then
    case "$(pci_class "$id")" in 0x03*) ;; *)
      fail_fix "$(t "%s is not a graphics function (class %s)." "$id" "$(pci_class "$id")")" "hs ct $ct device add pci $id" ;;
    esac
  fi
  # a bridge or other device that is not in the list: a VM still gets the checks
  if [ -z "$row" ] && [ "$kind" != usb ] && $is_vm; then
    pci_vm_reason "$id" "$(pci_driver "$id")"
    if [ "$R" != ok ]; then refuse "$R" "$RARG"; fi
  fi

  # can this instance take it (for a VM the reason of the row covers every function of the slot)
  if [ -n "$row" ]; then
    if $is_vm; then word=$(field "$row" 8); else word=$(field "$row" 9); fi
    if [ "$word" != ok ]; then
      other=
      if [ "$word" = group-shared ]; then pci_vm_reason "$id" "$(field "$row" 6)"; other=$RARG; fi
      refuse "$word" "$other"
    fi
  fi

  # who has it already (a graphics card is shared by containers by design; only a VM needs it alone)
  local warns=() w dup
  for p in "$id" "${sibs[@]}"; do
    user_lines=$(awk -F'\t' -v k="$p" '$1 == k { print $2 "\t" $3 "\t" $4 }' <<<"$USED")
    while IFS=$'\t' read -r inst status utype; do
      [ -n "$inst" ] || continue
      if [ "$inst" = "$ct" ]; then fail "$(t "%s is already passed to '%s'." "$p" "$ct")"; fi
      if [ "$kind" = usb ]; then
        fail "$(t "%s is already passed to %s. Remove it there first: hs ct %s device remove <device>" "$p" "$inst" "$inst")"
      fi
      if ! $is_vm && [ "$utype" != virtual-machine ]; then continue; fi
      if [ "$status" != Stopped ]; then   # Frozen, Stopping, Starting count as running
        fail "$(t "%s is in use by the running instance %s." "$p" "$inst")"
      fi
      w=$(t "%s has it too; only one of them can run at a time" "$inst"); dup=false
      for x in "${warns[@]}"; do [ "$x" != "$w" ] || dup=true; done
      $dup || warns+=("$w")
    done <<<"$user_lines"
  done

  # the plan
  emit step "$(t "pass %s (%s) to %s" "$id" "$product" "$ct")"
  if [ -z "$row" ]; then emit note "$(t "not plugged in now; it goes in when it is plugged in")"; fi
  for p in "${warns[@]}"; do emit warn "$p"; done
  if [ "$kind" = usb ] && $is_vm && [ -n "$row" ] && jq -e --arg id "$id" '
       [ (.usb.devices // [])[] | select(((.vendor_id | ascii_downcase) + ":" + (.product_id | ascii_downcase)) == $id)
         | (.interfaces // [])[] | .class_id ] | any(. == 3)' <<<"$RES" >/dev/null; then
    emit warn "$(t "the server lets go of it while the VM runs (a keyboard, a UPS)")"
  fi
  if $passes_pci; then
    if $running; then restart_vm=true; emit warn "$(t "the VM stops and starts again")"; fi
    emit note "$(t "the VM's whole memory is reserved while it runs (VFIO)")"
    if [ "$kind" = gpu ]; then
      gpus=$(awk -F'\t' '$1 == "gpu" { n++ } END { print n + 0 }' <<<"$HW")
      if [ "$gpus" -le 1 ]; then emit note "$(t "the server has no other graphics chip; fine for a server without a screen")"; fi
    fi
    drv=$(field "$row" 6)
    if [ "$drv" != vfio-pci ] && [ "$drv" != - ]; then
      emit note "$(t "Incus unbinds the driver %s at the start of the VM and gives the card back when it stops" "$drv")"
    fi
    for sib in "${sibs[@]}"; do
      sibname=$(hw_row "$sib")
      emit step "$(t "also pass %s (%s), the same card" "$sib" "$([ -z "$sibname" ] && printf -- - || field "$sibname" 5)")"
    done
  fi
  if [ "$kind" = gpu ] && ! $is_vm; then
    if $running; then gid=$(incus exec "$ct" -- getent group render </dev/null 2>/dev/null | cut -d: -f3 || true); fi
    if [ -z "$gid" ]; then emit note "$(t "no render group inside yet: only root can use the card")"; fi
  fi

  if $passes_pci; then
    if $dry; then
      emit danger "$(t "%s (%s) is taken from the server while %s runs." "$id" "$product" "$ct")"
      printf 'confirm: %s\n' "$id"
    elif ! $yes; then
      danger "$(t "%s (%s) is taken from the server while %s runs." "$id" "$product" "$ct")"
      confirm_name "$id" "the PCI address" || fail "cancelled"
    fi
  fi

  # do it
  case "$kind" in
    usb) add_device "$name" usb "vendorid=${id%%:*}" "productid=${id##*:}" required=false ;;
    gpu|pci)
      if $is_vm; then
        if $restart_vm; then run incus stop "$ct"; fi
        if [ "$kind" = gpu ]; then add_device "$name" gpu gputype=physical "pci=$id"; else add_device "$name" pci "address=$id"; fi
        for sib in "${sibs[@]}"; do add_device "$name-f${sib##*.}" pci "address=$sib"; done
        if $restart_vm; then
          if $dry; then
            run incus start "$ct"
          elif ! incus start "$ct"; then
            rollback
            fail "$(t "The VM did not start with %s; it runs again without it." "$id")"
          fi
        fi
      else
        if [ -n "$gid" ]; then add_device "$name" gpu gputype=physical "pci=$id" "gid=$gid"; else add_device "$name" gpu gputype=physical "pci=$id"; fi
      fi ;;
  esac
  ! $dry && ok "$(t "Passed %s to '%s'." "$id" "$ct")"
  return 0
}

# ── remove ──

remove() {   # remove <device>
  local dev=$1 type id sibs s running=false is_vm=false
  inst_json "$ct"
  if ! jq -e --arg d "$dev" '(.devices // {}) | has($d)' <<<"$INST" >/dev/null; then
    if jq -e --arg d "$dev" '(.expanded_devices // {}) | has($d)' <<<"$INST" >/dev/null; then
      fail "$(t "'%s' comes from the profile; change the profile instead." "$dev")"
    fi
    fail "$(t "'%s' has no device called '%s'." "$ct" "$dev")"
  fi
  type=$(jq -r --arg d "$dev" '.devices[$d].type // ""' <<<"$INST")
  case "$type" in usb|gpu|pci) ;; *)
    fail "$(t "'%s' is not a passed-through device; storage goes with hs ct %s storage remove." "$dev" "$ct")" ;;
  esac
  id=$(jq -r --arg d "$dev" '.devices[$d] | if .type == "usb" then (if .vendorid then "\(.vendorid | ascii_downcase):\(.productid | ascii_downcase)" else "-" end)
       elif .type == "gpu" then (if .pci then (.pci | '"$JQ_PCI"') else "-" end)
       else (if .address then (.address | '"$JQ_PCI"') else "-" end) end' <<<"$INST")
  [ "$(jq -r '.type' <<<"$INST")" != virtual-machine ] || is_vm=true
  [ "$(jq -r '.status // ""' <<<"$INST")" != Running ] || running=true
  sibs=()
  if [ "$type" != usb ] && [ "$id" != - ]; then
    while IFS= read -r s; do
      [ -n "$s" ] && sibs+=("$s")
    done < <(jq -r --arg d "$dev" --arg slot "${id%.*}" '
      (.devices // {}) | to_entries[]
      | select(.key | test("^" + $d + "-f"))
      | select(.value.type == "pci" and ((.value.address // "") | ascii_downcase | if length == 7 then "0000:" + . else . end | sub("\\.[0-7]$"; "")) == $slot)
      | .key' <<<"$INST")
  fi
  local stop=false
  if $is_vm && $running && [ "$type" != usb ]; then stop=true; fi
  emit step "$(t "give %s back to the server" "$([ "$id" = - ] && printf '%s' "$dev" || printf '%s' "$id")")"
  if $stop; then emit warn "$(t "the VM stops and starts again")"; fi
  if $stop; then run incus stop "$ct"; fi
  for s in "$dev" "${sibs[@]}"; do
    if ! run incus config device remove "$ct" "$s"; then
      if $stop; then incus start "$ct" >/dev/null 2>&1 || true; fi
      fail "$(t "Incus could not remove the device '%s'." "$s")"
    fi
  done
  if $stop; then
    if $dry; then run incus start "$ct"
    elif ! incus start "$ct"; then fail "$(t "The VM did not start after the device was removed.")"; fi
  fi
  ! $dry && ok "$(t "Removed. The server has the device again.")"
  return 0
}

# ── main ──

[ $# -ge 1 ] || usage
if [ "$1" = --hardware ]; then
  hardware
  exit 0
fi
ct=$1
[[ "$ct" =~ ^[a-z][a-z0-9-]*$ ]] || fail "$(t "invalid name '%s' (lowercase letters, digits, -)" "$ct")"
[ $# -ge 2 ] || usage
mode=$2; shift 2
case "$mode" in
  --list) list_devices "$ct" ;;
  --add)
    [ $# -ge 2 ] || usage
    kind=$1; devid=$2; shift 2
    devname=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --name) [ $# -ge 2 ] || usage; devname=$2; shift 2 ;;
        *) usage ;;
      esac
    done
    id=""; name=""
    add "$kind" "$devid" "$devname" ;;
  --remove)
    [ $# -ge 1 ] || usage
    id=""
    remove "$1" ;;
  *) usage ;;
esac
