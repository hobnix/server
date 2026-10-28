#!/usr/bin/env bash
# The installer ISO's wizard (scripts/install-wizard.sh, docs/PLAN-modular-core.md step 10a): the plan, the files it writes and what it refuses.
# No disk is touched: HS_INSTALL_SKIP_DISK=1 leaves out partitioning, mounting and nixos-install; the target is a temporary folder.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test HS_PYTHON=python3 PYTHONUTF8=1 HS_INSTALL_SKIP_DISK=1
W="bash $SCRIPTS/install-wizard.sh"
KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItestkey you@pc'
REPO=$WORK/repo; mkdir -p "$REPO/presets" "$REPO/scripts"
cp "$ROOT/machine.toml.example" "$REPO/"; cp "$ROOT"/presets/*.toml "$REPO/presets/"; mkdir -p "$REPO/config"; cp "$ROOT/config/schema.toml" "$REPO/config/"
printf 'x' > "$REPO/install.nix"; mkdir -p "$REPO/.git" "$REPO/node_modules"; printf 'x' > "$REPO/.git/HEAD"; printf 'x' > "$REPO/node_modules/junk"
T=$WORK/target

echo "-- the plan (dry run)"
out=$($W --dry-run --disk sda --hostname myserver --key "$KEY" --timezone Europe/Vienna --preset minimal --nic eth0 --smb-allow "10.0.0.0/24 127.0.0.1" --target "$T" --repo "$REPO" 2>&1)
check_out "it names the disk as erased" "/dev/sda \(erased\)" echo "$out"
check_out "and the layout" "1 GB boot, 8 GB swap" echo "$out"
check_out "and the server name" "myserver" echo "$out"
check_out "a dry run says nothing changed" "Dry run" echo "$out"
check "and writes nothing" test ! -e "$T/etc/nixos"

echo "-- the files"
$W --disk sda --hostname myserver --key "$KEY" --timezone Europe/Vienna --preset minimal --nic eth0 --smb-allow "10.0.0.0/24 127.0.0.1" --target "$T" --repo "$REPO" >/dev/null 2>&1 || true
M=$T/etc/nixos/machine.toml
get() { HS_MACHINE_FILE=$M python3 "$SCRIPTS/machine-toml.py" get "$M" "$1" --json 2>/dev/null; }
check "the repository is copied" test -f "$T/etc/nixos/install.nix"
check "without .git and node_modules" bash -c '[ ! -e "$1/.git" ] && [ ! -e "$1/node_modules" ]' _ "$T/etc/nixos"
check_eq "hostName" '"myserver"' "$(get hostName)"
check_eq "nic" '"eth0"' "$(get nic)"
check_eq "smbAllow" '"10.0.0.0/24 127.0.0.1"' "$(get smbAllow)"
check_eq "timeZone" '"Europe/Vienna"' "$(get timeZone)"
check_out "sshKeys holds the key" "AAAAC3NzaC1lZDI1NTE5AAAAItestkey" python3 -c "import sys;print(sys.argv[1])" "$(get sshKeys)"
check_out "hostId is a new 8-digit hex value (no CHANGEME)" '^"[0-9a-f]{8}"$' echo "$(get hostId)"
check "the preset was applied (runtime setting written)" test -f "$T/var/lib/hs/settings/backupNewShares"

echo "-- what it refuses"
out=$($W --dry-run --disk sda --hostname "bad name" --key "$KEY" --target "$T" --repo "$REPO" 2>&1 || true)
check_out "a server name with a space" "not a usable server name" echo "$out"
out=$($W --dry-run --disk sda --hostname ok --key "not-a-key" --target "$T" --repo "$REPO" 2>&1 || true)
check_out "something that is not a public key" "does not look like a public SSH key" echo "$out"
out=$($W --dry-run --disk "sda;rm" --hostname ok --key "$KEY" --target "$T" --repo "$REPO" 2>&1 || true)
check_out "a disk name with odd characters" "is not a disk name" echo "$out"
out=$($W --dry-run --disk sda --hostname ok --key "$KEY" --preset nonsense --target "$T" --repo "$REPO" 2>&1 || true)
check_out "an unknown preset" "No preset called" echo "$out"
out=$($W --dry-run --hostname ok --key "$KEY" --target "$T" --repo "$REPO" 2>&1 </dev/null || true)
check_out "no disk and no terminal: nothing is chosen on a guess" "No terminal and no --disk" echo "$out"
out=$($W --dry-run --role nonsense --disk sda --hostname ok --key "$KEY" --target "$T" --repo "$REPO" 2>&1 || true)
check_out "an unknown role" "role is homeserver, edge or minimal" echo "$out"

echo "-- the role edge (a public VPS)"
out=$($W --dry-run --role edge --bios --disk sda --hostname edge1 --key "$KEY" --target "$WORK/edge-dry" --repo "$REPO" 2>&1)
check_out "the plan names the role" "Role .*edge" echo "$out"
check_out "and a BIOS layout with GRUB on the disk" "BIOS boot.*GRUB on /dev/sda" echo "$out"
if grep -q "Samba networks\|Network card" <<<"$out"; then fail "an edge node asks nothing about network cards or Samba"; else pass "an edge node asks nothing about network cards or Samba"; fi
TE=$WORK/edge-target
$W --role edge --bios --disk sda --hostname edge1 --key "$KEY" --timezone Europe/Berlin --target "$TE" --repo "$REPO" >/dev/null 2>&1 || true
M=$TE/etc/nixos/machine.toml
check_eq "role" '"edge"' "$(get role)"
if [ "$(uname -o 2>/dev/null)" = Msys ]; then skip "bootDevice: Git Bash rewrites /dev/sda in arguments (Linux only)"
else check_eq "bootDevice (GRUB, BIOS)" '"/dev/sda"' "$(get bootDevice)"; fi
check_eq "the preset of the same name was applied: the edge capabilities" '["tailscale","edge-mail","edge-ports","edge-watcher","edge-status"]' "$(get capabilities | tr -d ' ')"
check_eq "and the Tailscale tag" '["tag:vps"]' "$(get tailscaleTags | tr -d ' ')"
check_eq "no ZFS host id for a node without pools" "" "$(get hostId)"
check_eq "and no network card or Samba networks" "" "$(get nic)$(get smbAllow)"
check_eq "the name and zone are there" '"edge1" "Europe/Berlin"' "$(get hostName) $(get timeZone)"
check "machine.toml of an edge node passes hs config check without hostId, nic, smbAllow and vlans" bash -c 'out=$(python3 "$1/machine-toml.py" check "$2/machine.toml.example" "$3" 2>&1); ! grep -q "^error" <<<"$out"' _ "$SCRIPTS" "$ROOT" "$M"
finish
