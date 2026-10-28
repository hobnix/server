#!/usr/bin/env bash
# help: install a new server from the installer ISO: the OS disk, name, SSH key, preset (run on the ISO as root)
# help.de: einen neuen Server vom Installer-Stick einrichten: Systemplatte, Name, SSH-Schlüssel, Vorlage (auf dem Stick als root)
# args: [--role homeserver|edge|minimal] [--disk <name>] [--hostname <name>] [--key-file <file>] [--timezone <zone>] [--preset <name>] [--confirm-disk <name>] [--bios] [--dry-run]
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/machine.sh"

# The terminal installer on the ISO (docs/PLAN-modular-core.md step 10a): it replaces the manual steps 2.1 to 2.7 of the Homeserver guide.
# It touches ONE disk (the one you pick and then type the name of), leaves every other disk alone, puts a copy of this repository
# into /etc/nixos of the new system, writes machine.toml, applies a preset and runs nixos-install with install.nix. The pools come
# afterwards (hs pool), then `hs rebuild` switches to the full configuration.
#
# The role: homeserver (the default: storage, Incus, Samba, backup), edge (a public VPS with the edge capabilities, preset edge: no pools, no
# hostId, no network card or Samba networks to ask; on a machine without UEFI it lays out a BIOS boot partition and puts GRUB on the disk: machine.toml bootDevice)
# or minimal (only the base). The role is written to machine.toml; a preset of the same name is the default.
#
# Everything it asks can be given up front (the options above, plus --nic, --smb-allow, --key <line>, --target <dir>, --repo <dir>).
# An unattended run needs --disk and --confirm-disk <the same name>: without a terminal nothing is erased on a guess.
# Test knobs: HS_INSTALL_SKIP_DISK=1 (no partitioning, no mounting, no nixos-install: only the files), HS_INSTALL_PASSWORD (the adminuser
# password without asking), HS_PRESETS_DIR, HS_PYTHON.

disk=""; hostname_=""; keyfile=""; key=""; tz=""; preset=""; confirm_disk=""; nic=""; smb=""; dry=false; role=""; bios=false
target=${HS_INSTALL_TARGET:-/mnt}
repo=""
while [ $# -gt 0 ]; do
  case "$1" in
    --role) role=${2:?}; shift 2 ;;
    --bios) bios=true; shift ;;
    --disk) disk=${2:?}; shift 2 ;;
    --hostname) hostname_=${2:?}; shift 2 ;;
    --key-file) keyfile=${2:?}; shift 2 ;;
    --key) key=${2:?}; shift 2 ;;
    --timezone) tz=${2:?}; shift 2 ;;
    --preset) preset=${2:?}; shift 2 ;;
    --confirm-disk) confirm_disk=${2:?}; shift 2 ;;
    --nic) nic=${2:?}; shift 2 ;;
    --smb-allow) smb=${2:?}; shift 2 ;;
    --target) target=${2:?}; shift 2 ;;
    --repo) repo=${2:?}; shift 2 ;;
    --dry-run) dry=true; shift ;;
    *) say "usage: hs-install [--role homeserver|edge|minimal] [--disk <name>] [--hostname <name>] [--key-file <file>] [--timezone <zone>] [--preset <name>] [--confirm-disk <name>] [--dry-run]"; exit 1 ;;
  esac
done
skip=${HS_INSTALL_SKIP_DISK:-}
py=${HS_PYTHON:-python3}
# the repository to copy: the one this script belongs to (on the ISO: /etc/hs-installer)
[ -n "$repo" ] || repo=$(cd "$here/.." && pwd)
tty=false; if [ -t 0 ] && [ -t 1 ]; then tty=true; fi

# ---- the role
if [ -z "$role" ]; then
  if $tty; then role=$(choose "What is this server? (homeserver: storage, containers, shares; edge: a public VPS; minimal: only the base)" homeserver edge minimal) || role=homeserver; else role=homeserver; fi
fi
case "$role" in homeserver|edge|minimal) ;; *) fail "$(t "The role is homeserver, edge or minimal, not '%s'." "$role")" ;; esac

step "Installer"
if [ -z "$skip" ] && ! $dry; then
  [ "$(id -u)" = 0 ] || fail "Run this as root (sudo -i)."
  # on an installed server this must never run: the stick is mounted at /iso, a server is not
  findmnt -rn /iso >/dev/null 2>&1 || fail "This is not the installer stick (nothing is mounted at /iso), so nothing is installed. The installer runs from the stick."
  if [ ! -d /sys/firmware/efi ]; then
    # a cloud VPS often boots with BIOS: an edge node then gets GRUB (a BIOS boot partition); the other roles need UEFI
    [ "$role" = edge ] || fail "This was not started in UEFI mode (ls /sys/firmware/efi shows nothing). Boot the stick in UEFI mode."
    bios=true
  fi
fi

# ---- the disk
disks() {   # name<TAB>size<TAB>transport<TAB>model, without loop devices, optical drives and the stick itself
  local iso_src iso_disk=""
  iso_src=$(findmnt -no SOURCE /iso 2>/dev/null || true)
  [ -z "$iso_src" ] || iso_disk=$(lsblk -no PKNAME "$iso_src" 2>/dev/null | head -n1 || true)
  lsblk -dn -e 7,11 -o NAME,SIZE,TRAN,MODEL 2>/dev/null | awk -v iso="$iso_disk" '$1 != iso { n = $1; s = $2; t = ($3 == "" || NF < 3) ? "-" : $3; $1 = $2 = ""; sub(/^ +/, ""); print n "\t" s "\t" t "\t" $0 }' || true
}
if [ -z "$disk" ]; then
  $tty || fail "No terminal and no --disk: nothing is chosen on a guess."
  step "Which disk is for the system?"
  note "Only this disk is erased. The data disks stay as they are, but check the name twice."
  { thead 'Name' 'Size' 'Bus' 'Model'; disks; } | table
  disk=$(ask "Name of the system disk (e.g. sda or nvme0n1)" "")
fi
disk=${disk#/dev/}
[[ "$disk" =~ ^[a-zA-Z0-9]+$ ]] || fail "$(t "'%s' is not a disk name." "$disk")"
if [ -z "$skip" ]; then
  [ -b "/dev/$disk" ] || fail "$(t "There is no disk /dev/%s." "$disk")"
  if lsblk -no MOUNTPOINTS "/dev/$disk" 2>/dev/null | grep -q .; then fail "$(t "/dev/%s has mounted parts (it may be the stick or a disk in use). Choose another." "$disk")"; fi
fi
case "$disk" in nvme*|mmcblk*) p="${disk}p" ;; *) p="$disk" ;; esac

# ---- the answers
valid_host() { [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,13}[a-zA-Z0-9])?$ ]]; }
if [ -z "$hostname_" ]; then
  defname=homeserver; [ "$role" = homeserver ] || defname=$role
  if $tty; then hostname_=$(ask "Name of the server (also in the Windows network, at most 15 characters)" "$defname"); else hostname_=$defname; fi
fi
valid_host "$hostname_" || fail "$(t "'%s' is not a usable server name (letters, digits, dashes; at most 15 characters)." "$hostname_")"

if [ -z "$key" ] && [ -n "$keyfile" ]; then key=$(sed -n '/^ssh-/{p;q;}' "$keyfile" 2>/dev/null || true); fi
if [ -z "$key" ]; then
  $tty || fail "No SSH key: give --key-file or --key."
  note "Paste the PUBLIC key of your PC (one line starting with ssh-ed25519 or ssh-rsa; on the PC: type ~/.ssh/id_ed25519.pub)."
  key=$(ask "SSH public key" "")
fi
case "$key" in ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-ssh-*\ *) ;; *) fail "That does not look like a public SSH key (it must start with ssh-ed25519, ssh-rsa ...)." ;; esac
case "$key" in *\"*|*\\*) fail "The key contains a quote or a backslash." ;; esac

if [ -z "$tz" ] && $tty; then tz=$(ask "Time zone (e.g. Europe/Vienna; empty = UTC)" ""); fi
[ -z "$tz" ] || [[ "$tz" =~ ^[A-Za-z0-9_+/-]+$ ]] || fail "$(t "'%s' is not a time zone." "$tz")"

presets() { PYTHONUTF8=1 HS_PRESETS_DIR="${HS_PRESETS_DIR:-$repo/presets}" "$py" "$here/preset.py" list en | cut -f1; }
if [ -z "$preset" ] && [ "$role" != homeserver ]; then preset=$role; fi   # the preset of the same name: edge, minimal
if [ -z "$preset" ]; then
  if $tty; then preset=$(choose "Preset (a ready-made list of choices; minimal changes nothing special)" $(presets)) || preset=minimal; else preset=minimal; fi
fi
presets | grep -qx -- "$preset" || fail "$(t "No preset called '%s'." "$preset")"

# the network card and the network of the PCs: from the route this installer itself uses
if [ "$role" != homeserver ]; then :   # no bridges, no Samba: nothing to ask
elif [ -z "$nic" ]; then nic=$(ip -o route show default 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i+1); exit } }' || true); fi
if [ "$role" != homeserver ]; then :
elif [ -z "$smb" ]; then
  cidr=$(ip -o -4 addr show dev "${nic:-lo}" 2>/dev/null | awk '{ print $4; exit }' || true)
  if [ -n "$cidr" ]; then smb=$("$py" -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)' "$cidr" 2>/dev/null || true); fi
  [ -z "$smb" ] || smb="$smb 127.0.0.1"
fi

# ---- the plan
step "The plan"
kv "System disk" "/dev/$disk (erased)"
if $bios; then kv "Layout" "1 MB BIOS boot, 8 GB swap, the rest for the system (ext4), GRUB on /dev/$disk"
else kv "Layout" "1 GB boot, 8 GB swap, the rest for the system (ext4)"; fi
kv "Role" "$role"
kv "Server name" "$hostname_"
kv "SSH key" "${key%% *} ... ${key##* }"
kv "Time zone" "${tz:-UTC (not set)}"
kv "Preset" "$preset"
if [ "$role" = homeserver ]; then
  kv "Network card" "${nic:-not found: from the example}"
  kv "Samba networks" "${smb:-from the example}"
fi
kv "Copy of this repository" "$target/etc/nixos"
if $dry; then note "Dry run: nothing was changed."; exit 0; fi

if [ -z "$skip" ]; then
  if [ -n "$confirm_disk" ]; then
    [ "$confirm_disk" = "$disk" ] || fail "$(t "--confirm-disk '%s' is not the disk '%s'." "$confirm_disk" "$disk")"
  else
    $tty || fail "Erasing a disk asks for its name: run this in a terminal, or add --confirm-disk $disk."
    warn "$(t "Everything on /dev/%s will be erased." "$disk")"
    typed=$(ask "$(t "Type the name of the disk to erase it (%s)" "$disk")" "")
    [ "$typed" = "$disk" ] || { note "Not the same name. Nothing was changed."; exit 1; }
  fi
fi

# ---- the password of adminuser
pw=${HS_INSTALL_PASSWORD:-}
if [ -z "$pw" ] && [ -z "$skip" ]; then
  $tty || fail "No terminal and no HS_INSTALL_PASSWORD: the password of adminuser cannot be asked."
  pw=$(ask_secret "Password of adminuser (for sudo; the SSH key is used to log in):")
  pw2=$(ask_secret "Once more:")
  [ -n "$pw" ] && [ "$pw" = "$pw2" ] || fail "The passwords are empty or not the same. Nothing was changed."
fi

# ---- disk
if [ -z "$skip" ]; then
  step "Partitioning /dev/$disk"
  parted -s "/dev/$disk" -- mklabel gpt
  if $bios; then
    parted -s "/dev/$disk" -- mkpart root ext4 2MB -8GB
    parted -s "/dev/$disk" -- mkpart swap linux-swap -8GB 100%
    parted -s "/dev/$disk" -- mkpart biosboot 1MB 2MB
    parted -s "/dev/$disk" -- set 3 bios_grub on
  else
    parted -s "/dev/$disk" -- mkpart root ext4 1GB -8GB
    parted -s "/dev/$disk" -- mkpart swap linux-swap -8GB 100%
    parted -s "/dev/$disk" -- mkpart ESP fat32 1MB 1GB
    parted -s "/dev/$disk" -- set 3 esp on
  fi
  udevadm settle 2>/dev/null || true
  ok "GPT with root, swap and boot"
  step "Formatting and mounting"
  mkfs.ext4 -q -F -L nixos "/dev/${p}1"
  mkswap -L swap "/dev/${p}2" >/dev/null
  $bios || mkfs.fat -F 32 -n boot "/dev/${p}3" >/dev/null
  udevadm settle 2>/dev/null || true
  mount /dev/disk/by-label/nixos "$target"
  mkdir -p "$target/boot"
  $bios || mount -o umask=077 /dev/disk/by-label/boot "$target/boot"
  swapon "/dev/${p}2"
  ok "Mounted at $target"
  nixos-generate-config --root "$target" >/dev/null
  ok "hardware-configuration.nix written"
fi

# ---- the repository and machine.toml
step "Configuration"
etc=$target/etc/nixos
mkdir -p "$etc"
# the whole repository (install.nix and configuration.nix read config/, capabilities/, pkgs/, web/ ...), not the .git folder or build leftovers
( cd "$repo" && tar -cf - --exclude=.git --exclude=node_modules --exclude=target --exclude=tests --exclude=__pycache__ --exclude='result*' . ) | ( cd "$etc" && tar -xf - )
cp "$etc/machine.toml.example" "$etc/machine.toml"
ok "A copy of the repository is in $etc"
export HS_MACHINE_FILE=$etc/machine.toml HS_STATE_DIR=${HS_STATE_DIR:-$target/var/lib/hs} HS_SETTINGS_DIR=${HS_SETTINGS_DIR:-$target/var/lib/hs/settings}
mkdir -p "$HS_STATE_DIR" "$HS_SETTINGS_DIR"
hostid=$(head -c4 /dev/urandom | od -A none -t x1 | tr -d ' \n')
mset() { machine_set "$1" "$2" installer >/dev/null || fail "$(t "'%s' could not be written to machine.toml." "$1")"; }
[ "$role" != homeserver ] || mset hostId "\"$hostid\""   # ZFS needs it; the other roles have no pools
[ "$role" = homeserver ] || mset role "\"$role\""
! $bios || mset bootDevice "\"/dev/$disk\""
mset hostName "\"$hostname_\""
mset sshKeys "[ \"$key\" ]"
[ -z "$nic" ] || [ "$role" != homeserver ] || mset nic "\"$nic\""
[ -z "$smb" ] || [ "$role" != homeserver ] || mset smbAllow "\"$smb\""
[ -z "$tz" ] || mset timeZone "\"$tz\""
if [ "$role" != homeserver ]; then   # the example's pool and network lines mean nothing to a node without pools, bridges and Samba
  for k in hostId nic smbAllow vlans; do machine_unset "$k" installer >/dev/null || true; done
fi
ok "machine.toml: server name, SSH key, network card and the rest"
HS_PRESETS_DIR=${HS_PRESETS_DIR:-$etc/presets} bash "$here/preset.sh" apply "$preset" --yes >/dev/null || fail "The preset could not be applied."
ok "$(t "Preset '%s' applied (only what was not set yet)" "$preset")"

# ---- install
if [ -z "$skip" ]; then
  step "Installing NixOS (a few minutes)"
  # the log goes to the stick's /tmp: the new system has no /root yet at this point
  NIXOS_CONFIG="$etc/install.nix" nixos-install --no-root-passwd >/tmp/hs-nixos-install.log 2>&1 || {
    tail -n 15 /tmp/hs-nixos-install.log | sed 's/^/      /' >&2
    fail "$(t 'nixos-install failed. The whole log: %s' /tmp/hs-nixos-install.log)"
  }
  printf '%s\n' "adminuser:$pw" | nixos-enter --root "$target" -c 'chpasswd' >/dev/null
  ok "adminuser has its password"
fi

step "Done"
note "Take the stick out and reboot. Then, from your PC:  ssh adminuser@$hostname_.local   (or the address your router gave it)"
if [ "$role" = homeserver ]; then
  note "Next: create the pools (zpool create, as in section 3 of the Homeserver guide; the hs command only exists after the first nixos-rebuild switch), then sudo nixos-rebuild switch. The guide: docs/install.md."
else
  note "Next: fill the section \"Edge node\" of /etc/nixos/machine.toml, put the Tailscale auth key into /var/lib/hs/tailscale-authkey (mode 0600), then sudo nixos-rebuild switch. The guide: docs/operations.md."
fi
