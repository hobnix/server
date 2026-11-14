#!/usr/bin/env bash
# Rebuild rehearsal, the part a plain VM can show (docs/backup-and-recovery.md, "Practise"): VM A holds shares and host files and writes a
# restic backup onto a block volume labelled "backup"; VM A and its data are deleted; a clean VM B gets ONLY that volume and the
# passphrase, and the restore must bring back the host files and every share file with the same checksums.
# Not covered: nixos-install, boot order, the vault, hs rebuild, pools (Case A steps 5-11 of the guide; a manual rehearsal).
# Run on the server as a user who may use incus (no root):   bash tests/rebuild-vm.sh [--keep]
# First run on hardware 2026-11-10 (#415): the read-only volume needs restic --no-lock.
# Not part of tests/run.sh and not run by CI: it needs Incus with KVM and the internet. `scripts/dev/t vm` runs it.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
keep=false; [ "${1:-}" = --keep ] && keep=true
pool=${HS_INCUS_POOL:-default}
a=hs-rebuild-a-$$; b=hs-rebuild-b-$$; vol=hs-rebuild-backup-$$
pw=$(head -c 24 /dev/urandom | base64 | tr -d '/+=\n')   # the passphrase: reaches the VMs through stdin only, never argv or the environment
T_PASS=0; T_FAIL=0
pass() { T_PASS=$((T_PASS + 1)); echo "  ok    $*"; }
fail() { T_FAIL=$((T_FAIL + 1)); echo "  FAIL  $*"; }

cleanup() {
  $keep && { echo "kept: incus delete -f $a $b; incus storage volume delete $pool $vol"; return; }
  incus delete -f "$a" >/dev/null 2>&1; incus delete -f "$b" >/dev/null 2>&1
  incus storage volume delete "$pool" "$vol" >/dev/null 2>&1
}
trap cleanup EXIT

launch() {   # launch <name>: a fresh Ubuntu VM with restic and the repository scripts; retried, the launch sometimes hangs
  local vm=$1 ok=false try
  for try in 1 2 3; do
    if timeout 300 incus launch images:ubuntu/24.04 "$vm" --vm >/dev/null 2>&1; then ok=true; break; fi
    echo "launch hung or failed (try $try), cleaning up and retrying"; incus delete -f "$vm" >/dev/null 2>&1
  done
  $ok || { fail "the VM $vm did not start"; return 1; }
  for _ in $(seq 1 60); do incus exec "$vm" -- true >/dev/null 2>&1 && break; sleep 3; done
  incus exec "$vm" -- bash -c 'for i in 1 2 3 4 5 6 7 8 9 10; do apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq restic e2fsprogs >/dev/null && exit 0; sleep 6; done; exit 1' \
    || { fail "installing restic in $vm (internet?)"; return 1; }
}
backup_dev() {   # the block device of the volume, found by its serial; the volume has no label until VM A formats it
  incus exec "$1" -- bash -c 'for d in /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_incus_*; do case $d in *-part*|*_incus_root) ;; *) readlink -f "$d"; exit 0 ;; esac; done; exit 1'
}

echo "== volume and VM A (the old server)"
incus storage volume create "$pool" "$vol" --type=block size=2GiB >/dev/null || { echo "FAIL  volume"; exit 1; }
launch "$a" || exit 1
incus storage volume attach "$pool" "$vol" "$a" >/dev/null || { echo "FAIL  attach to A"; exit 1; }
sleep 5
echo "== A: seed shares and host files, back up"
incus exec "$a" -- bash -s <<'INNER' || { echo "FAIL  seeding or backing up in A"; exit 1; }
set -euo pipefail
dev=$(for d in /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_incus_*; do case $d in *-part*|*_incus_root) ;; *) readlink -f "$d"; break ;; esac; done)
mkfs.ext4 -q -L backup "$dev"
mkdir -p /mnt/backup && mount "$dev" /mnt/backup
mkdir -p /bulk/shares/photos/2024 /bulk/shares/docs /var/lib/hs /etc/hs
dd if=/dev/urandom of=/bulk/shares/photos/2024/big.bin bs=1M count=20 status=none
echo "birthday" > /bulk/shares/photos/2024/note.txt
printf 'äöü ß file with spaces\n' > "/bulk/shares/docs/Annual Report.txt"
printf 'machineName = "oldbox"\n' > /etc/hs/machine.toml
echo "state" > /var/lib/hs/some-state
( cd / && find bulk etc/hs var/lib/hs -type f -print0 | sort -z | xargs -0 sha256sum ) > /root/manifest
INNER
printf '%s\n' "$pw" | incus exec "$a" -- bash -c '
set -euo pipefail
umask 077; cat > /root/pw
R() { restic -r /mnt/backup/restic --password-file /root/pw "$@"; }
R init >/dev/null
R backup --tag shares /bulk/shares >/dev/null
R backup --tag host /etc/hs /var/lib/hs >/dev/null
R check >/dev/null
sync; umount /mnt/backup'  || { echo "FAIL  restic backup in A"; exit 1; }
incus file pull "$a/root/manifest" "${TMPDIR:-/tmp}/$a.manifest" >/dev/null || { echo "FAIL  manifest"; exit 1; }

echo "== VM A and its data are destroyed; only the backup volume survives"
incus storage volume detach "$pool" "$vol" "$a" >/dev/null || { echo "FAIL  detach"; exit 1; }
incus delete -f "$a" >/dev/null || { echo "FAIL  delete A"; exit 1; }

echo "== VM B (the new server): the volume and the passphrase, nothing else"
launch "$b" || exit 1
incus storage volume attach "$pool" "$vol" "$b" >/dev/null || { echo "FAIL  attach to B"; exit 1; }
sleep 5
incus file push -q "${TMPDIR:-/tmp}/$a.manifest" "$b/root/manifest" >/dev/null
rm -f "${TMPDIR:-/tmp}/$a.manifest"
printf '%s\n' "$pw" | incus exec "$b" -- env HS_PLAIN=1 bash -c '
umask 077; cat > /root/pw
umask 022
n=0
pass() { n=$((n+1)); echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; bad=1; }
bad=0
dev=$(for d in /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_incus_*; do case $d in *-part*|*_incus_root) ;; *) readlink -f "$d"; break ;; esac; done)
mkdir -p /mnt/backup && mount -o ro "$dev" /mnt/backup && pass "the backup volume mounts" || { fail "mount"; exit 1; }
# the volume is read-only on purpose (the rehearsal must not write to the backup), so restic takes no lock and keeps no cache (as backup.sh does)
R() { restic -r /mnt/backup/restic --password-file /root/pw --no-lock --no-cache "$@"; }
err=/root/restic-err
shown() { sed "s/^/      restic: /" "$err" | head -n 5; }   # restic message of the failed call, indented
R snapshots --tag host 2>"$err" | grep -q host && pass "the host snapshot is listed with the passphrase" || { fail "no host snapshot"; shown; }
R snapshots --tag shares 2>"$err" | grep -q shares && pass "the shares snapshot is listed" || { fail "no shares snapshot"; shown; }
printf wrong > /root/pw-bad
if restic -r /mnt/backup/restic --password-file /root/pw-bad --no-lock --no-cache snapshots >/dev/null 2>"$err"; then fail "a wrong passphrase opened the repository"
elif grep -qi "wrong password" "$err"; then pass "a wrong passphrase is refused"
else fail "a wrong passphrase failed, but not with a wrong-password message"; shown; fi
R check >/dev/null 2>"$err" && pass "restic check is clean" || { fail "restic check"; shown; }
# the guide: host files back into place, shares into a separate folder first
R restore latest --tag host --target / >/dev/null 2>"$err" && pass "host files restored" || { fail "host restore"; shown; }
grep -q oldbox /etc/hs/machine.toml && pass "machine.toml is back with its content" || fail "machine.toml differs"
mkdir -p /bulk/shares/restored
R restore latest --tag shares --target /bulk/shares/restored >/dev/null 2>"$err" && pass "shares restored" || { fail "share restore"; shown; }
miss=0
while read -r sum path; do
  case $path in bulk/*) f=/bulk/shares/restored/$path ;; *) f=/$path ;; esac
  [ "$(sha256sum "$f" 2>/dev/null | cut -d" " -f1)" = "$sum" ] || { echo "    differs or missing: $path"; miss=$((miss+1)); }
done < <(sed "s/  / /" /root/manifest)
[ "$miss" -eq 0 ] && pass "every file has the same checksum as before ($(wc -l < /root/manifest) files)" || fail "$miss files differ"
echo "  -> $n ok"
exit $bad' 
rc=$?
if [ $rc -eq 0 ]; then pass "rebuild rehearsal in B"; else fail "rebuild rehearsal in B (exit $rc)"; fi
echo "  -> $T_PASS ok, $T_FAIL failed, 0 skipped"
[ "$T_FAIL" -eq 0 ]
