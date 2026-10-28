#!/usr/bin/env bash
# hs sys monitor disks (monitor.sh --disks): the disk table the overview reads, with fake lsblk, zpool and smartctl.
# Needs jq (always there in CI), no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1
BIN=$WORK/bin; mkdir -p "$BIN"

if ! command -v jq >/dev/null 2>&1; then skip "jq is not installed: monitor tests not run"; finish; exit $?; fi

cat > "$BIN/lsblk" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "-dnb -o NAME,SIZE,TYPE,ROTA,MODEL,SERIAL")
    printf 'sda 4000000000000 disk 1 ST4000VN006 ZXX1\n'     # bulk data disk (label)
    printf 'sdb 250000000000 disk 0 Samsung_850 S2\n'         # the system disk (mounted on /)
    printf 'sdc 2000000000000 disk 0 WD_Red S3\n'             # member of the ZFS pool fast
    printf 'sdd 8000000000 disk 0 USB_Stick S4\n'             # the backup disk (label)
    printf 'sde 1000000000000 disk 0 Blank S5\n'              # nothing on it
    printf 'sdf 500000000000 disk 0 Other S6\n'               # mounted somewhere
    printf 'zd0 5000 disk 0 zvol S7\n'                        # a zvol: not a disk
    printf 'sr0 1000 rom 0 DVD S8\n' ;;                       # not type disk
  "-nr -o LABEL /dev/sda") echo bulk-data-01 ;;
  "-nr -o LABEL /dev/sdd") echo backup ;;
  "-nr -o MOUNTPOINT /dev/sdb") printf '/boot\n/\n' ;;
  "-nr -o MOUNTPOINT /dev/sdf") echo /mnt/other ;;
esac
FAKE
cat > "$BIN/zpool" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  list) case "$*" in
    *vHpL*) printf "fast	2000398934016	500000000000	1500398934016
	mirror-0	2000398934016	500000000000	1500398934016
		sdc1	-	-	-
" ;;
    *) echo fast ;;
  esac ;;
  status) printf '  pool: fast\n state: ONLINE\nconfig:\n\n\tNAME        STATE     READ WRITE CKSUM\n\tfast        ONLINE       0     0     0\n\t  mirror-0  ONLINE       0     0     0\n\t    sdc     ONLINE       0     0     0\n\nerrors: No known data errors\n' ;;
esac
FAKE
cat > "$BIN/df" <<'FAKE'
#!/usr/bin/env bash
case "${*: -1}" in
  /) v=100000000000 ;;
  /mnt/bulk/data-01) v=2000000000000 ;;
  /mnt/other) v=300000000000 ;;
  *) exit 1 ;;
esac
printf 'Avail\n%s\n' "$v"
FAKE
cat > "$BIN/smartctl" <<'FAKE'
#!/usr/bin/env bash
case "${*: -1}" in
  /dev/sda) echo '{"smart_status":{"passed":true},"temperature":{"current":35},"power_on_time":{"hours":1000},"ata_smart_attributes":{"table":[{"id":5,"raw":{"value":0}},{"id":197,"raw":{"value":0}},{"id":199,"raw":{"value":3}}]}}' ;;
  /dev/sdb) echo '{"smart_status":{"passed":false},"temperature":{"current":41},"power_on_time":{"hours":20000}}' ;;
  /dev/sdc) echo '{"smartctl":{"messages":[{"string":"Device is in STANDBY mode"}]}}' ;;
esac
FAKE
# hdparm -C: only sda (a rotating disk) is asked; it sleeps
cat > "$BIN/hdparm" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$HDPARM_CALLS"
printf '
/dev/sda:
 drive state is:  standby
'
FAKE
export HDPARM_CALLS=$WORK/hdparm-calls; : > "$HDPARM_CALLS"
chmod +x "$BIN"/*
export PATH=$BIN:$PATH
export HS_SMARTCTL_URL=file:///nonexistent   # no exporter: every disk is asked directly
out=$(bash "$SCRIPTS/monitor.sh" --disks)

echo "-- hs sys monitor disks"
check_eq "only real disks: no zvol, no DVD" "6" "$(wc -l <<<"$out" | tr -d ' ')"
check_eq "a bulk data disk: HDD, role from the label, health and counters" $'sda\t4000000000000\tHDD\tbulk data-01\t35\tOK\t1000\t0\t0\t3\tST4000VN006 ZXX1	2000000000000	asleep' "$(grep '^sda' <<<"$out")"
check_eq "the system disk: SSD, role system, a failing SMART verdict" $'sdb\t250000000000\tSSD\tsystem\t41\tFAIL\t20000\t-\t-\t-\tSamsung_850 S2	100000000000	-' "$(grep '^sdb' <<<"$out")"
check_out "a ZFS member: the pool is the role, asleep is not woken" $'^sdc\t2000000000000\tSSD\tfast\t-\tasleep\t' echo "$out"
check_out "the backup disk has its own role" $'^sdd\t.*\tbackup disk\t' echo "$out"
check_out "an empty disk is free, and no SMART data gives dashes" $'^sde\t1000000000000\tSSD\tfree\t-\t-\t-\t-\t-\t-\tBlank S5' echo "$out"
check_out "a disk mounted elsewhere is mounted" $'^sdf\t.*\tmounted\t' echo "$out"
check_out "a ZFS member: the free space of its mirror" $'^sdc\t.*\t1500398934016\t-$' echo "$out"
check_out "a bulk disk and a mounted disk: the free space of the filesystem" $'^sdf\t.*\t300000000000\t-$' echo "$out"
check_out "a disk that is not mounted (backup disk, free disk) has no free space" $'^sdd\t.*\t-\t-$' echo "$out"
check_out "an empty disk too" $'^sde\t.*Blank S5\t-\t-$' echo "$out"
check_eq "every line has 13 tab separated fields" "" "$(awk -F'\t' 'NF != 13 { print NR": "NF }' <<<"$out")"

check_eq "hdparm -C only asks the rotating disk" "-C /dev/sda" "$(sort -u "$HDPARM_CALLS")"

echo "-- the exporter's last scrape instead of asking every disk"
cat > "$WORK/metrics.txt" <<'EOM'
smartctl_device_temperature{device="sda",temperature_type="current"} 36
smartctl_device_smart_status{device="sda"} 1
smartctl_device_power_on_seconds{device="sda"} 7200000
smartctl_device_attribute{attribute_id="199",attribute_value_type="raw",device="sda"} 4
EOM
scraped=$(HS_SMARTCTL_URL=file://$WORK/metrics.txt bash "$SCRIPTS/monitor.sh" --disks)
check_out "a disk the exporter knows: its values, not smartctl's" $'^sda\t4000000000000\tHDD\tbulk data-01\t36\tOK\t2000\t-\t-\t4\t' echo "$scraped"
check_out "a disk it does not know is asked directly" $'^sdb\t.*\tsystem\t41\tFAIL\t20000\t' echo "$scraped"
check_eq "--fresh ignores the exporter" "$out" "$(HS_SMARTCTL_URL=file://$WORK/metrics.txt bash "$SCRIPTS/monitor.sh" --disks --fresh)"
check_eq "an exporter that is down gives the direct table" "$out" "$(HS_SMARTCTL_URL=file:///nonexistent bash "$SCRIPTS/monitor.sh" --disks)"

echo "-- through the registry"
fake=$WORK/reg; mkdir -p "$fake/lib"
cp "$SCRIPTS"/lib/hs.sh "$SCRIPTS"/lib/capability.sh "$SCRIPTS"/lib/registry-load.sh "$SCRIPTS"/lib/ui.sh "$SCRIPTS"/lib/i18n.sh "$SCRIPTS"/lib/setting.sh "$SCRIPTS"/lib/job.sh "$SCRIPTS"/lib/diskpath.sh "$SCRIPTS/lib/registry.tsv" "$fake/lib/"; cp -r "$SCRIPTS"/lib/i18n "$fake/lib/"
cp "$SCRIPTS/monitor.sh" "$fake/"
check_eq "hs sys monitor disks is the same table" "$out" "$(env HS_CALLER=t HS_COMPLETE_DIR=$WORK/complete bash "$fake/lib/hs.sh" sys monitor disks)"
check_out "an unknown option prints the usage" "usage: hs monitor" bash "$SCRIPTS/monitor.sh" --bogus
finish
