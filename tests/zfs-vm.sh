#!/usr/bin/env bash
# The real ZFS replace / detach / remove flows of manage-pool.sh, in a throwaway Incus VM.
# Run on the server as a user who may use incus (no root needed):   bash tests/zfs-vm.sh [--keep]
# Creates the VM hs-zfs-test-<pid> (Ubuntu 24.04, which ships the ZFS module) and a few block volumes
# on the default pool, runs the checks inside, then deletes everything (--keep leaves it for a look).
# Not part of tests/run.sh and not run by CI: it needs Incus with KVM and the internet.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
keep=false; [ "${1:-}" = --keep ] && keep=true
vm=hs-zfs-test-$$
pool=${HS_INCUS_POOL:-default}
vols=()

cleanup() {
  $keep && { echo "kept: incus delete -f $vm; incus storage volume delete $pool <volume>"; return; }
  incus delete -f "$vm" >/dev/null 2>&1
  for v in "${vols[@]}"; do incus storage volume delete "$pool" "$v" >/dev/null 2>&1; done
}
trap cleanup EXIT

echo "== VM $vm"
launched=false
for try in 1 2 3; do
  if timeout 300 incus launch images:ubuntu/24.04 "$vm" --vm >/dev/null 2>&1; then launched=true; break; fi
  echo "launch hung or failed (try $try), cleaning up and retrying"
  incus delete -f "$vm" >/dev/null 2>&1
done
$launched || { echo "FAIL  the VM did not start"; exit 1; }
for _ in $(seq 1 60); do incus exec "$vm" -- true >/dev/null 2>&1 && break; sleep 3; done

# six 2 GB disks, one 3 GB (bigger replacement), one 1 GB (too small)
i=0
for size in 2 2 2 2 2 2 3 1; do
  i=$((i + 1)); v=$vm-d$i; vols+=("$v")
  incus storage volume create "$pool" "$v" --type=block size="${size}GiB" >/dev/null || { echo "FAIL  volume $v"; exit 1; }
  incus storage volume attach "$pool" "$v" "$vm" >/dev/null || { echo "FAIL  attach $v"; exit 1; }
done
sleep 5

echo "== install ZFS in the VM"
incus exec "$vm" -- bash -c 'for i in 1 2 3 4 5 6 7 8 9 10; do apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zfsutils-linux gdisk util-linux jq >/dev/null && exit 0; sleep 6; done; exit 1' \
  || { echo "FAIL  installing zfsutils-linux (internet?)"; exit 1; }
incus exec "$vm" -- modprobe zfs || { echo "FAIL  zfs module"; exit 1; }
incus exec "$vm" -- mkdir -p /root/hs /etc/hs
incus file push -r -q "$here/scripts" "$here/tests" "$vm/root/hs/" >/dev/null || { echo "FAIL  copying the scripts"; exit 1; }

echo "== checks"
incus exec "$vm" -- env HS_PLAIN=1 bash -s <<'INNER'
set -uo pipefail
cd /root/hs
. tests/lib.sh
echo zfs > /etc/hs/bulk-type
S=/root/hs/scripts
ids() { ls /dev/disk/by-id | grep -E '^scsi-0QEMU_QEMU_HARDDISK_incus_' | grep -v -- '-part' | sort; }
mapfile -t D < <(ids)
[ "${#D[@]}" -ge 8 ] || { fail "expected 8 disks, found ${#D[@]}"; finish; exit 1; }
# the disks by size: 2 GB x6, then 3 GB, then 1 GB (lsblk order of sizes)
mapfile -t BY_SIZE < <(for d in "${D[@]}"; do echo "$(lsblk -dnb -o SIZE "/dev/disk/by-id/$d") $d"; done | sort -n | awk '{print $2}')
SMALL=${BY_SIZE[0]}; BIG=${BY_SIZE[7]}; M=("${BY_SIZE[@]:1:6}")
mp() { bash "$S/manage-pool.sh" bulk "$@" 2>&1; }
resilver_done() { for _ in $(seq 1 120); do zpool status bulk | grep -q 'resilver in progress' || return 0; sleep 2; done; return 1; }
vdevs() { zpool status bulk | grep -c '^[[:space:]]*mirror-'; }

echo "-- setup: two mirrors"
zpool create -f -o ashift=12 -o autoexpand=on bulk mirror "/dev/disk/by-id/${M[0]}" "/dev/disk/by-id/${M[1]}" mirror "/dev/disk/by-id/${M[2]}" "/dev/disk/by-id/${M[3]}"
check "pool exists with 2 mirrors" test "$(vdevs)" = 2
dd if=/dev/urandom of=/bulk/blob bs=1M count=300 status=none; sync

echo "-- replace with a smaller disk is refused"
check_out "smaller refused" "smaller than the one it replaces" bash -c "echo ${M[0]} | bash $S/manage-pool.sh bulk --replace ${M[0]} --disks $SMALL"

echo "-- replace with an equal disk"
out=$(echo "${M[0]}" | bash "$S/manage-pool.sh" bulk --replace "${M[0]}" --disks "${M[4]}" 2>&1)
check_out "replace runs zpool replace" "zpool replace bulk" echo "$out"
check "resilver finishes" resilver_done
check "the old disk is out of the pool" bash -c "! zpool status bulk | grep -q ${M[0]}"
check "the data is intact" bash -c "zpool status bulk | grep -q 'errors: No known data errors'"

echo "-- replace with a bigger disk"
out=$(echo "${M[1]}" | bash "$S/manage-pool.sh" bulk --replace "${M[1]}" --disks "$BIG" 2>&1)
check "resilver finishes (bigger)" resilver_done
check "pool still ONLINE" bash -c "zpool status bulk | grep -q 'state: ONLINE'"

echo "-- detach from a 2-disk mirror warns"
check_out "the warning" "alone in its vdev" mp --remove "${M[4]}" --mode detach --dry-run

echo "-- 3-way mirror, then detach without a warning"
zpool attach bulk "/dev/disk/by-id/${M[2]}-part1" "/dev/disk/by-id/${M[5]}" 2>&1 || zpool attach -f bulk "/dev/disk/by-id/${M[2]}" "/dev/disk/by-id/${M[5]}"
resilver_done
out=$(echo "${M[5]}" | bash "$S/manage-pool.sh" bulk --remove "${M[5]}" 2>&1)
check_out "detach of one disk of three" "keeps working with 2 disks" echo "$out"
check "back to two disks in that mirror" bash -c "[ \$(zpool status bulk | grep -c 'ONLINE') -ge 5 ]"

echo "-- remove a whole mirror"
out=$(echo "${M[4]}" | bash "$S/manage-pool.sh" bulk --remove "${M[4]}" --mode vdev 2>&1)
check_out "says the mirror is removed" "mirror will be removed" echo "$out"
for _ in $(seq 1 120); do zpool status bulk | grep -q 'remove:.*in progress\|Evacuation' || break; sleep 2; done
check "one mirror left" test "$(vdevs)" = 1
check "the data is still there" bash -c "[ \$(stat -c %s /bulk/blob) = 314572800 ]"

echo "-- the only vdev cannot be removed"
SOLE=$(zpool status -P bulk | awk '/\/dev\/disk\/by-id/ { n = $1; sub(/.*\//, "", n); sub(/-part[0-9]+$/, "", n); print n; exit }')
check_out "only vdev refused" "only vdev|only mirror" mp --remove "$SOLE" --mode vdev --dry-run
finish
INNER
rc=$?
exit $rc
