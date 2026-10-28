#!/usr/bin/env bash
# The vault (scripts/vault.sh, scripts/lib/vault.sh) and its place in hs unlock, with real LUKS on loop devices. Needs root and device-mapper.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
need_root
dm_works || { skip "device-mapper / dm-crypt is not available on this machine"; finish; exit $?; }

export HS_PLAIN=1 HS_STATE_DIR=$WORK/state HS_RUN_DIR=$WORK/run HS_VAULT_DIR=$WORK/vault HS_GUIDED_TTY=1 HS_SAMBA_PRIVATE=$WORK/samba
mkdir -p "$WORK/state" "$WORK/run" "$WORK/mnt"
PW=sharedpass
vault() { bash "$SCRIPTS/vault.sh" "$@"; }
unlock() { bash "$SCRIPTS/unlock.sh" "$@"; }
is_open() { mountpoint -q "$WORK/vault" && test -e /dev/mapper/hs-vault; }
lib() { bash -c ". '$SCRIPTS/lib/vault.sh'; $*"; }   # a helper of lib/vault.sh in a fresh shell

part=$(mkloop vp 100M)
partname=$(basename "$part")

echo "-- init refuses what it must refuse"
mk=$(mkloop busy 100M)
mkfs.ext4 -q -F "$mk"; mount "$mk" "$WORK/mnt"
check_out "a mounted partition" "mounted" vault init "$mk" --dry-run
umount "$WORK/mnt"
check_out "a partition with a signature" "signature" vault init "$mk" --dry-run
check_out "a block device is needed" "Not a block device" vault init "$WORK/nothing" --dry-run
check "nothing was recorded" test ! -e "$WORK/state/vault-uuid"
check_out "the dry run shows the plan and the danger line" "ALL DATA on .* will be erased" vault init "$part" --dry-run
check_out "and says nothing was changed" "Dry run" vault init "$part" --dry-run
check "the dry run left the partition alone" test -z "$(blkid -p -o value -s TYPE "$part")"
check_out "without a terminal and without --yes nothing happens" "without --yes" env HS_GUIDED_TTY= bash "$SCRIPTS/vault.sh" init "$part"
export HS_DISK_PASSPHRASE=$PW
check_out "a wrong disk name cancels" "cancelled" bash -c "echo wrongname | bash $SCRIPTS/vault.sh init $part"
check "still nothing recorded" test ! -e "$WORK/state/vault-uuid"

echo "-- init"
check "init with the typed disk name" bash -c "echo $partname | bash $SCRIPTS/vault.sh init $part"
check "the partition is LUKS" test "$(blkid -p -o value -s TYPE "$part")" = crypto_LUKS
check_eq "the uuid is recorded" "$(cryptsetup luksUUID "$part")" "$(cat "$WORK/state/vault-uuid" 2>/dev/null)"
check_out "the LUKS label is hs-vault" "hs-vault" cryptsetup luksDump "$part"
check "the vault is open afterwards" is_open
check_eq "the file system label is hs-vault" hs-vault "$(blkid -o value -s LABEL /dev/mapper/hs-vault)"
check_eq "secrets/ is root only" 700 "$(stat -c %a "$WORK/vault/secrets")"
check "bind/ exists" test -d "$WORK/vault/bind"
check_out "a second init is refused" "set up already" vault init "$part" --dry-run
check_out "status says open" "Vault: open" vault status
check_eq "the LUKS header is saved outside the vault (600)" 600 "$(stat -c %a "$WORK/state/vault-header" 2>/dev/null)"
check_out "and is a real header" "hs-vault" cryptsetup luksDump "$WORK/state/vault-header"
check_out "status shows the header backup" "Header backup +0 days" vault status
rm -f "$WORK/state/vault-header"
check "hs vault header-backup makes it again" vault header-backup
check "with mode 600" test "$(stat -c %a "$WORK/state/vault-header")" = 600

echo "-- move"
umask 077
printf 'secret-content-1' > "$WORK/state/restic-password"
printf 'secret-content-2' > "$WORK/state/unifi"; chmod 644 "$WORK/state/unifi"
out=$(vault move 2>&1)
if grep -q "secret-content" <<<"$out"; then fail "move never prints a secret"; else pass "move never prints a secret"; fi
check "restic-password is a link into the vault" test "$(readlink "$WORK/state/restic-password")" = "$WORK/vault/secrets/restic-password"
check_eq "the content is the same" secret-content-1 "$(cat "$WORK/state/restic-password")"
check_eq "the mode is 600" 600 "$(stat -c %a "$WORK/vault/secrets/restic-password")"
check_eq "a too open mode becomes 600" 600 "$(stat -c %a "$WORK/vault/secrets/unifi")"
check "a secret that does not exist is skipped" test ! -e "$WORK/state/grafana-admin"
check_out "moving again is harmless" "in the vault already" vault move restic-password
check_eq "and the content is unchanged" secret-content-1 "$(cat "$WORK/state/restic-password")"
check_out "a name that does not exist is said" "does not exist" vault move nothing-here
check_out "a bad name is refused" "Not a secret name" vault move ../etc
mkdir "$WORK/state/adir"
check_out "a folder is sent to bind" "hs vault bind" vault move adir
check_out "status lists it" "restic-password +secret +in vault" vault status
check_out "list is tab separated when piped" "^restic-password	secret	in vault" vault list
lib "vault_secret restic-password" >/dev/null 2>&1; check_eq "vault_secret: 0 while open" 0 "$?"
lib "vault_secret nothing-here" >/dev/null 2>&1; check_eq "vault_secret: 2 for a secret that does not exist" 2 "$?"

echo "-- a folder (bind item)"
mkdir -p "$WORK/priv"; echo folder-content > "$WORK/priv/a.db"
check "bind moves the folder in" vault bind extra-folder "$WORK/priv" --yes
check "the vault is mounted over the folder" mountpoint -q "$WORK/priv"
check_eq "its files are still there" folder-content "$(cat "$WORK/priv/a.db")"
check_eq "and live in the vault" folder-content "$(cat "$WORK/vault/bind/extra-folder/a.db")"
check_out "bind again is harmless" "in the vault already" vault bind extra-folder "$WORK/priv" --yes
check_out "status lists the folder" "extra-folder .*folder +in vault" vault status

echo "-- the Samba folder is the last, optional item of hs vault move"
mkdir -p "$WORK/samba"; echo tdb-content > "$WORK/samba/secrets.tdb"
# stale runtime sockets, like the ~280 in msg.sock of the real server: they must neither stop the move nor be copied
mkdir -p "$WORK/samba/msg.sock"; python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$WORK/samba/msg.sock/4711"
test -S "$WORK/samba/msg.sock/4711" || echo "(no socket could be made here)"
out=$(vault move 2>&1)
check "the default move mounts the vault over the Samba folder" mountpoint -q "$WORK/samba"
check_eq "its files are still there" tdb-content "$(cat "$WORK/samba/secrets.tdb")"
check_eq "and live in the vault" tdb-content "$(cat "$WORK/vault/bind/samba-private/secrets.tdb")"
check "the folder msg.sock is in the vault, the stale socket is not" bash -c "test -d '$WORK/vault/bind/samba-private/msg.sock' && test ! -S '$WORK/vault/bind/samba-private/msg.sock/4711'"
check_out "moving it again is harmless" "in the vault already" vault move samba-private

echo "-- close and open"
if have fuser; then
  ( cd "$WORK/vault" && exec sleep 60 ) & busy=$!
  sleep 1
  check_out "close is refused while something uses the vault" "in use" vault close --yes
  kill "$busy" 2>/dev/null; wait "$busy" 2>/dev/null
else
  skip "fuser is not installed: close while the vault is in use"
fi
check "close" vault close --yes
check "the vault is not mounted" test ! "$(mountpoint -q "$WORK/vault" && echo m)"
check "the mapper is gone" test ! -e /dev/mapper/hs-vault
check "the folder is not mounted any more" test ! "$(mountpoint -q "$WORK/priv" && echo m)"
check_eq "and the plain disk holds nothing of it" 0 "$(ls -A "$WORK/priv" | wc -l)"
check "the Samba folder is not mounted any more" test ! "$(mountpoint -q "$WORK/samba" && echo m)"
check_eq "and empty on the plain disk" 0 "$(ls -A "$WORK/samba" | wc -l)"
check "the secret link dangles" test -L "$WORK/state/restic-password" -a ! -e "$WORK/state/restic-password"
lib "vault_secret restic-password" >/dev/null 2>"$WORK/err"; check_eq "vault_secret: 1 while closed" 1 "$?"
check_out "and says why" "vault is closed" cat "$WORK/err"
lib "vault_secret nothing-here" >/dev/null 2>&1; check_eq "vault_secret: still 2 for a secret that does not exist" 2 "$?"
check_out "status says closed" "Vault: closed" vault status
check_out "move refuses while closed" "vault is closed" vault move
check_out "close again says so" "closed already" vault close --yes
check_out "open with a wrong passphrase fails" "does not open" env HS_DISK_PASSPHRASE=nope bash "$SCRIPTS/vault.sh" open
check "open" vault open
check "open again is a no-op" vault open
check_eq "the secret reads again" secret-content-1 "$(cat "$WORK/state/restic-password")"
check "the folder is mounted again" mountpoint -q "$WORK/priv"
check_eq "with its files" folder-content "$(cat "$WORK/priv/a.db")"
check_eq "the Samba folder too (before any unit starts)" tdb-content "$(cat "$WORK/samba/secrets.tdb")"

echo "-- hs unlock: the vault first"
# an encrypted data disk with the same passphrase
dev=$(mkloop e1 100M)
printf %s "$PW" | cryptsetup luksFormat --batch-mode --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file - "$dev" >/dev/null 2>&1
mapper1=/dev/mapper/hs-$(cryptsetup luksUUID "$dev" | tr -d - | cut -c1-12)
cryptsetup luksUUID "$dev" >> "$WORK/state/luks-uuids"   # the server knows this disk (unknown ones stay closed)
vault close --yes >/dev/null 2>&1
check_out "boot with a closed vault: the marker" "locked" bash -c "bash $SCRIPTS/unlock.sh --boot 2>&1; test -e $WORK/run/storage-locked && echo locked"
check "the marker is there" test -e "$WORK/run/storage-locked"
check "boot opened nothing" test ! -e "$mapper1" -a ! -e /dev/mapper/hs-vault
check_out "status shows the vault row as LOCKED" "VAULT .*LOCKED" unlock --status
out=$(unlock 2>&1)
check "unlock opens the vault" is_open
check "and the data disk" test -e "$mapper1"
check "and removes the marker" test ! -e "$WORK/run/storage-locked"
v=$(grep -n "Vault open" <<<"$out" | head -1 | cut -d: -f1); d=$(grep -n "disk(s) opened" <<<"$out" | head -1 | cut -d: -f1)
if [ -n "$v" ] && [ -n "$d" ] && [ "$v" -lt "$d" ]; then pass "the vault is opened before the other disks"; else fail "the vault is opened before the other disks (vault line '$v', disks line '$d')"; fi
check_out "status shows the vault open" "VAULT .* open" unlock --status
cryptsetup close "$(basename "$mapper1")"

echo "-- the key file lives in the vault"
printf '%s\n' "$PW" | unlock --setup-key >/dev/null 2>&1
check "the key file is a link into the vault" test "$(readlink "$WORK/state/disk-key")" = "$WORK/vault/secrets/disk-key"
check_eq "and root only (400)" 400 "$(stat -c %a "$WORK/vault/secrets/disk-key")"
unlock --remove-key >/dev/null 2>&1
check "remove-key takes both away" test ! -e "$WORK/vault/secrets/disk-key" -a ! -L "$WORK/state/disk-key"
# a data disk with ANOTHER passphrase: only the key file in the vault opens it
dev2=$(mkloop e2 100M)
printf %s otherpass | cryptsetup luksFormat --batch-mode --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file - "$dev2" >/dev/null 2>&1
mapper2=/dev/mapper/hs-$(cryptsetup luksUUID "$dev2" | tr -d - | cut -c1-12)
cryptsetup luksUUID "$dev2" >> "$WORK/state/luks-uuids"
printf %s otherpass > "$WORK/vault/secrets/disk-key"; chmod 400 "$WORK/vault/secrets/disk-key"
ln -sfn "$WORK/vault/secrets/disk-key" "$WORK/state/disk-key"
sed -i "\|$(cryptsetup luksUUID "$dev")|d" "$WORK/state/luks-uuids"   # e1 is not known any more: its refusal is not a problem
vault close --yes >/dev/null 2>&1
check_out "status says the key file is in the closed vault" "in the vault, which is closed" unlock --status
unlock >/dev/null 2>&1
check "unlock with the vault's key file opens the disk with the other passphrase" test -e "$mapper2"
check "and the vault" is_open
cryptsetup close "$(basename "$mapper2")" 2>/dev/null

echo "-- the helpers never fail cryptically"
vault close --yes >/dev/null 2>&1
check_out "the note is one sentence" "run hs unlock" lib vault_locked_note
check_out "German" "Tresor ist geschlossen" env HS_LANG=de bash -c ". $SCRIPTS/lib/vault.sh; vault_locked_note"
lib "vault_configured"; check_eq "vault_configured" 0 "$?"
HS_VAULT_OPEN=1 lib "vault_is_open"; check_eq "HS_VAULT_OPEN=1 means open (test knob)" 0 "$?"
lib "vault_is_open"; check_eq "without it a closed vault is closed" 1 "$?"
check_eq "vault_dev finds the partition" "$part" "$(lib vault_dev)"

finish
