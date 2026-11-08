#!/usr/bin/env bash
# The disaster-recovery installer (scripts/install-restore.sh, issue #254): reading a backup, the plan, the refusals and the files laid over the
# new configuration. No disk and no root: a fake restic (the repository is a folder of fixture files), HS_INSTALL_SKIP_DISK=1, a temp target.
# UNVERIFIED: this does NOT prove anything about real disks, a real restic repository or the ISO (manual checklist: docs/install.md).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test HS_PYTHON=python3 PYTHONUTF8=1 HS_INSTALL_SKIP_DISK=1
unset HS_INSTALL_PASSWORD
KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItestkey you@pc'
REPO=$WORK/repo; mkdir -p "$REPO/presets" "$REPO/scripts" "$REPO/config"
cp "$ROOT/machine.toml.example" "$REPO/"; cp "$ROOT"/presets/*.toml "$REPO/presets/"; cp "$ROOT/config/schema.toml" "$REPO/config/"
printf 'x' > "$REPO/install.nix"

# the "backup": a restic repository folder (config file) and the fixture tree the fake restic restores from
BK=$WORK/backup/restic; FIX=$WORK/fixture; mkdir -p "$BK" "$FIX/etc/nixos" "$FIX/var/lib/hs/disks" "$FIX/etc/ssh" "$WORK/bin"
: > "$BK/config"; export FIX BK
cat > "$FIX/etc/nixos/machine.toml" <<TOML
hostName = "oldbox"
sshKeys = [ "$KEY" ]
timeZone = "Europe/Vienna"
hostId = "deadbeef"
nic = "enp3s0"
smbAllow = "192.168.7.0/24 127.0.0.1"
TOML
echo 'hw-old' > "$FIX/etc/nixos/hardware-configuration.nix"
echo 'uuid-old' > "$FIX/var/lib/hs/vault-uuid"
echo 'luks' > "$FIX/var/lib/hs/luks-uuids"
echo 'SECRET-BACKUP-PASSWORD' > "$FIX/var/lib/hs/restic-password"
echo 'disk-a' > "$FIX/var/lib/hs/disks/a"
ln -s /var/lib/hs-vault/secret "$FIX/var/lib/hs/vault-link"
echo 'hostkey' > "$FIX/etc/ssh/ssh_host_ed25519_key"; chmod 600 "$FIX/etc/ssh/ssh_host_ed25519_key"
cat > "$WORK/bin/restic" <<'FAKE'
#!/usr/bin/env bash
# fake: -r REPO --password-file F snapshots|restore ...; the right password is "right-pass"; restore copies the --include paths from $FIX
args=("$@"); repo=""; pf=""; cmd=""; target=""; inc=()
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    -r) repo=${args[$((i + 1))]} ;;
    --password-file) pf=${args[$((i + 1))]} ;;
    --target) target=${args[$((i + 1))]} ;;
    --include) inc+=("${args[$((i + 1))]}") ;;
    snapshots|restore) cmd=${cmd:-${args[$i]}} ;;
  esac
done
[ -f "$repo/config" ] && [ "$(cat "$pf")" = right-pass ] || { echo "Fatal: wrong password or no such repository" >&2; exit 1; }
case "$cmd" in
  snapshots) echo '[{"id":"abcdef0123456789","time":"2026-11-05T04:00:01Z"},{"id":"1234567890abcdef","time":"2026-11-04T04:00:01Z"}]' ;;
  restore) for p in "${inc[@]}"; do for m in $FIX$p; do [ -e "$m" ] || [ -L "$m" ] || continue; q=${m#"$FIX"}; mkdir -p "$target$(dirname "$q")"; cp -a "$m" "$target$q"; done; done ;;
esac
FAKE
chmod +x "$WORK/bin/restic"; export PATH="$WORK/bin:$PATH"
echo right-pass > "$WORK/pass"; chmod 600 "$WORK/pass"; echo wrong-pass > "$WORK/badpass"; chmod 600 "$WORK/badpass"
export HS_RESTORE_REPO=$BK
R="bash $SCRIPTS/install-restore.sh"
T=$WORK/target

echo "-- the plan (dry run)"
out=$($R --dry-run --password-file "$WORK/pass" --disk sda --target "$T" --repo "$REPO" </dev/null 2>&1)
check_out "it says it is unverified" "UNVERIFIED" echo "$out"
check_out "it lists the snapshots" "abcdef01" echo "$out"
check_out "it names the new system disk as erased" "/dev/sda \(erased\)" echo "$out"
check_out "it takes the server name from the backup" "oldbox" echo "$out"
check_out "it lists the files that come back" "/etc/nixos/machine.toml" echo "$out"
check_out "and says what it does not restore" "Not restored here" echo "$out"
check_out "a dry run says nothing changed" "Dry run" echo "$out"
check "a dry run writes nothing" test ! -e "$T/etc/nixos"
if grep -q "SECRET-BACKUP-PASSWORD" <<<"$out"; then fail "no secret in the output"; else pass "no secret in the output"; fi
if grep -q "restic-password\|hardware-configuration\|/disks/" <<<"$out"; then fail "the plan lists a file that must not come back"; else pass "the plan lists no restic-password, hardware-configuration or disks"; fi

echo "-- the restore (files only)"
out=$($R --password-file "$WORK/pass" --disk sda --confirm-disk sda --target "$T" --repo "$REPO" </dev/null 2>&1) || fail "the restore run failed: $(tail -n 4 <<<"$out" | tr '\n' ' ')"
M=$T/etc/nixos/machine.toml
get() { HS_MACHINE_FILE=$M python3 "$SCRIPTS/machine-toml.py" get "$M" "$1" --json 2>/dev/null; }
check_eq "machine.toml of the backup is in place (hostName)" '"oldbox"' "$(get hostName)"
check_eq "and its hostId is kept (ZFS pools)" '"deadbeef"' "$(get hostId)"
check "the repository copy is there" test -f "$T/etc/nixos/install.nix"
check_eq "vault-uuid is back" "uuid-old" "$(cat "$T/var/lib/hs/vault-uuid" 2>/dev/null)"
check "the backup password is NOT written" test ! -e "$T/var/lib/hs/restic-password"
check "the old disk mounts are NOT written" test ! -e "$T/var/lib/hs/disks"
check "a link into the vault is not copied" test ! -e "$T/var/lib/hs/vault-link"
check "the old hardware-configuration.nix is not written" test ! -e "$T/etc/nixos/hardware-configuration.nix"
check_eq "the SSH host key is back" "hostkey" "$(cat "$T/etc/ssh/ssh_host_ed25519_key" 2>/dev/null)"
check_eq "with its mode" "600" "$(stat -c %a "$T/etc/ssh/ssh_host_ed25519_key" 2>/dev/null)"
check "no temporary folder of the restore is left" bash -c '! ls "${TMPDIR:-/tmp}"/hs-restore.* >/dev/null 2>&1'

echo "-- what it refuses"
out=$($R --password-file "$WORK/badpass" --disk sda --confirm-disk sda --target "$WORK/t2" --repo "$REPO" </dev/null 2>&1 || true)
check_out "a wrong password" "could not be opened" echo "$out"
check "and writes nothing" test ! -e "$WORK/t2/etc/nixos"
out=$(HS_INSTALL_SKIP_DISK= $R --password-file "$WORK/pass" --disk sda --target "$WORK/t2" --repo "$REPO" </dev/null 2>&1 || true)
check_out "no terminal and no --confirm-disk: the disk name is asked" "asks for its name" echo "$out"
out=$($R --password-file "$WORK/pass" --disk sda --confirm-disk sdb --target "$WORK/t2" --repo "$REPO" </dev/null 2>&1 || true)
check_out "a different name than the disk" "is not the disk" echo "$out"
out=$($R --password-file "$WORK/pass" --target "$WORK/t2" --repo "$REPO" </dev/null 2>&1 || true)
check_out "no disk and no terminal: nothing is chosen on a guess" "No terminal and no --disk" echo "$out"
out=$($R --target "$WORK/t2" --disk sda </dev/null 2>&1 || true)
check_out "no password and no terminal" "No terminal and no --password-file" echo "$out"
out=$($R --password-file "$WORK/pass" --disk "sda;rm" --target "$WORK/t2" --repo "$REPO" </dev/null 2>&1 || true)
check_out "a disk name with odd characters" "is not a disk name" echo "$out"
out=$($R --password-file "$WORK/pass" --disk sda --snapshot deadbeef --dry-run </dev/null 2>&1 || true)
check_out "a snapshot that does not exist" "No host snapshot" echo "$out"
out=$(HS_RESTORE_REPO=$WORK/nowhere $R --password-file "$WORK/pass" --disk sda --dry-run </dev/null 2>&1 || true)
check_out "a folder that is no repository" "No backup repository" echo "$out"

echo "-- the answers file"
A=$WORK/answers.toml
cat > "$A" <<TOML
version = 1
[install]
disk = "sda"
confirm_disk = "sda"
[restore]
snapshot = "abcdef01"
[secrets]
backup_passphrase_file = "$WORK/pass"
TOML
check_out "check-answers accepts the restore keys" "valid" bash "$SCRIPTS/answers.sh" "$A"
out=$($R --answers "$A" --dry-run --target "$WORK/t3" --repo "$REPO" </dev/null 2>&1)
check_out "the restore run reads disk and password from it" "/dev/sda \(erased\)" echo "$out"
sed -i 's/^snapshot = .*/snapshot = "nonsense"/' "$A"
check_out "a bad snapshot in the answers file is an error" "must be latest or a snapshot id" bash "$SCRIPTS/answers.sh" "$A"
printf 'version = 1\n[secrets]\nbackup_passphrase = "x"\n' > "$A"
check_out "an inline backup passphrase is refused" "never inline" bash "$SCRIPTS/answers.sh" "$A"

echo "-- the installer wizard with --restore-from"
check "the wizard knows --restore-from" grep -q -- '--restore-from' "$SCRIPTS/install-wizard.sh"
finish
