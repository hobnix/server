#!/usr/bin/env bash
# crypt_disk_class (scripts/lib/crypt.sh): whose is the LUKS volume on a disk? Fake lsblk, blkid, cryptsetup and holders: no
# root, no devices. own and ambiguous disks are never offered as free disks, copy (an old system disk with a copy of our
# vault) and foreign are offered with a warning.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_STATE_DIR=$WORK/state HS_SYS_BLOCK=$WORK/sysblock
mkdir -p "$WORK/bin" "$WORK/types" "$WORK/uuids" "$WORK/state" "$HS_SYS_BLOCK"
cat > "$WORK/bin/lsblk" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "-nr -o PATH,TYPE") cat "$WORK/devs" ;;
  "-nr -o PATH "*) d=${@: -1}; awk -v d="$d" '$1 == d || index($1, d) == 1 { print $1 }' "$WORK/devs" ;;
esac
FAKE
cat > "$WORK/bin/blkid" <<'FAKE'
#!/usr/bin/env bash
cat "$WORK/types/$(basename "${@: -1}")" 2>/dev/null || true
FAKE
cat > "$WORK/bin/cryptsetup" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = luksUUID ] || exit 1
cat "$WORK/uuids/$(basename "$2")" 2>/dev/null || exit 1
FAKE
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH" WORK
. "$SCRIPTS/lib/crypt.sh"

luks() {   # luks <name> <uuid>: the device holds a LUKS header
  echo crypto_LUKS > "$WORK/types/$1"; echo "$2" > "$WORK/uuids/$1"
}
: > "$WORK/devs"
dev() { echo "/dev/$1 $2" >> "$WORK/devs"; }
printf "11111111-aaaa
33333333-bbbb
" > "$WORK/state/luks-uuids"   # data disks of this server
echo "22222222-vault" > "$WORK/state/vault-uuid"  # the vault

echo "-- somebody else's disk"
dev sdz disk; dev sdz1 part; luks sdz1 99999999-other
check_eq "an unrecorded LUKS volume is foreign" foreign "$(crypt_disk_class /dev/sdz)"

echo "-- this server's data disk"
dev sdb disk; luks sdb 11111111-aaaa
check_eq "a recorded volume that nothing else carries is own (also while locked)" own "$(crypt_disk_class /dev/sdb)"

echo "-- an old system disk with a copy of our vault"
dev sda disk; dev sda2 part; luks sda2 22222222-vault
mkdir -p "$HS_SYS_BLOCK/sda2/holders/dm-0"            # the real vault is open
dev sdh disk; dev sdh2 part; luks sdh2 22222222-vault
check_eq "the open vault is own" own "$(crypt_disk_class /dev/sda)"
check_eq "its copy on another disk is a copy (offered with a warning)" copy "$(crypt_disk_class /dev/sdh)"

echo "-- the same UUID twice and nothing is open: hidden, we cannot tell which is real"
rm -rf "$HS_SYS_BLOCK/sda2"
check_eq "the first is ambiguous" ambiguous "$(crypt_disk_class /dev/sda)"
check_eq "the second is ambiguous" ambiguous "$(crypt_disk_class /dev/sdh)"

echo "-- a disk with an own volume and a foreign one is own (never offered)"
dev sdm disk; dev sdm1 part; dev sdm2 part; luks sdm1 33333333-bbbb; luks sdm2 99999999-other
check_eq "own wins" own "$(crypt_disk_class /dev/sdm)"
finish
