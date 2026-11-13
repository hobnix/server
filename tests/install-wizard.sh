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
# the git checkout step must never reach the network in a test: an origin that does not exist means "no network"
export HS_INSTALL_ORIGIN=$WORK/no-such-origin HS_INSTALL_FETCH_TIMEOUT=20 HS_INSTALLER_VERSION_FILE=$WORK/no-such-version-file

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

echo "-- the git checkout in /etc/nixos (issue #396)"
G="git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c tag.gpgsign=false"
PUB=$WORK/published; mkdir -p "$PUB"
cp -r "$REPO"/. "$PUB"/; rm -rf "$PUB/.git" "$PUB/node_modules"; cp "$ROOT/.gitignore" "$PUB/"
mkdir -p "$PUB/tests" "$PUB/.claude"; echo t > "$PUB/tests/a.sh"; echo c > "$PUB/.claude/b"
( cd "$PUB" && git init -q -b develop && $G add -A && $G commit -q -m one && $G tag v0.1.0 && echo more > extra.txt && $G add extra.txt && $G commit -q -m two )
TAGC=$(git -C "$PUB" rev-parse v0.1.0); HEADC=$(git -C "$PUB" rev-parse HEAD)
# what the ISO carries: the published tree without .git, tests and .claude (a copy of the tagged commit)
ISO=$WORK/iso-tree; mkdir -p "$ISO"; git -C "$PUB" archive "$TAGC" | tar -x -C "$ISO"; rm -rf "$ISO/tests" "$ISO/.claude"
vf=$WORK/hs-installer-version; printf 'describe=v0.1.0\ncommit=%s\n' "$TAGC" > "$vf"
inst() {   # inst <target> [more options]: the install with its own target, the ISO tree and the version file (ORIGIN: another origin)
  local tg=$1; shift
  mkdir -p "$tg/etc/nixos"; echo "hw-sentinel" > "$tg/etc/nixos/hardware-configuration.nix"
  HS_INSTALL_ORIGIN=${ORIGIN:-$PUB} HS_INSTALLER_VERSION_FILE=$vf $W --disk sda --hostname gitbox --key "$KEY" --preset minimal --nic eth0 --smb-allow "10.0.0.0/24" --target "$tg" --repo "$ISO" "$@" 2>&1
}
out=$(HS_INSTALL_ORIGIN=$PUB HS_INSTALLER_VERSION_FILE=$vf $W --dry-run --disk sda --hostname gitbox --key "$KEY" --target "$WORK/g0" --repo "$ISO" 2>&1)
check_out "the plan names the git checkout and the tag" "Git checkout.*at v0.1.0" echo "$out"
check "a dry run makes no checkout" test ! -e "$WORK/g0/etc/nixos"
out=$(inst "$WORK/g1"); E=$WORK/g1/etc/nixos
check_out "it says the checkout is made" "is a git checkout of v0.1.0" echo "$out"
check_eq "HEAD is the commit of the ISO" "$TAGC" "$(git -C "$E" rev-parse HEAD)"
check_eq "the version is the tag" "v0.1.0" "$(git -C "$E" describe --tags --always)"
check_eq "HEAD is detached on a tag, like hs update on stable" "HEAD" "$(git -C "$E" rev-parse --abbrev-ref HEAD)"
check_eq "git status is clean: machine.toml and hardware-configuration.nix are ignored" "" "$(git -C "$E" status --porcelain)"
check "files the copy leaves out come back (tests)" test -f "$E/tests/a.sh"
check_eq "origin is the given url" "$PUB" "$(git -C "$E" remote get-url origin)"
check "the tags were fetched" git -C "$E" rev-parse -q --verify refs/tags/v0.1.0
check_eq "hardware-configuration.nix is untouched" "hw-sentinel" "$(cat "$E/hardware-configuration.nix")"
check_eq "machine.toml has the answers" '"gitbox"' "$(HS_MACHINE_FILE=$E/machine.toml python3 "$SCRIPTS/machine-toml.py" get "$E/machine.toml" hostName --json)"
check_eq "the version is also kept for a server without git" "v0.1.0" "$(cat "$E/.hobnix-version")"
check "the update channel sees the tag" bash -c 'cd "$1" && git tag --list "v[0-9]*" | grep -qx v0.1.0' _ "$E"

# a stick built from develop (not a tag): on the branch develop, tracking origin/develop
printf 'describe=v0.1.0-1-g%s\ncommit=%s\n' "${HEADC:0:7}" "$HEADC" > "$vf"
ISO2=$WORK/iso-tree2; mkdir -p "$ISO2"; git -C "$PUB" archive "$HEADC" | tar -x -C "$ISO2"; rm -rf "$ISO2/tests" "$ISO2/.claude"
ISO_SAVE=$ISO; ISO=$ISO2; out=$(inst "$WORK/g2"); ISO=$ISO_SAVE; E=$WORK/g2/etc/nixos
check_eq "from develop: the branch is develop" "develop" "$(git -C "$E" rev-parse --abbrev-ref HEAD)"
check_eq "tracking origin/develop" "origin/develop" "$(git -C "$E" rev-parse --abbrev-ref 'develop@{u}')"
check_eq "and clean" "" "$(git -C "$E" status --porcelain)"

echo "-- no network, or a revision nobody published: the install goes on without .git"
printf 'describe=v0.1.0\ncommit=%s\n' "$TAGC" > "$vf"
out=$(ORIGIN=$WORK/not-there inst "$WORK/g3"); E=$WORK/g3/etc/nixos
check_out "the install went on after the warning" "machine.toml: server name" echo "$out"
check_out "it says there is no checkout and where the steps are" "No git checkout was made.*docs/install.md" echo "$out"
check "no half repository is left" test ! -e "$E/.git"
check "machine.toml is written all the same" test -f "$E/machine.toml"
check_eq "the version is still known" "v0.1.0" "$(cat "$E/.hobnix-version")"
printf 'describe=v9.9.9\ncommit=%s\n' "0000000000000000000000000000000000000001" > "$vf"
out=$(inst "$WORK/g4"); E=$WORK/g4/etc/nixos
check_out "a commit that is not published: said, no .git" "does not say which published revision" echo "$out"
check "and no .git" test ! -e "$E/.git"
printf 'describe=-\ncommit=-\n' > "$vf"
out=$(inst "$WORK/g5"); check "a stick without a revision: no .git, no failure" test ! -e "$WORK/g5/etc/nixos/.git"
check_out "and the plan says so" "Git checkout.*none" bash -c "HS_INSTALL_ORIGIN=$PUB HS_INSTALLER_VERSION_FILE=$vf $W --dry-run --disk sda --hostname gitbox --key '$KEY' --target $WORK/g6 --repo $ISO 2>&1"

echo "-- the web interface and the setup flag (issue #580)"
TW=$WORK/web-target
$W --disk sda --hostname webbox --key "$KEY" --target "$TW" --repo "$REPO" >/dev/null 2>&1 || true
M=$TW/etc/nixos/machine.toml
check_eq "machine.toml turns the web interface on" "true" "$(get webUi)"
check "the first-setup flag is armed" test -s "$TW/var/lib/hs/first-run.json"
check "and holds no code" bash -c "grep -q '\"state\": \"pending\"' '$TW/var/lib/hs/first-run.json' && ! grep -Eq '[A-HJ-NP-Z2-9]{5}-[A-HJ-NP-Z2-9]{5}' '$TW/var/lib/hs/first-run.json'"
check_out "the last note names the address and the code" "one-time code.*webbox2.local:8480" bash -c "$W --disk sda --hostname webbox2 --key '$KEY' --target $WORK/web-target2 --repo $REPO 2>&1"

echo "-- the role edge (a public VPS)"
out=$($W --dry-run --role edge --bios --disk sda --hostname edge1 --key "$KEY" --target "$WORK/edge-dry" --repo "$REPO" 2>&1)
check_out "the plan names the role" "Role .*edge" echo "$out"
check_out "and a BIOS layout with GRUB on the disk" "BIOS boot.*GRUB on /dev/sda" echo "$out"
if grep -q "Samba networks\|Network card" <<<"$out"; then fail "an edge node asks nothing about network cards or Samba"; else pass "an edge node asks nothing about network cards or Samba"; fi
TE=$WORK/edge-target
$W --role edge --bios --disk sda --hostname edge1 --key "$KEY" --timezone Europe/Berlin --target "$TE" --repo "$REPO" >/dev/null 2>&1 || true
M=$TE/etc/nixos/machine.toml
check_eq "role" '"edge"' "$(get role)"
check "an edge node serves no web page and arms no setup" bash -c "test -z \"$(get webUi)\" && test ! -e '$TE/var/lib/hs/first-run.json'"
if [ "$(uname -o 2>/dev/null)" = Msys ]; then skip "bootDevice: Git Bash rewrites /dev/sda in arguments (Linux only)"
else check_eq "bootDevice (GRUB, BIOS)" '"/dev/sda"' "$(get bootDevice)"; fi
check_eq "the preset of the same name was applied: the edge capabilities" '["tailscale","edge-mail","edge-ports","edge-watcher","edge-status"]' "$(get capabilities | tr -d ' ')"
check_eq "and the Tailscale tag" '["tag:vps"]' "$(get tailscaleTags | tr -d ' ')"
check_eq "no ZFS host id for a node without pools" "" "$(get hostId)"
check_eq "and no network card or Samba networks" "" "$(get nic)$(get smbAllow)"
check_eq "the name and zone are there" '"edge1" "Europe/Berlin"' "$(get hostName) $(get timeZone)"
check "machine.toml of an edge node passes hs config check without hostId, nic, smbAllow and vlans" bash -c 'out=$(python3 "$1/machine-toml.py" check "$2/machine.toml.example" "$3" 2>&1); ! grep -q "^error" <<<"$out"' _ "$SCRIPTS" "$ROOT" "$M"
finish
