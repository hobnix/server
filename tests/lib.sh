# shellcheck shell=bash
# Helpers for the integration tests (tests/run.sh). They need root, loop devices and, for some
# tests, xfs, device-mapper (LUKS), restic, mergerfs. A test that cannot run on this machine
# says "skip"; in CI (REQUIRE_ALL=1) a skip counts as a failure, so nothing is silently untested.

T_PASS=0; T_FAIL=0; T_SKIP=0
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPTS=$ROOT/scripts
WORK=$(mktemp -d /tmp/hs-test.XXXXXX)
# mkloop runs in $(...), a subshell: what it creates is written to files, not to variables
LOOPS=$WORK/.loops
LINKS=$WORK/.links
# The disks of the array are mounted under /var/lib/hs/disks since the switch of ; these tests build their pools under /mnt/bulk (tests/bulkpath.sh and
# tests/bulk-switch.sh check the default).
export HS_DISKS_ROOT=${HS_DISKS_ROOT:-/mnt/bulk} HS_DETACHED_ROOT=${HS_DETACHED_ROOT:-/mnt/bulk}

pass() { T_PASS=$((T_PASS + 1)); echo "  ok    $*"; }
fail() { T_FAIL=$((T_FAIL + 1)); echo "  FAIL  $*"; }
skip() {
  if [ -n "${REQUIRE_ALL:-}" ]; then T_FAIL=$((T_FAIL + 1)); echo "  FAIL  (cannot be skipped in CI) $*"
  else T_SKIP=$((T_SKIP + 1)); echo "  skip  $*"; fi
}
# free_port: prints a TCP port nobody listens on (asks the kernel for one). A test never hard-codes a port: two tests at the same time, or a
# leftover process, would make it fail for no reason.
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
check() {   # check "what" command...: passes when the command succeeds
  local what=$1; shift
  if "$@" >/dev/null 2>&1; then pass "$what"; else fail "$what"; fi
}
check_eq() {   # check_eq "what" expected actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}
check_out() {   # check_out "what" regex command...: output of the command matches
  local what=$1 re=$2 out; shift 2
  out=$("$@" 2>&1 || true)
  if grep -Eq "$re" <<<"$out"; then pass "$what"; else fail "$what (no '$re' in: $(head -c 300 <<<"$out" | tr '\n' ' '))"; fi
}

# Mounts the tests make (the pool, the data disks, /bulk). A leftover one of an earlier test or of the machine itself is in the way.
# mountpoint(1) cannot be used for this: on a dead FUSE mount (mergerfs gone) it says "not a mountpoint" and mkdir says "File exists".
test_mounts() { awk '$5 ~ /^(\/bulk|\/mnt\/bulk|\/var\/lib\/hs\/disks)(\/|$)/ { print $5 }' /proc/self/mountinfo | sort -ru; }
# cleanup unmounts these paths only for a test that passed need_root and found them free at its start. A test without need_root, or a
# machine where they are in use (a real pool), never gets them unmounted by the EXIT trap.
POOL_MOUNTS_OURS=false
need_root() {
  [ "$(id -u)" -eq 0 ] || { echo "The integration tests need root (loop devices, mounts)."; exit 2; }
  local left
  left=$(test_mounts | tr '\n' ' ')
  if [ -n "$left" ]; then
    echo "  FAIL  these paths are mounted and the test needs them free: $left"
    echo "        Never run the root tests on a machine with a real pool: use a throwaway VM. If an earlier test left them in a test VM,"
    echo "        unmount them there (umount -l, deepest first) and run the test again. Nothing was unmounted."
    exit 1
  fi
  POOL_MOUNTS_OURS=true
}
have() { command -v "$1" >/dev/null 2>&1; }

mkloop() {   # mkloop <name> <size> -> device; /dev/disk/by-id/ata-TEST_<name> points at it
  local img=$WORK/$1.img dev
  truncate -s "$2" "$img"
  dev=$(losetup -f --show "$img")
  echo "$dev" >> "$LOOPS"
  mkdir -p /dev/disk/by-id
  ln -sf "$dev" "/dev/disk/by-id/ata-TEST_$1"
  echo "/dev/disk/by-id/ata-TEST_$1" >> "$LINKS"
  echo "$dev"
}

fs_works() {   # fs_works xfs|btrfs|ext4: can this kernel mount it?
  local dev m
  have "mkfs.$1" || return 1
  dev=$(mkloop "probe-$1" 300M)
  case "$1" in xfs) mkfs.xfs -q -f "$dev" ;; btrfs) mkfs.btrfs -q -f "$dev" ;; *) mkfs.ext4 -q -F "$dev" ;; esac >/dev/null 2>&1 || return 1
  m=$WORK/probe-mnt-$1; mkdir -p "$m"
  mount "$dev" "$m" 2>/dev/null || return 1
  umount "$m"
}
dm_works() {   # device-mapper / dm-crypt usable?
  local dev
  have cryptsetup || return 1
  dev=$(mkloop probe-luks 64M)
  printf x | cryptsetup luksFormat --batch-mode --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file - "$dev" >/dev/null 2>&1 || return 1
  printf x | cryptsetup open --key-file - "$dev" hs-probe >/dev/null 2>&1 || return 1
  cryptsetup close hs-probe
}

cleanup() {
  local m d
  for m in $(findmnt -rn -o TARGET | grep "^$WORK" | sort -r); do umount -l "$m" 2>/dev/null || true; done
  if $POOL_MOUNTS_OURS; then   # every mount of the pool, deepest first; a mount can be stacked, so look again until it is gone
    local i
    for i in 1 2 3; do
      for m in $(test_mounts); do umount -l "$m" 2>/dev/null || true; done
      [ -z "$(test_mounts)" ] && break
    done
  fi
  for d in /dev/mapper/hs-*; do [ -e "$d" ] && cryptsetup close "$(basename "$d")" 2>/dev/null; done
  [ ! -f "$LOOPS" ] || while read -r d; do [ -n "$d" ] && losetup -d "$d" 2>/dev/null; done < "$LOOPS"
  [ ! -f "$LINKS" ] || while read -r d; do [ -n "$d" ] && rm -f "$d"; done < "$LINKS"
  rm -rf "${WORK:?}"
}
trap cleanup EXIT

finish() {
  echo "  -> $T_PASS ok, $T_FAIL failed, $T_SKIP skipped"
  [ "$T_FAIL" -eq 0 ]
}
