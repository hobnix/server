#!/usr/bin/env bash
# The ZFS replace/remove decisions of manage-pool.sh, against a fake `zpool` (no ZFS needed here).
# The real commands run in tests/zfs-vm.sh (throwaway VM on the server).
set -uo pipefail
. "$(dirname "$0")/lib.sh"
need_root
mkdir -p /etc/hs; echo zfs > /etc/hs/bulk-type
export HS_PLAIN=1 HS_STATE_DIR=$WORK/state
BIN=$WORK/bin; mkdir -p "$BIN"; LOG=$WORK/zpool.log; : > "$LOG"
SCEN=$WORK/scenario
cat > "$BIN/zpool" <<FAKE
#!/usr/bin/env bash
echo "zpool \$*" >> "$LOG"
sc=\$(cat "$SCEN")
case "\$1" in
  status)
    echo "  pool: bulk"; echo " config:"; echo
    printf '\tNAME\t\tSTATE\tREAD WRITE CKSUM\n'
    printf '\tbulk\tONLINE\t0 0 0\n'
    printf '\t  mirror-0\tONLINE\t0 0 0\n\t    /dev/disk/by-id/ata-A-part1\tONLINE\t0 0 0\n\t    /dev/disk/by-id/ata-B-part1\tONLINE\t0 0 0\n'
    case "\$sc" in
      three) printf '\t    /dev/disk/by-id/ata-C-part1\tONLINE\t0 0 0\n' ;;
      two|full) printf '\t  mirror-1\tONLINE\t0 0 0\n\t    /dev/disk/by-id/ata-D-part1\tONLINE\t0 0 0\n\t    /dev/disk/by-id/ata-E-part1\tONLINE\t0 0 0\n' ;;
    esac ;;
  list)
    printf 'bulk\t8000000000\t3000000000\t5000000000\n'
    printf '\tmirror-0\t4000000000\t2000000000\t2000000000\n'
    if [ "\$sc" = full ]; then printf '\tmirror-1\t4000000000\t3900000000\t100000000\n'; else printf '\tmirror-1\t4000000000\t1000000000\t3000000000\n'; fi ;;
esac
FAKE
chmod +x "$BIN/zpool"
export PATH="$BIN:$PATH"
pool() { bash "$SCRIPTS/manage-pool.sh" bulk "$@" 2>&1; }

echo "-- one mirror only"
echo one > "$SCEN"
check_out "a single mirror cannot be removed whole" "only vdev" pool --remove ata-A --mode vdev --dry-run
check_out "detaching from a 2-disk mirror warns that the other disk is alone" "alone in its vdev" pool --remove ata-A --mode detach --dry-run

echo "-- three disks in a mirror"
echo three > "$SCEN"
out=$(pool --remove ata-C --dry-run)
check_out "detach without a warning" "keeps working with 2 disks" echo "$out"
check_out "the command is zpool detach" "zpool detach bulk /dev/disk/by-id/ata-C-part1" echo "$out"

echo "-- two mirrors"
echo two > "$SCEN"
out=$(pool --remove ata-A --mode vdev --dry-run)
check_out "removing a whole mirror says what moves" "mirror will be removed" echo "$out"
check_out "and how much" "2.0GB of data move to the other mirrors, which have 3.0GB free" echo "$out"
check_out "the command is zpool remove mirror-0" "zpool remove bulk mirror-0" echo "$out"
: > "$LOG"
echo ata-A | pool --remove ata-A --mode vdev >/dev/null
check_out "it runs zpool remove" "zpool remove bulk mirror-0" cat "$LOG"
: > "$LOG"
echo ata-A | pool --remove ata-A --mode detach >/dev/null
check_out "detach runs zpool detach" "zpool detach bulk /dev/disk/by-id/ata-A-part1" cat "$LOG"

echo "-- the other mirror is too full"
echo full > "$SCEN"
check_out "refused with the numbers" "Not possible: mirror-0 holds 2.0GB, the other mirrors have only" pool --remove ata-A --mode vdev --dry-run

echo "-- unknown mode"
echo two > "$SCEN"
check_out "an unknown --mode is refused" "detach or vdev" pool --remove ata-A --mode foo --dry-run

rm -f /etc/hs/bulk-type
finish
