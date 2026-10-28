#!/usr/bin/env bash
# hs sys disk plan|start <disk> wipe (scripts/disk-change.sh): a disk that belongs to nothing is erased after a typed confirmation;
# mounted, pool, array and backup disks are refused. Fake lsblk, zpool, wipefs ... in PATH: no root, no disks.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en
unset HS_CALLER HS_GUIDED_TTY
BIN=$WORK/bin; mkdir -p "$BIN" "$WORK/dev"
LOG=$WORK/calls; : > "$LOG"
for d in sdy sdm sdp sdb sdk sdc sdq; do : > "$WORK/dev/$d"; done
export HS_DEV_DIR=$WORK/dev HS_STATE_DIR=$WORK/state; mkdir -p "$WORK/state"; printf 'UUID-OPEN\nUUID-KEEP\n' > "$WORK/state/luks-uuids"
cat > "$BIN/lsblk" <<'FAKE'
#!/usr/bin/env bash
# last argument is the device; -P gives key="value" lines, -nr -o PATH gives paths
dev=${@: -1}; d=$(basename "$dev")
if [[ "$*" != *"PATH,TYPE"* ]]; then
  case "$d" in sdy) printf '/dev/sdy\n/dev/sdy1\n' ;; sdc) printf '/dev/sdc\n/dev/sdc1\n/dev/mapper/hs-abc\n' ;; *) printf '/dev/%s\n' "$d" ;; esac; exit 0
fi
disk() { printf 'PATH="/dev/%s" TYPE="disk" FSTYPE="" LABEL="" MOUNTPOINTS="" SIZE="%s"\n' "$1" "$2"; }
case "$d" in
  sdy) disk sdy 3.6T; printf 'PATH="/dev/sdy1" TYPE="part" FSTYPE="ext4" LABEL="old" MOUNTPOINTS="" SIZE="3.6T"\n' ;;
  sdm) disk sdm 1T; printf 'PATH="/dev/sdm1" TYPE="part" FSTYPE="ext4" LABEL="" MOUNTPOINTS="/mnt/temp/x" SIZE="1T"\n' ;;
  sdp) disk sdp 4T; printf 'PATH="/dev/sdp1" TYPE="part" FSTYPE="ext4" LABEL="bulk-data-02" MOUNTPOINTS="" SIZE="4T"\n' ;;
  sdb) disk sdb 4T; printf 'PATH="/dev/sdb1" TYPE="part" FSTYPE="ext4" LABEL="backup" MOUNTPOINTS="" SIZE="4T"\n' ;;
  sdk) disk sdk 2T; printf 'PATH="/dev/sdk1" TYPE="part" FSTYPE="zfs_member" LABEL="" MOUNTPOINTS="" SIZE="2T"\n' ;;
  sdc) disk sdc 4T; printf 'NAME="sdc1" PATH="/dev/sdc1" TYPE="part" FSTYPE="crypto_LUKS" LABEL="" MOUNTPOINTS="" SIZE="4T"\nNAME="hs-abc" PATH="/dev/mapper/hs-abc" TYPE="crypt" FSTYPE="ext4" LABEL="" MOUNTPOINTS="" SIZE="4T"\n' ;;
  sdq) disk sdq 4T; printf 'NAME="sdq1" PATH="/dev/sdq1" TYPE="part" FSTYPE="crypto_LUKS" LABEL="" MOUNTPOINTS="" SIZE="4T"\nNAME="hs-def" PATH="/dev/mapper/hs-def" TYPE="crypt" FSTYPE="ext4" LABEL="bulk-data-02" MOUNTPOINTS="" SIZE="4T"\n' ;;
  *) exit 1 ;;
esac
FAKE
cat > "$BIN/blkid" <<'FAKE'
#!/usr/bin/env bash
case "${@: -1}" in /dev/sdc1|/dev/sdq1) echo crypto_LUKS ;; esac
FAKE
cat > "$BIN/cryptsetup" <<FAKE
#!/usr/bin/env bash
case "\$1" in luksUUID) echo UUID-OPEN ;; close) echo "cryptsetup \$*" >> "$LOG" ;; esac
exit 0
FAKE
cat > "$BIN/zpool" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = status ] && printf '  pool: fast\n\tNAME\n\tfast\n\t  mirror-0\n\t    sdk1\n'
exit 0
FAKE
for c in wipefs sgdisk blockdev udevadm; do printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n' "$c" "$LOG" > "$BIN/$c"; done
chmod +x "$BIN"/*
run() { rc=0; out=$(PATH="$BIN:$PATH" timeout 20 bash "$SCRIPTS/disk-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }
T=$'\t'

echo "-- plan"
run plan wipe sdy
check_eq "a free disk: exit 0" 0 "$rc"
has "^status${T}ok$" && has "^danger${T}ALL DATA on sdy will be erased.$" && has "^confirm_name${T}sdy$" && has "^warn${T}sdy1 holds ext4 \"old\"$" && has "^long${T}no$" && pass "plan: status, danger, confirm_name, what is on it" || fail "plan: $out"
run plan wipe sdm;  check_eq "mounted: refused" 1 "$rc"; has "in use" && pass "mounted: reason" || fail "mounted: $out"
run plan wipe sdp;  check_eq "array member: refused" 1 "$rc"; has "member of the bulk array" && pass "array: reason" || fail "array: $out"
run plan wipe sdb;  check_eq "backup disk: refused" 1 "$rc"; has "backup disk" && pass "backup: reason" || fail "backup: $out"
run plan wipe sdk;  check_eq "ZFS member: refused" 1 "$rc"; has "ZFS pool" && pass "zfs: reason" || fail "zfs: $out"
run plan wipe nosuch; check_eq "unknown disk: refused" 1 "$rc"
run plan wipe 'a/b';  check_eq "a path is refused" 1 "$rc"
run plan wipe sdy --bogus; check_eq "an unknown option is refused" 1 "$rc"

echo "-- an open encrypted volume that is mounted nowhere (a disk taken out of the array)"
run plan wipe sdc
check_eq "open LUKS volume: exit 0" 0 "$rc"
has "^step${T}close the open encrypted volume hs-abc$" && pass "the plan closes it first" || fail "open LUKS: $out"
run plan wipe sdq; check_eq "an open volume that still carries the array label is refused" 1 "$rc"; has "member of the bulk array" && pass "array label: reason" || fail "$out"

echo "-- start"
: > "$LOG"
run start wipe sdy; check_eq "no confirmation: refused" 1 "$rc"; has "type the name" && pass "asks for the name" || fail "$out"
check_eq "nothing was erased" 0 "$(wc -l < "$LOG" | tr -d ' ')"
run start wipe sdy --confirm sdx; check_eq "wrong name: refused" 1 "$rc"
check_eq "nothing was erased" 0 "$(wc -l < "$LOG" | tr -d ' ')"
run start wipe sdy --confirm sdy --now; check_eq "right name: exit 0" 0 "$rc"
has "^status${T}done$" && pass "done" || fail "$out"
if grep -q "wipefs -a -q $WORK/dev/sdy" "$LOG" && grep -q "wipefs -a -q /dev/sdy1" "$LOG"; then pass "the disk and its partition were wiped"; else fail "wipefs calls: $(cat "$LOG")"; fi
: > "$LOG"
run start wipe sdm --confirm sdm; check_eq "start repeats the checks (mounted)" 1 "$rc"
check_eq "nothing was erased" 0 "$(wc -l < "$LOG" | tr -d ' ')"
echo "-- start without --now is a job (Tasks)"
printf '#!/usr/bin/env bash\necho "systemd-run $*" >> "%s"\n' "$LOG" > "$BIN/systemd-run"; chmod +x "$BIN/systemd-run"
: > "$LOG"
run start wipe sdy --confirm sdy; check_eq "job: exit 0" 0 "$rc"
has "^status${T}started$" && has "^unit${T}hs-job-disk-wipe-sdy-" && pass "status started and the unit" || fail "job: $out"
if grep -q "disk-change.sh start wipe sdy --confirm sdy --now" "$LOG" && ! grep -q wipefs "$LOG"; then pass "the job repeats the command with --now; nothing erased yet"; else fail "job calls: $(cat "$LOG")"; fi
rm -f "$BIN/systemd-run"

echo "-- start on the open encrypted disk"
: > "$LOG"
run start wipe sdc --confirm sdc --now; check_eq "exit 0" 0 "$rc"
if grep -q "cryptsetup close hs-abc" "$LOG" && grep -q "wipefs -a -q" "$LOG"; then pass "closed, then wiped"; else fail "calls: $(cat "$LOG")"; fi
check_eq "its uuid is forgotten, the others stay" "UUID-KEEP" "$(cat "$WORK/state/luks-uuids")"
finish
