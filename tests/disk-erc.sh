#!/usr/bin/env bash
# hs disk erc (scripts/disk-erc.sh): only members of a ZFS mirror or raidz get the error recovery time; fake zpool output, lsblk and smartctl.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_ERC_NOROOT=1
BIN=$WORK/bin; mkdir -p "$BIN"; export CALLS=$WORK/calls; : > "$CALLS"
cat > "$WORK/status.txt" <<'EOF'
  pool: tank
 state: ONLINE
config:

	NAME          STATE     READ WRITE CKSUM
	tank          ONLINE       0     0     0
	  mirror-0    ONLINE       0     0     0
	    /dev/sda1 ONLINE       0     0     0
	    /dev/sdb1 ONLINE       0     0     0
	  raidz1-1    ONLINE       0     0     0
	    /dev/sdc1 ONLINE       0     0     0
	    /dev/sdd1 ONLINE       0     0     0
	    /dev/sdg1 REMOVED      0     0     0
	    /dev/sdh1 FAULTED      0     0     0
	  /dev/sde1   ONLINE       0     0     0
	cache
	  /dev/sdf1   ONLINE       0     0     0

errors: No known data errors
EOF
cat > "$BIN/lsblk" <<'FAKE'
#!/usr/bin/env bash
p=${*: -1}; echo "$(basename "$p" | tr -d '0-9')"
FAKE
cat > "$BIN/smartctl" <<'FAKE'
#!/usr/bin/env bash
echo "smartctl $*" >> "$CALLS"
case "${*: -1}" in
  /dev/sdd) echo "SCT Commands not supported" ;;
  *) echo "SCT Error Recovery Control set to: Read: 70 (7.0 seconds), Write: 70 (7.0 seconds)" ;;
esac
FAKE
chmod +x "$BIN"/*
export PATH=$BIN:$PATH HS_ERC_STATUS=$WORK/status.txt
E="bash $SCRIPTS/disk-erc.sh"

check_eq "members: mirror and raidz disks only" "sda
sdb
sdc
sdd" "$($E list)"
out=$($E apply 2>&1)
check_eq "scterc is set on the members, once each" "4" "$(grep -c 'scterc,70,70' "$CALLS" | tr -d ' ')"
check_eq "a single disk and a cache disk are left alone" "0" "$(grep -c -e '/dev/sde\|/dev/sdf' "$CALLS" | tr -d ' ')"
check_eq "a REMOVED or FAULTED member is not touched" "0" "$(grep -c -e '/dev/sdg\|/dev/sdh' "$CALLS" | tr -d ' ')"
check_out "a disk without support is skipped with a note" "sdd: no ERC support" echo "$out"
printf 'pool: x\nconfig:\n\n  NAME   STATE\n  x      ONLINE\n    /dev/sda1 ONLINE\n\nerrors: none\n' > "$WORK/single.txt"
check_out "no mirror or raidz: nothing to do" "nothing to set" env HS_ERC_STATUS=$WORK/single.txt $E apply
finish
