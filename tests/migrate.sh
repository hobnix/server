#!/usr/bin/env bash
# hs migrate check: reads old disks without changing them.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
need_root
export HS_TEST_LOOP=1 HS_PLAIN=1 HS_STATE_DIR=$WORK/state
mkdir -p /etc/hs; echo snapraid > /etc/hs/bulk-type

d=$(mkloop plain 200M); mkfs.ext4 -q -F "$d"
mkdir -p "$WORK/m"; mount "$d" "$WORK/m"; head -c 10M /dev/zero > "$WORK/m/data"; umount "$WORK/m"
e=$(mkloop enc 100M)
printf pw | cryptsetup luksFormat --batch-mode --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file - "$e" >/dev/null 2>&1 || skip "cryptsetup missing"
mkloop big 400M >/dev/null
before=$(blkid -p -o export "$d" | md5sum)

out=$(bash "$SCRIPTS/migrate-check.sh" --parity ata-TEST_big 2>&1 || true)
check_out "the plain disk can be adopted and shows its data" "ata-TEST_plain.*ext4.*MB.*can be adopted" echo "$out"
check_out "the encrypted disk is recognised" "ata-TEST_enc.*crypto_LUKS.*passphrase" echo "$out"
check_out "a big enough parity disk is accepted" "at least as large" echo "$out"
out=$(bash "$SCRIPTS/migrate-check.sh" --parity ata-TEST_enc 2>&1 || true)
check_out "a too small parity disk is refused" "smaller than the largest data disk" echo "$out"
check_eq "nothing on the disk changed" "$before" "$(blkid -p -o export "$d" | md5sum)"
check "nothing is left mounted" bash -c "! findmnt -rn -S $d"
rm -f /etc/hs/bulk-type
finish
