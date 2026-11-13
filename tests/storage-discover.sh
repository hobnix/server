#!/usr/bin/env bash
# scripts/storage-discover.sh (hs sys storage discover): one line per whole disk, read only. Fake lsblk, blkid, zpool, findmnt (no root,
# no disks): the fakes answer from files under $WORK/fx and log every call, so the test can prove that nothing writes.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
FIX=$ROOT/tests/fixtures/storage-discover
export HS_PLAIN=1 HS_LANG=en HS_BYID=$WORK/byid HS_SYSFS=$WORK/sys
unset HS_TEST_LOOP
BIN=$WORK/bin FX=$WORK/fx CALLS=$WORK/calls
mkdir -p "$BIN" "$FX" "$HS_BYID" "$HS_SYSFS"
: > "$CALLS"

# lsblk: no device = the disk list; a device and "-o COL" = the file $FX/<dev>/<COL>
cat > "$BIN/lsblk" <<'FAKE'
#!/usr/bin/env bash
echo "lsblk $*" >> "$CALLS"
last=${*: -1}
case "$last" in
  /dev/*) col=""; prev=""
    for a; do [ "$prev" = -o ] && col=$a; prev=$a; done
    cat "$FX/${last##*/}/$col" 2>/dev/null ;;
  *) cat "$FX/disks" ;;
esac
exit 0
FAKE
cat > "$BIN/blkid" <<'FAKE'
#!/usr/bin/env bash
echo "blkid $*" >> "$CALLS"
exit 0
FAKE
cat > "$BIN/findmnt" <<'FAKE'
#!/usr/bin/env bash
echo "findmnt $*" >> "$CALLS"
exit 0
FAKE
cat > "$BIN/zpool" <<'FAKE'
#!/usr/bin/env bash
echo "zpool $*" >> "$CALLS"
case "$1" in
  status) cat "$FIXDIR/status.txt" ;;
  import) [ "$2" = -d ] && [ $# -eq 3 ] && cat "$FIXDIR/import.txt" || exit 1 ;;
  *) exit 1 ;;
esac
FAKE
# every command that would change something: it must never be called
for c in mount umount wipefs mkfs mkfs.ext4 mkfs.xfs mkfs.btrfs sgdisk parted cryptsetup udevadm zfs partprobe; do
  printf '#!/usr/bin/env bash\necho "WRITE %s $*" >> "$CALLS"\nexit 0\n' "$c" > "$BIN/$c"
done
chmod +x "$BIN"/*
export PATH="$BIN:$PATH" FX CALLS FIXDIR=$FIX HS_ZPOOL=$BIN/zpool

col() { local d=$1 c=$2; shift 2; mkdir -p "$FX/$d"; printf '%s\n' "$@" > "$FX/$d/$c"; }
disk() {   # disk <name> <by-id> <size> <type> <tran> <model>: the lsblk list, the by-id links (disk and first partition)
  printf '%s %s %s\n' "$1" "$3" "$4" >> "$FX/disks"
  ln -s "../$1" "$HS_BYID/$2"; ln -s "../${1}1" "$HS_BYID/$2-part1"
  mkdir -p "$FX/$1"; printf '%s\n' "$5" > "$FX/$1/TRAN"; printf '%s\n' "$6" > "$FX/$1/MODEL"
  col "$1" TYPE "$4"
}
: > "$FX/disks"
disk sda ata-OS 500000000000 disk sata "Samsung SSD 860"
col sda FSTYPE "" vfat ext4;  col sda MOUNTPOINT /boot /;  col sda TYPE disk part part; col sda PTTYPE gpt
disk sdb ata-EMPTY 4000000000000 disk sata ""
disk sdc ata-C 8000000000000 disk sata "WDC WD80EFAX"
col sdc FSTYPE zfs_member; col sdc LABEL tank;  col sdc TYPE disk part; col sdc PTTYPE gpt
disk sdd ata-D 8000000000000 disk sata "WDC WD80EFAX"
col sdd FSTYPE zfs_member; col sdd TYPE disk part; col sdd PTTYPE gpt
disk sde ata-E 4000000000000 disk sata "ST4000"
col sde FSTYPE xfs; col sde LABEL bulk-data-01; col sde MOUNTPOINT /var/lib/hs/disks/data-01; col sde TYPE disk part
disk sdf ata-F 6000000000000 disk usb "ST6000"
col sdf FSTYPE xfs; col sdf LABEL bulk-parity-1; col sdf TYPE disk part
disk sdg ata-G 2000000000000 disk usb "Elements 25A3"
col sdg FSTYPE ext4; col sdg LABEL backup; col sdg TYPE disk part
disk sdh ata-H 1000000000000 disk sas "HUS724"
col sdh FSTYPE crypto_LUKS; col sdh TYPE disk part
disk sdi ata-I 1000000000000 disk sata "Toshiba"
col sdi FSTYPE ntfs; col sdi LABEL Movies; col sdi TYPE disk part; col sdi PTTYPE gpt
disk sdj ata-J 1000000000000 disk sata "Toshiba"
col sdj FSTYPE ext4 ntfs; col sdj TYPE disk part part; col sdj PTTYPE gpt
disk sdk ata-K 3000000000000 disk sata "HGST"
col sdk FSTYPE zfs_member; col sdk TYPE disk part; col sdk PTTYPE gpt
disk vda virtio-V 20000000000 disk "" ""
disk nvme0n1 nvme-N 1000000000000 disk nvme "Samsung SSD 980"
printf 'zd0 1000000 disk\nsdz 0 disk\nloop0 1000000 loop\nsr0 1000000 rom\n' >> "$FX/disks"
ln -s ../zd0 "$HS_BYID/zvol-x"; ln -s ../sdz "$HS_BYID/ata-Z"; ln -s ../loop0 "$HS_BYID/loop-x"

D=$WORK/out; run() { bash ${DBG:+-x} "$SCRIPTS/storage-discover.sh" > "$D" 2>"$WORK/err"; }
row() { awk -F'\t' -v d="$1" '$1 == d' "$D"; }
t() { printf '\t'; }
T=$'\t'

echo "-- with ZFS"
check "runs" run
check_eq "empty disk" "ata-EMPTY${T}4000000000000${T}sata${T}-${T}empty${T}-${T}free" "$(row ata-EMPTY)"
check_eq "OS disk" "ata-OS${T}500000000000${T}sata${T}Samsung_SSD_860${T}os${T}-${T}system" "$(row ata-OS)"
check_eq "importable pool, name is not bulk" "ata-C${T}8000000000000${T}sata${T}WDC_WD80EFAX${T}zfs${T}tank${T}importable" "$(row ata-C)"
check_eq "imported pool" "ata-D${T}8000000000000${T}sata${T}WDC_WD80EFAX${T}zfs${T}media${T}imported" "$(row ata-D)"
check_eq "same pool name elsewhere with a missing device does not taint the imported one" "ata-D${T}8000000000000${T}sata${T}WDC_WD80EFAX${T}zfs${T}media${T}imported" "$(row ata-D)"
check_eq "pool with a missing device" "ata-K${T}3000000000000${T}sata${T}HGST${T}zfs${T}old${T}damaged" "$(row ata-K)"
check_eq "snapraid data, mounted" "ata-E${T}4000000000000${T}sata${T}ST4000${T}snapraid${T}bulk-data-01${T}mounted" "$(row ata-E)"
check_eq "snapraid parity, unmounted, usb" "ata-F${T}6000000000000${T}usb${T}ST6000${T}snapraid${T}bulk-parity-1${T}unmounted" "$(row ata-F)"
check_eq "backup disk" "ata-G${T}2000000000000${T}usb${T}Elements_25A3${T}backup${T}backup${T}protected" "$(row ata-G)"
check_eq "LUKS, locked, sas" "ata-H${T}1000000000000${T}sas${T}HUS724${T}luks${T}-${T}locked" "$(row ata-H)"
check_eq "foreign ntfs" "ata-I${T}1000000000000${T}sata${T}Toshiba${T}foreign${T}ntfs${T}has-data" "$(row ata-I)"
check_eq "foreign ext4 and ntfs" "ata-J${T}1000000000000${T}sata${T}Toshiba${T}foreign${T}ext4,ntfs${T}has-data" "$(row ata-J)"
check_eq "virtio disk without model" "virtio-V${T}20000000000${T}virtio${T}-${T}empty${T}-${T}free" "$(row virtio-V)"
check_eq "nvme disk" "nvme-N${T}1000000000000${T}nvme${T}Samsung_SSD_980${T}empty${T}-${T}free" "$(row nvme-N)"
check_eq "zvol, size 0, loop and rom are skipped" "" "$(awk -F'\t' '$1 ~ /^(zvol-x|ata-Z|loop-x)$/' "$D")"
check_eq "one line per disk" "13" "$(wc -l < "$D" | tr -d ' ')"
check_eq "seven fields, none empty" "" "$(awk -F'\t' 'NF != 7 { print; next } { for (i = 1; i <= 7; i++) if ($i == "") print }' "$D")"
check_eq "no output besides the rows" "" "$(cat "$WORK/err")"
check "zpool import is a listing" grep -qx "zpool import -d $HS_BYID" "$CALLS"

echo "-- an open LUKS disk"
col sdh TYPE disk part crypt
run; check_eq "LUKS, open" "luks${T}-${T}open" "$(row ata-H | cut -f5-)"

echo "-- no zpool installed"
export HS_ZPOOL=$WORK/nowhere/zpool
run
check_eq "importable pool without a name" "zfs${T}-${T}importable" "$(row ata-C | cut -f5-)"
check_eq "imported pool is only a member now" "zfs${T}-${T}importable" "$(row ata-D | cut -f5-)"
check_eq "other disks are the same" "empty${T}-${T}free" "$(row ata-EMPTY | cut -f5-)"
check_eq "still no empty field" "" "$(awk -F'\t' 'NF != 7 { print; next } { for (i = 1; i <= 7; i++) if ($i == "") print }' "$D")"

echo "-- it never writes"
check_eq "no write command was called" "0" "$(grep -c '^WRITE' "$CALLS" || true)"
check_eq "no import of a pool by name" "0" "$(grep '^zpool import' "$CALLS" | grep -vcx "zpool import -d $HS_BYID" || true)"
check_eq "no mount, wipefs, mkfs, labelclear" "0" "$(grep -cE 'labelclear|wipefs|mkfs|mount' "$CALLS" || true)"
finish
