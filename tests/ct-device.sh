#!/usr/bin/env bash
# scripts/ct-device.sh: hardware passthrough to instances. --hardware (USB, GPU, PCI and why one cannot be passed), <ct> --list, and
# --add / --remove with their checks, dry-run lines and the rollback of a failed VM start. Fake incus on PATH, a fake sysfs (HS_SYSFS).
# Needs jq (always there in CI), no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1
BIN=$WORK/bin; mkdir -p "$BIN"
export LOG=$WORK/incus.log; : > "$LOG"
export FX=$WORK/fx; mkdir -p "$FX"
export HS_SYSFS=$WORK/sys
SYS=$HS_SYSFS

if ! command -v jq >/dev/null 2>&1; then skip "jq is not installed: device tests not run"; finish; exit $?; fi

# ── the fake sysfs ──
mkdir -p "$SYS/bus/pci/devices" "$SYS/kernel/iommu_groups" "$SYS/block" "$SYS/class/net"
pcidev() {   # pcidev <addr> <class> <group> [boot_vga]
  mkdir -p "$SYS/bus/pci/devices/$1"
  printf '%s\n' "$2" > "$SYS/bus/pci/devices/$1/class"
  if [ -n "${4:-}" ]; then printf '%s\n' "$4" > "$SYS/bus/pci/devices/$1/boot_vga"; fi
  mkdir -p "$SYS/kernel/iommu_groups/$3/devices"
  : > "$SYS/kernel/iommu_groups/$3/devices/$1"
  ln -s "$SYS/kernel/iommu_groups/$3" "$SYS/bus/pci/devices/$1/iommu_group"
}
pcidev 0000:00:02.0 0x030000 0 1
pcidev 0000:00:17.0 0x010601 1
pcidev 0000:00:1c.0 0x060400 2
pcidev 0000:01:00.0 0x030000 12
pcidev 0000:01:00.1 0x040300 12
pcidev 0000:03:00.0 0x030000 14
pcidev 0000:03:00.1 0x040300 14
pcidev 0000:04:00.0 0x020000 3
pcidev 0000:05:00.0 0x0c0330 15
pcidev 0000:06:00.0 0x0c0330 15
pcidev 0000:07:00.0 0x030000 16      # a card whose sibling function is a network card
pcidev 0000:07:00.1 0x020000 16
pcidev 0000:08:00.0 0x030000 17      # a card whose sibling function is a disk controller
pcidev 0000:08:00.1 0x010802 17
pcidev 0000:0a:00.0 0x040300 18      # an audio function whose sibling is the boot display
pcidev 0000:0a:00.1 0x030000 18 1
pcidev 0000:0b:00.0 0x030000 19      # a card a running container uses
pcidev 0000:0c:00.0 0x030000 20      # a card a running VM uses
pcidev 0000:0d:00.0 0x030000 21      # a card whose audio function a running VM uses
pcidev 0000:0d:00.1 0x040300 21
pcidev 0000:00:1f.0 0x060100 22      # an LPC bridge, an audio function and an SMBus controller in one slot
pcidev 0000:00:1f.3 0x040300 22
pcidev 0000:00:1f.4 0x0c0500 22
pcidev 0000:0e:00.0 0x030000 23      # a card a frozen VM holds
mkdir -p "$SYS/devices/usb1/1-4/1-4:1.0/net/enx0" "$SYS/bus/usb/devices"
printf '2357
' > "$SYS/devices/usb1/1-4/idVendor"; printf '0601
' > "$SYS/devices/usb1/1-4/idProduct"
ln -s "$SYS/devices/usb1/1-4" "$SYS/bus/usb/devices/1-4"
ln -s "$SYS/devices/usb1/1-4/1-4:1.0/net/enx0" "$SYS/class/net/enx0"
mkdir -p "$SYS/devices/usb1/1-5/1-5:1.0/host0/sdb"      # a USB disk the usual drivers do not show: a block device below it
printf 'abcd
' > "$SYS/devices/usb1/1-5/idVendor"; printf '0002
' > "$SYS/devices/usb1/1-5/idProduct"
ln -s "$SYS/devices/usb1/1-5" "$SYS/bus/usb/devices/1-5"
ln -s "$SYS/devices/usb1/1-5/1-5:1.0/host0/sdb" "$SYS/block/sdb"
mkdir -p "$SYS/devices/0000:00:17.0/ata1/sda" "$SYS/devices/0000:04:00.0/net/enp4s0"
ln -s "$SYS/devices/0000:00:17.0/ata1/sda" "$SYS/block/sda"
ln -s "$SYS/devices/0000:04:00.0/net/enp4s0" "$SYS/class/net/enp4s0"

# ── the fake Incus ──
cat > "$FX/resources.json" <<'JSON'
{"usb":{"devices":[
 {"vendor_id":"046d","product_id":"c52b","vendor":"Logitech","product":"Unifying Receiver","interfaces":[{"class_id":3,"driver":"usbhid"}]},
 {"vendor_id":"046d","product_id":"c52b","vendor":"Logitech","product":"Unifying Receiver","interfaces":[{"class_id":3,"driver":"usbhid"}]},
 {"vendor_id":"04f9","product_id":"0042","vendor":"Brother","product":"HL Printer","interfaces":[{"class_id":7,"driver":"usblp"}]},
 {"vendor_id":"0781","product_id":"5581","vendor":"SanDisk","product":"Ultra","interfaces":[{"class_id":8,"driver":"usb-storage"}]},
 {"vendor_id":"0bda","product_id":"8153","vendor":"Realtek","product":"USB GbE","interfaces":[{"class_id":255,"driver":"r8152"}]},
 {"vendor_id":"2357","product_id":"0601","vendor":"TP-Link","product":"UE300","interfaces":[{"class_id":255,"driver":"somenet"}]},
 {"vendor_id":"05e3","product_id":"0610","vendor":"Genesys","product":"Hub","interfaces":[{"class_id":9,"driver":"hub"}]},
 {"vendor_id":"1d6b","product_id":"0002","vendor":"Linux","product":"root hub","interfaces":[{"class_id":9,"driver":"hub"}]},
 {"vendor_id":"0bda","product_id":"0129","vendor":"Realtek","product":"Card reader","interfaces":[{"class_id":255,"driver":"rtsx_usb"}]},
 {"vendor_id":"abcd","product_id":"0001","vendor":"Acme","product":"Stick","interfaces":[{"class_id":8,"driver":"somedriver"}]},
 {"vendor_id":"abcd","product_id":"0002","vendor":"Acme","product":"Hidden disk","interfaces":[{"class_id":255,"driver":"somedriver"}]},
 {"vendor_id":"abcd","product_id":"0003","vendor":"Acme","product":"Reader","interfaces":[{"class_id":255,"driver":"ums-realtek"}]}]},
 "pci":{"devices":[
 {"pci_address":"0000:00:02.0","vendor_id":"8086","product_id":"4680","vendor":"Intel","product":"UHD 770","driver":"i915"},
 {"pci_address":"0000:00:17.0","vendor_id":"8086","product_id":"7ae2","vendor":"Intel","product":"SATA","driver":"ahci"},
 {"pci_address":"0000:00:1c.0","vendor_id":"8086","product_id":"7ab8","vendor":"Intel","product":"Bridge","driver":"pcieport"},
 {"pci_address":"0000:01:00.0","vendor_id":"10de","product_id":"2504","vendor":"NVIDIA","product":"GA106","driver":"nvidia"},
 {"pci_address":"0000:01:00.1","vendor_id":"10de","product_id":"228e","vendor":"NVIDIA","product":"GA106 Audio","driver":"snd_hda_intel"},
 {"pci_address":"0000:03:00.0","vendor_id":"1002","product_id":"73ff","vendor":"AMD","product":"Radeon","driver":"amdgpu"},
 {"pci_address":"0000:03:00.1","vendor_id":"1002","product_id":"ab28","vendor":"AMD","product":"Radeon Audio","driver":"snd_hda_intel"},
 {"pci_address":"0000:04:00.0","vendor_id":"10ec","product_id":"8168","vendor":"Realtek","product":"RTL8111","driver":"r8169"},
 {"pci_address":"0000:05:00.0","vendor_id":"1912","product_id":"0015","vendor":"Renesas","product":"USB 3.0","driver":"xhci_hcd"},
 {"pci_address":"0000:06:00.0","vendor_id":"1912","product_id":"0016","vendor":"Renesas","product":"USB 3.0 b","driver":"xhci_hcd"},
 {"pci_address":"0000:07:00.0","vendor_id":"1002","product_id":"1111","vendor":"AMD","product":"Card N","driver":"amdgpu"},
 {"pci_address":"0000:07:00.1","vendor_id":"8086","product_id":"1502","vendor":"Intel","product":"NIC","driver":"e1000e"},
 {"pci_address":"0000:08:00.0","vendor_id":"1002","product_id":"2222","vendor":"AMD","product":"Card D","driver":"amdgpu"},
 {"pci_address":"0000:08:00.1","vendor_id":"144d","product_id":"a808","vendor":"Samsung","product":"NVMe","driver":"nvme"},
 {"pci_address":"0000:0a:00.0","vendor_id":"1002","product_id":"ab29","vendor":"AMD","product":"Audio B","driver":"snd_hda_intel"},
 {"pci_address":"0000:0a:00.1","vendor_id":"1002","product_id":"3333","vendor":"AMD","product":"Card B","driver":"amdgpu"},
 {"pci_address":"0000:0b:00.0","vendor_id":"1002","product_id":"4444","vendor":"AMD","product":"Card C","driver":"amdgpu"},
 {"pci_address":"0000:0c:00.0","vendor_id":"1002","product_id":"5555","vendor":"AMD","product":"Card V","driver":"amdgpu"},
 {"pci_address":"0000:0d:00.0","vendor_id":"1002","product_id":"6666","vendor":"AMD","product":"Card A","driver":"amdgpu"},
 {"pci_address":"0000:00:1f.0","vendor_id":"8086","product_id":"7a04","vendor":"Intel","product":"LPC","driver":"-"},
 {"pci_address":"0000:00:1f.3","vendor_id":"8086","product_id":"7ad0","vendor":"Intel","product":"Audio","driver":"snd_hda_intel"},
 {"pci_address":"0000:00:1f.4","vendor_id":"8086","product_id":"7aa3","vendor":"Intel","product":"SMBus","driver":"i801_smbus"},
 {"pci_address":"0000:0e:00.0","vendor_id":"1002","product_id":"7777","vendor":"AMD","product":"Card F","driver":"amdgpu"},
 {"pci_address":"0000:0d:00.1","vendor_id":"1002","product_id":"ab2a","vendor":"AMD","product":"Audio A","driver":"snd_hda_intel"}]}}
JSON
cat > "$FX/instances.json" <<'JSON'
[{"name":"vm1","type":"virtual-machine","status":"Stopped","devices":{},"expanded_devices":{"root":{"type":"disk","path":"/"}}},
 {"name":"vm2","type":"virtual-machine","status":"Stopped",
  "devices":{"card":{"type":"gpu","gputype":"physical","pci":"0000:03:00.0"},"card-f1":{"type":"pci","address":"0000:03:00.1"}},
  "expanded_devices":{"card":{"type":"gpu","gputype":"physical","pci":"0000:03:00.0"},"card-f1":{"type":"pci","address":"0000:03:00.1"}}},
 {"name":"web","type":"container","status":"Running","devices":{"gpu":{"type":"gpu","pci":"01:00.0"}},
  "expanded_devices":{"gpu":{"type":"gpu","pci":"01:00.0"},"eth0":{"type":"nic"}}},
 {"name":"cups","type":"virtual-machine","status":"Running",
  "devices":{"printer":{"type":"usb","vendorid":"04f9","productid":"0042"},"data":{"type":"disk","source":"/x","path":"/data"}},
  "expanded_devices":{"printer":{"type":"usb","vendorid":"04f9","productid":"0042"},"data":{"type":"disk","source":"/x","path":"/data"},
    "prof-usb":{"type":"usb","vendorid":"1111","productid":"2222"}}},
 {"name":"cam","type":"container","status":"Running","devices":{"gpu":{"type":"gpu","pci":"0b:00.0"}},"expanded_devices":{"gpu":{"type":"gpu","pci":"0b:00.0"}}},
 {"name":"gvm","type":"virtual-machine","status":"Running","devices":{"gpu":{"type":"gpu","pci":"0c:00.0"},"snd":{"type":"pci","address":"0d:00.1"}},
  "expanded_devices":{"gpu":{"type":"gpu","pci":"0c:00.0"},"snd":{"type":"pci","address":"0d:00.1"}}},
 {"name":"fvm","type":"virtual-machine","status":"Frozen","devices":{"gpu":{"type":"gpu","pci":"0e:00.0"}},"expanded_devices":{"gpu":{"type":"gpu","pci":"0e:00.0"}}}]
JSON
cat > "$BIN/incus" <<'FAKE'
#!/usr/bin/env bash
echo "incus $*" >> "$LOG"
case "$1" in
  query)
    case "$2" in
      /1.0/resources) cat "$FX/resources.json" ;;
      "/1.0/instances?recursion=1") [ ! -e "$FX/failinst" ] || exit 1; cat "$FX/instances.json" ;;
      /1.0/instances/*) jq -e --arg n "${2#/1.0/instances/}" '.[] | select(.name == $n)' "$FX/instances.json" || exit 1 ;;
    esac ;;
  config)
    if [ "$2 $3" = "device get" ]; then
      jq -e -r --arg n "$4" --arg d "$5" '.[] | select(.name == $n) | .expanded_devices[$d].type // empty' "$FX/instances.json" | grep . || exit 1
    fi
    if [ "$2 $3" = "device remove" ] && [ -e "$FX/failremove" ]; then exit 1; fi ;;
  start) [ ! -e "$FX/failstart" ] || exit 1 ;;
  exec) echo "render:x:105:" ;;
esac
exit 0
FAKE
chmod +x "$BIN/incus"
export PATH=$BIN:$PATH
D="bash $SCRIPTS/ct-device.sh"

hwv() {   # hwv <id> <field>: one field of one --hardware line
  $D --hardware | awk -F'\t' -v k="$1" -v n="$2" '$2 == k { print $n }'
}
emptyfields() {   # lines of stdin with an empty tab-separated field
  awk -F'\t' '{ for (i = 1; i <= NF; i++) if ($i == "") { print; break } }'
}

echo "-- --hardware"
out=$($D --hardware)
check_eq "every line has 11 fields" "" "$(awk -F'\t' 'NF != 11' <<<"$out")"
check_eq "no empty field" "" "$(emptyfields <<<"$out")"
check_eq "devices: 9 usb, 10 gpu, 12 pci (no hub, root hub or bridge)" "usb 9 gpu 10 pci 12" \
  "usb $(grep -c '^usb' <<<"$out") gpu $(grep -c '^gpu' <<<"$out") pci $(grep -c '^pci' <<<"$out")"
check_eq "order: usb, gpu, pci" "usb gpu pci" "$(cut -f1 <<<"$out" | uniq | paste -sd' ')"
check_eq "a USB device is counted per vendor:product" "2" "$(hwv 046d:c52b 11)"
check_eq "boot display" "boot-display" "$(hwv 0000:00:02.0 8)"
check_eq "the host's NVIDIA card" "nvidia-host" "$(hwv 0000:01:00.0 8)"
check_eq "disk controller" "host-disk" "$(hwv 0000:00:17.0 8)"
check_eq "network card" "host-network" "$(hwv 0000:04:00.0 8)"
check_eq "shared IOMMU group" "group-shared" "$(hwv 0000:05:00.0 8)"
check_eq "a free card takes a VM" "ok" "$(hwv 0000:03:00.0 8)"
check_eq "the iommu group is shown" "14" "$(hwv 0000:03:00.0 7)"
check_eq "container: NVIDIA goes through a recipe" "nvidia-recipe" "$(hwv 0000:01:00.0 9)"
check_eq "container: a free card" "ok" "$(hwv 0000:03:00.0 9)"
check_eq "container: pci is VM only" "vm-only" "$(hwv 0000:03:00.1 9)"
check_eq "usb storage is refused" "host-disk" "$(hwv 0781:5581 8)"
check_eq "a USB card reader (rtsx_usb) is a host disk" "host-disk" "$(hwv 0bda:0129 8)"
check_eq "a USB mass-storage interface (class 8) is a host disk" "host-disk" "$(hwv abcd:0001 8)"
check_eq "a USB device with a block device below it is a host disk, VM" "host-disk" "$(hwv abcd:0002 8)"
check_eq "a USB device with a block device below it is a host disk, container" "host-disk" "$(hwv abcd:0002 9)"
check_eq "a USB card reader (ums-*) is a host disk" "host-disk" "$(hwv abcd:0003 8)"
check_eq "the SMBus controller is host-system" "host-system" "$(hwv 0000:00:1f.4 8)"
check_eq "an audio function next to an LPC bridge is host-system" "host-system" "$(hwv 0000:00:1f.3 8)"
check_eq "a USB network adapter (known driver) is a host network card, VM" "host-network" "$(hwv 0bda:8153 8)"
check_eq "a USB network adapter (known driver) is a host network card, container" "host-network" "$(hwv 0bda:8153 9)"
check_eq "a USB network adapter (interface below it in sysfs), VM" "host-network" "$(hwv 2357:0601 8)"
check_eq "a USB network adapter (interface below it in sysfs), container" "host-network" "$(hwv 2357:0601 9)"
check_eq "the sibling of the host's NVIDIA card is refused too" "nvidia-host" "$(hwv 0000:01:00.1 8)"
check_eq "a card with a network function" "host-network" "$(hwv 0000:07:00.0 8)"
check_eq "a card with a disk controller function" "host-disk" "$(hwv 0000:08:00.0 8)"
check_eq "a function next to the boot display" "boot-display" "$(hwv 0000:0a:00.0 8)"
check_eq "used by: gpu" "web" "$(hwv 0000:01:00.0 10)"
check_eq "used by: usb" "cups" "$(hwv 04f9:0042 10)"
check_eq "usb driver" "usblp" "$(hwv 04f9:0042 6)"
mv "$SYS/kernel/iommu_groups" "$SYS/iommu_groups.off"; mkdir "$SYS/kernel/iommu_groups"
check_eq "no IOMMU groups at all" "no-iommu" "$(hwv 0000:03:00.0 8)"
check_out "the table warns about it" "IOMMU is off" $D --hardware --table
rmdir "$SYS/kernel/iommu_groups"; mv "$SYS/iommu_groups.off" "$SYS/kernel/iommu_groups"
check_out "the table has a header" "^Kind +ID +Vendor +Product +Driver +VM +Container +Used by" $D --hardware --table

echo "-- <ct> --list"
out=$($D cups --list)
check_eq "cups: the plugged-in printer" "printer	usb	04f9:0042	yes	HL Printer	instance	-" "$(grep '^printer' <<<"$out")"
check_eq "cups: a profile device that is not plugged in" "prof-usb	usb	1111:2222	no	-	profile	-" "$(grep '^prof-usb' <<<"$out")"
check_eq "cups: disks are not listed" "2" "$(wc -l <<<"$out" | tr -d ' ')"
out=$($D vm2 --list)
check_eq "vm2: the card" "card	gpu	0000:03:00.0	yes	Radeon	instance	-" "$(grep '^card	' <<<"$out")"
check_eq "vm2: its audio function belongs to the card" "card-f1	pci	0000:03:00.1	yes	Radeon Audio	instance	card" "$(grep '^card-f1' <<<"$out")"
check_eq "web: gpu id is normalised" "gpu	gpu	0000:01:00.0	yes	GA106	instance	-" "$($D web --list)"
check_eq "no empty field in --list" "" "$(emptyfields <<<"$out")"
check_out "list --table has a header" "^Device +Kind +ID +Plugged in +Product +From" $D vm2 --list --table
check_out "an unknown instance" "There is no instance called 'nope'" $D nope --list

echo "-- --add (dry run)"
out=$($D vm1 --add usb 046D:C52B --dry-run 2>&1)
check_out "usb into a VM" "^  incus config device add vm1 usb-046d-c52b usb vendorid=046d productid=c52b required=false" echo "$out"
check_out "a keyboard-class device warns" "^warn: the server lets go of it while the VM runs" echo "$out"
check_out "usb taken by another instance" "04f9:0042 is already passed to cups\. Remove it there first: hs ct cups device remove" $D vm1 --add usb 04f9:0042 --dry-run
check_out "usb storage is refused" "disks hang on it" $D vm1 --add usb 0781:5581 --dry-run
out=$($D vm1 --add usb 1234:5678 --dry-run 2>&1)
check_out "usb not plugged in is allowed with a note" "^note: not plugged in now" echo "$out"
out=$($D vm1 --add gpu 03:00.0 --dry-run 2>&1)
check_out "gpu into a stopped VM: the gpu line" "^  incus config device add vm1 gpu-03-00-0 gpu gputype=physical pci=0000:03:00.0" echo "$out"
check_out "the audio function goes along" "^  incus config device add vm1 gpu-03-00-0-f1 pci address=0000:03:00.1" echo "$out"
check_out "a danger line" "^danger: 0000:03:00.0 \(Radeon\) is taken from the server while vm1 runs" echo "$out"
check_out "the word to type is the PCI address" "^confirm: 0000:03:00.0$" echo "$out"
check_out "the sibling is a step" "^step: also pass 0000:03:00.1" echo "$out"
check_eq "no stop for a stopped VM" "" "$(grep 'incus stop' <<<"$out" || true)"
out=$($D cups --add gpu 0000:03:00.0 --dry-run 2>&1)
check_out "running VM: stop first" "^  incus stop cups" echo "$out"
check_out "running VM: start after" "^  incus start cups" echo "$out"
check_out "running VM: the warning" "^warn: the VM stops and starts again" echo "$out"
check_out "gpu into the host's NVIDIA card: the reason, not the running container" "NVIDIA driver and the containers use this card" $D vm1 --add gpu 01:00.0 --dry-run
check_eq "the NVIDIA card is not planned" "1" "$($D vm1 --add gpu 01:00.0 --dry-run >/dev/null 2>&1; echo $?)"
check_out "the audio function of the NVIDIA card is refused too" "01:00.1 cannot be passed in: the server's NVIDIA driver" $D vm1 --add pci 01:00.1 --dry-run
check_eq "the audio function of the NVIDIA card plans nothing" "" "$($D vm1 --add pci 01:00.1 --dry-run 2>/dev/null || true)"
check_out "a sibling that is a network card" "network card of the server" $D vm1 --add gpu 07:00.0 --dry-run
check_out "a sibling that is a disk controller" "disks hang on it" $D vm1 --add gpu 08:00.0 --dry-run
check_out "a sibling that is the boot display" "screen" $D vm1 --add pci 0a:00.0 --dry-run
check_out "a sibling used by a running VM" "0000:0d:00.1 is in use by the running instance gvm" $D vm1 --add gpu 0d:00.0 --dry-run
check_out "a card used by a running container blocks a VM" "0000:0b:00.0 is in use by the running instance cam" $D vm1 --add gpu 0b:00.0 --dry-run
check_out "a USB network adapter into a VM" "network card of the server" $D vm1 --add usb 0bda:8153 --dry-run
check_out "a USB network adapter into a container" "network card of the server" $D web --add usb 2357:0601 --dry-run
rc=0; out=$($D web --add gpu 0b:00.0 --dry-run 2>&1) || rc=$?
check_eq "a card a running container uses can go into another container" 0 "$rc"
check_out "... as a plain gpu line" "^  incus config device add web gpu-0b-00-0 gpu gputype=physical pci=0000:0b:00.0" echo "$out"
check_eq "... without a warning or refusal" "" "$(grep -i 'in use\|^warn: cam' <<<"$out" || true)"
check_out "a card a running VM uses blocks a container" "0000:0c:00.0 is in use by the running instance gvm" $D web --add gpu 0c:00.0 --dry-run
check_out "pci into a container" "only a VM can take a PCI device" $D web --add pci 03:00.1 --dry-run
check_out "unknown PCI address" "There is no PCI device 0000:09:00.0 on this server" $D vm1 --add gpu 09:00.0 --dry-run
check_out "a PCI device in a shared group" "also holds 0000:06:00.0" $D vm1 --add pci 05:00.0 --dry-run
check_out "a boot display" "screen" $D vm1 --add gpu 00:02.0 --dry-run
check_out "the name is taken" "'cups' already has a device called 'printer'" $D cups --add usb 1234:5678 --name printer --dry-run
check_out "a bad usb id" "invalid USB id" $D vm1 --add usb 04f9:004 --dry-run
check_out "a bad name" "invalid device name" $D vm1 --add usb 1234:5678 --name Bad --dry-run
out=$($D web --add gpu 03:00.0 --dry-run 2>&1)
check_out "gpu into a container: the render group id" "^  incus config device add web gpu-03-00-0 gpu gputype=physical pci=0000:03:00.0 gid=105" echo "$out"
check_eq "a container gpu add asks for no typed word" "" "$(grep '^confirm:' <<<"$out" || true)"
: > "$LOG"
$D vm1 --add usb 1234:5678 --dry-run >/dev/null 2>&1
check_eq "a dry run changes nothing" "" "$(grep 'config device add\|config device remove\|incus stop\|incus start' "$LOG" || true)"

check_out "a bridge sibling in the slot is refused" "00:1f.3 cannot be passed in: it is a part of the server itself" $D vm1 --add pci 00:1f.3 --dry-run
check_eq "... and nothing is planned" "" "$($D vm1 --add pci 00:1f.3 --dry-run 2>&1 | grep '^  incus\|^step:\|^confirm:' || true)"
check_out "the SMBus controller is refused" "00:1f.4 cannot be passed in: it is a part of the server itself" $D vm1 --add pci 00:1f.4 --dry-run
check_out "a bridge itself is refused" "00:1c.0 cannot be passed in: it is a part of the server itself" $D vm1 --add pci 00:1c.0 --dry-run
check_out "the LPC bridge itself is refused" "00:1f.0 cannot be passed in: it is a part of the server itself" $D vm1 --add pci 00:1f.0 --dry-run
check_out "a USB hub is refused" "05e3:0610 cannot be passed in: it is a part of the server itself" $D vm1 --add usb 05e3:0610 --dry-run
check_out "a USB root hub is refused" "1d6b:0002 cannot be passed in: it is a part of the server itself" $D vm1 --add usb 1d6b:0002 --dry-run
check_out "a USB card reader is refused" "disks hang on it" $D vm1 --add usb 0bda:0129 --dry-run
check_out "a USB class-8 device is refused" "disks hang on it" $D vm1 --add usb abcd:0001 --dry-run
check_out "a USB disk with a block device below it is refused" "disks hang on it" $D vm1 --add usb abcd:0002 --dry-run
check_out "a card a frozen VM holds counts as running" "0000:0e:00.0 is in use by the running instance fvm" $D vm1 --add gpu 0e:00.0 --dry-run
check_out "gpu needs a display function" "03:00.1 is not a graphics function" $D vm1 --add gpu 03:00.1 --dry-run
check_out "... the hint names pci" "hs ct vm1 device add pci 0000:03:00.1" $D vm1 --add gpu 03:00.1 --dry-run
touch "$FX/failinst"
check_out "no instance list: --hardware aborts" "Could not read the instances from Incus" $D --hardware
check_eq "no instance list: --add plans nothing" "" "$($D vm1 --add usb 1234:5678 --dry-run 2>&1 | grep '^  incus\|^step:' || true)"
rm -f "$FX/failinst"

echo "-- --add (real, the VM does not start)"
: > "$LOG"; touch "$FX/failstart"
rc=0; out=$($D cups --add gpu 03:00.0 --yes 2>&1) || rc=$?
rm -f "$FX/failstart"
check_eq "exit 1" 1 "$rc"
check_out "the message" "The VM did not start with 0000:03:00.0; it runs again without it" echo "$out"
check "the card was added" grep -q '^incus config device add cups gpu-03-00-0 gpu' "$LOG"
check "the card was taken out again" grep -q '^incus config device remove cups gpu-03-00-0$' "$LOG"
check "the audio function was taken out again" grep -q '^incus config device remove cups gpu-03-00-0-f1$' "$LOG"
check_eq "the VM was started again" 2 "$(grep -c '^incus start cups' "$LOG")"
: > "$LOG"
check_out "a real add says so" "Passed 1234:5678 to 'vm1'" $D vm1 --add usb 1234:5678

echo "-- --remove"
out=$($D vm2 --remove card --dry-run 2>&1)
check_out "step line" "^step: give 0000:03:00.0 back to the server" echo "$out"
check_out "the device" "^  incus config device remove vm2 card$" echo "$out"
check_out "its sibling" "^  incus config device remove vm2 card-f1$" echo "$out"
check_out "a profile device" "'prof-usb' comes from the profile" $D cups --remove prof-usb --dry-run
check_out "a disk is not ours" "not a passed-through device; storage goes with hs ct cups storage remove" $D cups --remove data --dry-run
check_out "an unknown device" "'vm1' has no device called 'nothing'" $D vm1 --remove nothing --dry-run
: > "$LOG"; $D vm2 --remove card >/dev/null 2>&1
check "a real remove" grep -q '^incus config device remove vm2 card-f1$' "$LOG"

echo "-- --remove (Incus fails after the stop)"
: > "$LOG"; touch "$FX/failremove"
rc=0; out=$($D gvm --remove gpu 2>&1) || rc=$?
rm -f "$FX/failremove"
check_eq "exit 1" 1 "$rc"
check_out "the message" "Incus could not remove the device 'gpu'" echo "$out"
check "the VM was stopped" grep -q '^incus stop gvm' "$LOG"
check "the VM was started again" grep -q '^incus start gvm' "$LOG"
finish
