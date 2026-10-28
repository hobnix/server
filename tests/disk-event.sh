#!/usr/bin/env bash
# scripts/disk-event.sh (hs sys disk event, hs disk events): a plugged-in or removed disk is logged and announced, a replayed
# udev event is silent, the first run only learns, and nothing ever touches a disk. Fake lsblk and curl, no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test HS_STATE_DIR=$WORK/state HS_NOTIFY_URL=http://push.test/topic
export HS_STATE_NO_COLLECT=1
export HS_PROC_UPTIME=$WORK/uptime HS_BOOT_WINDOW=300 HS_UDEVADM=true
echo "5000.00 100.00" > "$WORK/uptime"
mkdir -p "$WORK/dev" "$WORK/bin"
export DEVS=$WORK/dev CALLS=$WORK/curl.calls
: > "$CALLS"
cat > "$WORK/bin/curl" <<'FAKE'
#!/usr/bin/env bash
a="$*"; echo "curl ${a//$'\n'/ }" >> "$CALLS"   # one line per call, the body has several
FAKE
cat > "$WORK/bin/lsblk" <<'FAKE'
#!/usr/bin/env bash
dev=${@: -1}; name=${dev##*/}
case "$*" in
  "-dn -o NAME,TYPE") for f in "$DEVS"/*.size; do n=$(basename "$f" .size); echo "$n disk"; done; echo "loop0 loop" ;;
  *"-o SIZE"*) cat "$DEVS/$name.size" ;;
  *"-o MODEL"*) cat "$DEVS/$name.model" ;;
  *"-o SERIAL"*) cat "$DEVS/$name.serial" ;;
  *"-o LABEL,FSTYPE"*) cat "$DEVS/$name.parts" 2>/dev/null || true ;;
esac
FAKE
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH"
disk() {   # disk <name> <size> <model> <serial> [parts]
  echo "$2" > "$DEVS/$1.size"; echo "$3" > "$DEVS/$1.model"; echo "$4" > "$DEVS/$1.serial"; printf '%s' "${5:-}" > "$DEVS/$1.parts"
}
E="bash $SCRIPTS/disk-event.sh"
pushes() { grep -c . "$CALLS" || true; }

disk sda 250059350016 "Samsung SSD 850" S3R0NF1J ""
echo "-- the first event only learns what is there"
check "exit 0" $E add sda
check_eq "no push message" 0 "$(pushes)"
check "the disk is remembered" test -e "$HS_STATE_DIR/disks-seen/sda"

echo "-- a new empty disk"
disk sdz 4000787030016 "ST4000VN006-3CW1  " ZGY1234 ""
check_out "it is described" "sdz, ST4000VN006-3CW1, 4.0TB, S/N ZGY1234: empty: it can be added to a pool" $E add sdz
check_eq "one push message" 1 "$(pushes)"
check_out "with the model and the size" "ST4000VN006.*4.0TB" cat "$CALLS"
check_out "and a log line" "plugged in	sdz, ST4000VN006-3CW1" cat "$HS_STATE_DIR/disk-events"

echo "-- the same event again (udev replays them at boot and at every rebuild): silent"
: > "$CALLS"
check "exit 0" $E add sdz
check_eq "no second push message" 0 "$(pushes)"
check_eq "one log line" 1 "$(grep -c 'plugged in' "$HS_STATE_DIR/disk-events")"

echo "-- another disk under the same name is new"
disk sdz 2000398934016 "WD Red SA500" WDX999 ""
check_out "announced" "WD Red SA500" $E add sdz
check_eq "one push message" 1 "$(pushes)"

echo "-- what is on the disk"
disk sdy 3000592982016 "ST3000" Y1 $'bulk-data-02 xfs\n'
check_out "an array member" "a member of the bulk array \(data-02\)" $E add sdy
disk sdx 1000204886016 "WD Elements" X1 $'ntfs\n'
check_out "a disk with data is not called free" "holds data \(ntfs\): nothing is erased unless you add it" $E add sdx
disk sdw 1000204886016 "Old pool disk" W1 $'zfs_member\n'
check_out "ZFS labels" "has ZFS labels" $E add sdw

echo "-- taken out"
: > "$CALLS"
check_out "a removed pool member is announced as high priority" "taken out: sdy" $E remove sdy
check_out "with the pool hint" "Priority: high|high" cat "$CALLS"
: > "$CALLS"
check_out "a removed free disk" "taken out: sdx" $E remove sdx
check_out "is only a low message" "low" cat "$CALLS"
: > "$CALLS"
check "an unknown disk is ignored" $E remove sdq
check_eq "no push message" 0 "$(pushes)"

echo "-- no push message just after a boot, but it is logged"
echo "60.00 100.00" > "$WORK/uptime"; : > "$CALLS"
disk sdv 500107862016 "Boot-time disk" B1 ""
check_out "logged" "plugged in: sdv" $E add sdv
check_eq "no push message in the boot window" 0 "$(pushes)"
echo "5000.00 100.00" > "$WORK/uptime"

echo "-- loop and memory devices and odd names are ignored"
: > "$CALLS"
check "loop0" $E add loop0
check "zram0" $E add zram0
check "a path" $E add "../etc"
check_eq "nothing" 0 "$(pushes)"
check "no seen file for loop0" test ! -e "$HS_STATE_DIR/disks-seen/loop0"

echo "-- hs disk events and hs sys disk event through the dispatcher"
check_out "the log is a table" "When +Event +Disk|plugged in" $E log
check_out "hs disk events" "plugged in" bash "$SCRIPTS/lib/hs.sh" disk events
out=$(HS_CALLER=test bash "$SCRIPTS/lib/hs.sh" sys disk event remove sdv 2>&1 || true)
check_out "hs sys disk event remove" "taken out: sdv" echo "$out"

echo "-- seed learns silently, without a marker the first event seeds"
rm -rf "$HS_STATE_DIR"; : > "$CALLS"
check "seed" $E seed
check "marker" test -e "$HS_STATE_DIR/disks-seen/.seeded"
check_eq "no push message" 0 "$(pushes)"
finish
