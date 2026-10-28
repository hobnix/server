#!/usr/bin/env bash
# The reads behind the Hardware, Encryption, Vault and Game streaming pages of the web interface: hs sys hardware, hs sys encryption list,
# hs sys vault usage|uses, hs sys ext games state. Stand-ins for /sys/class/hwmon, /proc/cpuinfo, cryptsetup, lsblk, blkid, zfs, df. No root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=ui
tab=$'\t'

echo "-- registry rows"
reg=$SCRIPTS/lib/registry.tsv
for r in "sys hardware" "sys encryption list" "sys vault usage" "sys vault uses"; do
  check "row: $r" grep -q "^sys${tab}${r}${tab}" "$reg"
done
check "row: sys ext games state (the package games)" grep -q "^sys${tab}sys ext games state${tab}" "$ROOT/capabilities/games/commands.tsv"

echo "-- hardware"
hw=$WORK/hw; mkdir -p "$hw/hwmon0" "$hw/hwmon1" "$hw/hwmon2" "$hw/hwmon3"
echo coretemp > "$hw/hwmon0/name"; echo 45000 > "$hw/hwmon0/temp1_input"; echo "Package id 0" > "$hw/hwmon0/temp1_label"
echo 42000 > "$hw/hwmon0/temp2_input"; echo "Core 0" > "$hw/hwmon0/temp2_label"
echo nct6798 > "$hw/hwmon1/name"; echo 1200 > "$hw/hwmon1/fan1_input"; echo 0 > "$hw/hwmon1/fan2_input"; echo "CPU fan" > "$hw/hwmon1/fan1_label"
echo 38000 > "$hw/hwmon1/temp1_input"; echo SYSTIN > "$hw/hwmon1/temp1_label"; echo 0 > "$hw/hwmon1/temp2_input"
echo nvme > "$hw/hwmon2/name"; echo 40000 > "$hw/hwmon2/temp1_input"
echo acpitz > "$hw/hwmon3/name"; echo 27800 > "$hw/hwmon3/temp1_input"
printf 'processor\t: 0\nmodel name\t: Intel(R) Core(TM)  i7-6700K CPU @ 4.00GHz\nphysical id\t: 0\ncore id\t\t: 0\n\nprocessor\t: 1\nmodel name\t: Intel(R)\nphysical id\t: 0\ncore id\t\t: 0\n\nprocessor\t: 2\nphysical id\t: 0\ncore id\t\t: 1\n\nprocessor\t: 3\nphysical id\t: 0\ncore id\t\t: 1\n' > "$WORK/cpuinfo"
out=$(HS_HWMON_DIR=$hw HS_CPUINFO=$WORK/cpuinfo bash "$SCRIPTS/hardware.sh")
check_eq "cpu model (spaces squeezed)" "cpu-model${tab}Intel(R) Core(TM) i7-6700K CPU @ 4.00GHz" "$(grep '^cpu-model' <<<"$out")"
check_eq "two cores, four threads" "cpu-cores${tab}2 cpu-threads${tab}4" "$(grep -E '^cpu-(cores|threads)' <<<"$out" | tr '\n' ' ' | sed 's/ $//')"
check_eq "the package temperature" "temp${tab}CPU package${tab}45" "$(grep 'CPU package' <<<"$out")"
check_eq "a core temperature" "temp${tab}CPU core 0${tab}42" "$(grep 'core 0' <<<"$out")"
check_eq "a board sensor with its label" "temp${tab}SYSTIN${tab}38" "$(grep SYSTIN <<<"$out")"
check_eq "a chip without labels is named by chip and sensor" "temp${tab}acpitz temp1${tab}27" "$(grep acpitz <<<"$out")"
check_eq "nvme is left out (the disks have their own read)" 0 "$(grep -c 40 <<<"$out" | tr -d ' ')"
check_eq "a sensor that reads 0 is left out" 0 "$(grep -c 'temp2' <<<"$out" | tr -d ' ')"
check_eq "a fan with a label" "fan${tab}CPU fan${tab}1200" "$(grep 'CPU fan' <<<"$out")"
check_eq "a fan that does not spin is still listed" "fan${tab}nct6798 fan2${tab}0" "$(grep 'fan2' <<<"$out")"
out=$(HS_HWMON_DIR=$WORK/none HS_CPUINFO=$WORK/none bash "$SCRIPTS/hardware.sh"); rc=$?
check_eq "no sensors, no cpuinfo: nothing, exit 0" "0:" "$rc:$out"

echo "-- pc --state"
export HS_STATE_DIR=$WORK/state; mkdir -p "$HS_STATE_DIR"
check_eq "no PC, no rows" "" "$(bash "$ROOT/capabilities/games/pc.sh" --state)"
printf 'gaming\taa:bb:cc:dd:ee:ff\t10.10.10.50\nlaptop\t11:22:33:44:55:66\t\nsleeper\t11:22:33:44:55:77\t10.10.10.51\n' > "$HS_STATE_DIR/pcs"
printf '#!/usr/bin/env bash\n[ "$1" = 10.10.10.50 ] && [ "$2" = 47989 ]\n' > "$WORK/probe"; chmod +x "$WORK/probe"
out=$(HS_PC_PROBE=$WORK/probe bash "$ROOT/capabilities/games/pc.sh" --state)
check_eq "up when the probe answers" "gaming${tab}10.10.10.50${tab}up" "$(sed -n 1p <<<"$out")"
check_eq "unknown without an address" "laptop${tab}-${tab}unknown" "$(sed -n 2p <<<"$out")"
check_eq "down when it does not" "sleeper${tab}10.10.10.51${tab}down" "$(sed -n 3p <<<"$out")"

echo "-- vault usage and uses"
export HS_VAULT_DIR=$WORK/vault HS_SAMBA_PRIVATE=$WORK/samba
mkdir -p "$HS_VAULT_DIR/secrets" "$WORK/bin" "$WORK/samba"
check_eq "no vault: state none" "state${tab}none" "$(bash "$SCRIPTS/vault.sh" usage)"
echo 1111-2222 > "$HS_STATE_DIR/vault-uuid"
printf '#!/usr/bin/env bash\ncase "$*" in "luksUUID /dev/sda4") echo 1111-2222 ;; "luksUUID /dev/sdb1") echo aaaaaaaa-0000-1111 ;; "luksUUID /dev/sdc1") echo bbbbbbbb-0000-1111 ;; "luksUUID /dev/sdd1") echo cccccccc-0000-1111 ;; "luksUUID /dev/sdf1") echo ffffffff-0000-1111 ;; *) exit 1 ;; esac\n' > "$WORK/bin/cryptsetup"
printf '#!/usr/bin/env bash\ncase "$*" in *"-nr -o PATH,TYPE"*) printf "/dev/sda4 part\\n/dev/sdb1 part\\n/dev/sdc1 part\\n/dev/sdd1 part\\n/dev/sde1 part\\n/dev/sdf1 part\\n" ;; *"-bdn -o SIZE /dev/sda4"*) echo 10737418240 ;; *"-bdn -o SIZE"*) echo 4000787030016 ;; esac\n' > "$WORK/bin/lsblk"
printf '#!/usr/bin/env bash\n[ "${@: -1}" = /dev/sde1 ] && echo ext4 || echo crypto_LUKS\n' > "$WORK/bin/blkid"
printf '#!/usr/bin/env bash\nprintf "tank\\ttank\\tavailable\\t500\\ntank/x\\ttank\\tavailable\\t5\\nfast\\tfast\\tunavailable\\t700\\nplain\\t-\\t-\\t9\\n"\n' > "$WORK/bin/zfs"
printf '#!/usr/bin/env bash\nprintf "1B-blocks Used Avail\\n10000 2500 7500\\n"\n' > "$WORK/bin/df"
chmod +x "$WORK/bin"/*
export PATH="$WORK/bin:$PATH"
out=$(HS_VAULT_OPEN=1 bash "$SCRIPTS/vault.sh" usage)
check_eq "open: state, size, used, free" "state=open size=10000 used=2500 free=7500" "$(awk -F'\t' '$1 ~ /^(state|size|used|free)$/ { printf "%s=%s ", $1, $2 }' <<<"$out" | sed 's/ $//')"
check_eq "no header backup: no such key" 0 "$(grep -c header-backup <<<"$out" | tr -d ' ')"
date +%s > /dev/null; echo hdr > "$HS_STATE_DIR/vault-header"
check_eq "a header backup made now is 0 days old" "header-backup-days${tab}0" "$(HS_VAULT_OPEN=1 bash "$SCRIPTS/vault.sh" usage | grep header)"
out=$(bash "$SCRIPTS/vault.sh" usage)
check_eq "closed: the partition size, no usage" "state=closed size=10737418240" "$(awk -F'\t' '$1 ~ /^(state|size|used|free)$/ { printf "%s=%s ", $1, $2 }' <<<"$out" | sed 's/ $//')"
printf 'x' > "$HS_VAULT_DIR/secrets/unifi"
printf 'sample\n' > "$HS_VAULT_DIR/secrets/restic-password"
out=$(HS_VAULT_OPEN=1 bash "$SCRIPTS/vault.sh" uses)
check_eq "restic-password: the backup" "restic-password${tab}the backup: every nightly and manual restic run (hs backup)" "$(grep '^restic-password' <<<"$out")"
check_eq "disk-key: hs unlock" "disk-key${tab}hs unlock: opens the other encrypted disks without typing the passphrase" "$(grep '^disk-key' <<<"$out")"
check_eq "never a secret's content" 0 "$(grep -c sample <<<"$out" | tr -d ' ')"
printf 'samba-private\t%s\n' "$WORK/samba" > "$HS_STATE_DIR/vault-binds"
out=$(HS_VAULT_OPEN=1 bash "$SCRIPTS/vault.sh" uses)
check_eq "a bind item is listed by its name, not 'name (folder)'" "samba-private${tab}Samba: the domain member secrets (folder $WORK/samba)" "$(grep '^samba-private' <<<"$out")"

echo "-- encryption list"
mapd=$WORK/mapper; mkdir -p "$mapd" "$WORK/sysblock/sdf1/holders/dm-0"
touch "$mapd/hs-aaaaaaaa0000"    # sdb1 is open
printf 'aaaaaaaa-0000-1111\nbbbbbbbb-0000-1111\nffffffff-0000-1111\n' > "$HS_STATE_DIR/luks-uuids"    # sdd1 is not recorded: somebody else's
export HS_MAPPER_DIR=$mapd HS_SYS_BLOCK=$WORK/sysblock
out=$(HS_VAULT_OPEN=1 bash "$SCRIPTS/unlock.sh" --list)
check_eq "the vault is open" "vault${tab}/dev/sda4${tab}open${tab}10737418240" "$(grep '^vault' <<<"$out")"
check_eq "an open LUKS disk" "luks${tab}/dev/sdb1${tab}open${tab}4000787030016" "$(grep sdb1 <<<"$out")"
check_eq "a locked LUKS disk" "luks${tab}/dev/sdc1${tab}locked${tab}4000787030016" "$(grep sdc1 <<<"$out")"
check_eq "a disk that is not recorded (somebody else's) is not listed" 0 "$(grep -c sdd1 <<<"$out" | tr -d ' ')"
check_eq "a plain partition is not listed" 0 "$(grep -c sde1 <<<"$out" | tr -d ' ')"
check_eq "a known disk open under another name" "luks${tab}/dev/sdf1${tab}unmanaged${tab}4000787030016" "$(grep sdf1 <<<"$out")"
check_eq "an open ZFS encryption root, with its used space" "zfs${tab}tank${tab}open${tab}500" "$(grep '^zfs.tank' <<<"$out")"
check_eq "a locked ZFS encryption root" "zfs${tab}fast${tab}locked${tab}700" "$(grep '^zfs.fast' <<<"$out")"
check_eq "a child dataset and an unencrypted pool are not roots" 2 "$(grep -c '^zfs' <<<"$out" | tr -d ' ')"
check_eq "the vault closed shows locked" "vault${tab}/dev/sda4${tab}locked${tab}10737418240" "$(bash "$SCRIPTS/unlock.sh" --list | grep '^vault')"
check_eq "nothing in the output looks like a key or passphrase" 0 "$(grep -ci 'pass\|key' <<<"$out" | tr -d ' ')"

finish
