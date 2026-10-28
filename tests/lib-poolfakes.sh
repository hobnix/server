# shellcheck shell=bash
# Fake zpool, lsblk, find, df ... for the tests of manage-pool.sh that need no root and no disks (sourced after
# tests/lib.sh by pool-look.sh and pool-bare.sh). The fake zpool's scenario is the word in $SCEN (one, two, three,
# new); SnapRAID members are the labels in $WORK/labels and $WORK/labels.size; HS_BULK_TYPE_FILE tells the script
# the layout. Free disks: ata-FAKE_sdy and ata-FAKE_sdz (4 GB each). Members of the ZFS scenarios: ata-A, ata-B
# (mirror-0), ata-C (three), ata-D, ata-E (mirror-1, two).
BIN=$WORK/bin; mkdir -p "$BIN"
SCEN=$WORK/scenario
BT=$WORK/bulk-type
export HS_BULK_TYPE_FILE=$BT
REALFIND=$(command -v find)

cat > "$BIN/zpool" <<FAKE
#!/usr/bin/env bash
sc=\$(cat "$SCEN")
case "\$1" in
  status)
    echo "  pool: bulk"; echo " config:"; echo
    printf '\tNAME\t\tSTATE\tREAD WRITE CKSUM\n'
    printf '\tbulk\tONLINE\t0 0 0\n'
    printf '\t  mirror-0\tONLINE\t0 0 0\n\t    /dev/disk/by-id/ata-A-part1\tONLINE\t0 0 0\n\t    /dev/disk/by-id/ata-B-part1\tONLINE\t0 0 0\n'
    case "\$sc" in
      three) printf '\t    /dev/disk/by-id/ata-C-part1\tONLINE\t0 0 0\n' ;;
      two) printf '\t  mirror-1\tONLINE\t0 0 0\n\t    /dev/disk/by-id/ata-D-part1\tONLINE\t0 0 0\n\t    /dev/disk/by-id/ata-E-part1\tONLINE\t0 0 0\n' ;;
    esac ;;
  list)
    # "zpool list -H fast" fails: the pool does not exist yet (scenario new)
    [ "\$sc" != new ] || exit 1
    case "\$*" in
      "list -H "*) printf 'bulk\t8TB\t3TB\tONLINE\n'; exit 0 ;;
    esac
    printf 'bulk\t8000000000\t3000000000\t5000000000\n'
    printf '\tmirror-0\t4000000000\t2000000000\t2000000000\n'
    printf '\tmirror-1\t4000000000\t1000000000\t3000000000\n' ;;
esac
FAKE
cat > "$BIN/lsblk" <<FAKE
#!/usr/bin/env bash
case "\$*" in
  "-dnb -o NAME,SIZE,TYPE,ROTA,MODEL,SERIAL") printf 'sdy 4000000000 disk 1 MODEL SERY\nsdz 4000000000 disk 1 MODEL SERZ\n' ;;
  "-nr -o PATH "*) echo "\${@: -1}" ;;
  "-nr -o LABEL") cat "$WORK/labels" 2>/dev/null ;;
  "-nrb -o LABEL,SIZE") cat "$WORK/labels.size" 2>/dev/null ;;
  "-dnb -o SIZE "*) echo 4000000000 ;;
esac
exit 0
FAKE
cat > "$BIN/find" <<FAKE
#!/usr/bin/env bash
# the stable names of /dev/disk/by-id: ata-FAKE_<kernel name>
if [ "\$1" = /dev/disk/by-id ]; then
  for a; do case "\$a" in */sd?) echo "ata-FAKE_\${a##*/}" ;; esac; done
  exit 0
fi
exec "$REALFIND" "\$@"
FAKE
cat > "$BIN/df" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *used*) printf 'Used\n1000000000\n' ;;
  *avail*) printf 'Avail\n3000000000\n' ;;
  *pcent*) printf 'Use%%\n 40%%\n' ;;
esac
FAKE
for c in blkid zfs findmnt setfattr udevadm; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$c"; done
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/mountpoint"   # everything is mounted
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"
printf 'bulk-data-01\nbulk-data-02\nbulk-parity-1\n' > "$WORK/labels"
printf 'bulk-data-01 4000000000\nbulk-data-02 4000000000\nbulk-parity-1 4000000000\n' > "$WORK/labels.size"

# run <layout zfs|snapraid> <zpool scenario> <args...>: stdin is empty (no answers); HS_ANSWERS feeds answers
run() {
  local layout=$1 sc=$2; shift 2
  echo "$layout" > "$BT"; echo "$sc" > "$SCEN"
  printf '%b' "${HS_ANSWERS:-}" | bash "${HS_POOL_SCRIPT:-$SCRIPTS/manage-pool.sh}" "$@" 2>&1
}
