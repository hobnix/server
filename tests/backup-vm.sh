#!/usr/bin/env bash
# hs backup ct on a virtual machine: the export file is made, backed up with the tags ct:<name> and vm, and deleted; the dump
# hook runs first; the domain controller is not exported; the container drill leaves VM snapshots alone and the VM drill reads
# the tar out of restic. No root, no incus, no restic: fakes stand in.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1
BIN=$WORK/bin; ST=$WORK/state; mkdir -p "$WORK/incus/ct1/rootfs/etc" "$BIN" "$ST/backup-dump" "$WORK/mnt/restic" "$WORK/vmx" "$WORK/bulk"
: > "$WORK/mnt/restic/config"; echo pw > "$ST/restic-password"

cat > "$BIN/incus" <<'F'
#!/bin/sh
echo "incus $*" >> "$FAKE_LOG"
case "$1" in
  info) exit 0 ;;
  query)
    case "$2" in
      "/1.0/instances/vm1?recursion=1") echo '{"state":{"disk":{"root":{"usage":1000}}}}' ;;
      /1.0/instances/vm1) echo '{"type":"virtual-machine","status":"Running"}' ;;
      /1.0/instances/dc1) echo '{"type":"virtual-machine","status":"Running"}' ;;
      /1.0/instances/ct1) echo '{"type":"container","status":"Running"}' ;;
    esac ;;
  export) printf 'FAKE-TAR' > "$3" ;;
  list) echo ;;
esac
exit 0
F
cat > "$BIN/restic" <<'F'
#!/bin/sh
# restic -r <repo> --password-file <f> <cmd> ...
shift 4
echo "restic $*" >> "$FAKE_LOG"
case "$1" in
  backup) for a in "$@"; do case "$a" in */hs-vm-export/*.tar) echo "backed-up-file-content: $(cat "$a")" >> "$FAKE_LOG" ;; esac; done ;;
  snapshots) if [ -n "${FAKE_SNAPS:-}" ]; then cat "$FAKE_SNAPS"; else echo '[]'; fi ;;
  dump) cat "$FAKE_TAR" ;;
esac
exit 0
F
# a tiny jq for what backup.sh asks of it here (-r, `.a.b`, `.a.b // empty`, `.a.b // 0`, `length`), when the real one is not installed
if ! have jq; then
  cat > "$BIN/jq" <<'J'
#!/usr/bin/env python3
import json, sys
args = [a for a in sys.argv[1:] if a != "-r"]
expr = args[0].strip()
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
if expr == "length":
    print(len(data)); sys.exit(0)
default = None
if "//" in expr:
    expr, d = [x.strip() for x in expr.split("//", 1)]
    default = "" if d == "empty" else d
for k in [k for k in expr.split(".") if k]:
    data = data.get(k) if isinstance(data, dict) else None
if data is None:
    data = default
if data is not None and data != "":
    print(data)
J
  chmod +x "$BIN/jq"
fi
have flock || printf '#!/bin/sh
exit 0
' > "$BIN/flock"   # (not on every machine; nothing else runs here)
chmod +x "$BIN"/*
export FAKE_LOG=$WORK/log
export PATH="$BIN:$PATH" HS_STATE_DIR=$ST HS_BACKUP_MOUNT=$WORK/mnt HS_BACKUP_REPO=$WORK/mnt/restic HS_BACKUP_NO_MOUNT=1 HS_BULK=$WORK/bulk
export HS_BACKUP_CACHE=$WORK/cache HS_BACKUP_HOST_FILES="" HS_VM_EXPORT_DIR=$WORK/vmx HS_INCUS_ROOT=$WORK/incus HS_DISKS_ROOT=$WORK/disks
hsb() { bash "$SCRIPTS/backup.sh" "$@"; }

echo "-- switching a VM on"
check_out "a VM is said to be exported whole" "virtual machine as one export file" hsb ct vm1 on
check_out "the VM is in the list" "^vm1$" cat "$ST/backup-instances"

echo "-- the nightly run"
printf '# dump:db\nhs-dump postgres vm1 vm1\n' > "$ST/backup-dump/vm1"
hsb ct dc1 on >/dev/null 2>&1; hsb ct ct1 on >/dev/null 2>&1
: > "$FAKE_LOG"
hsb now >"$WORK/now.out" 2>&1 || true
check_out "the dump command runs inside the VM" "incus exec vm1 -- sh -c hs-dump postgres vm1 vm1" cat "$FAKE_LOG"
check_out "incus export is asked for an uncompressed instance-only file" "incus export vm1 .*hs-vm-export/vm1.tar --instance-only --compression none" cat "$FAKE_LOG"
check_out "restic backs the file up with ct:vm1 and vm" "restic backup .*--tag ct:vm1 --tag vm .*hs-vm-export/vm1.tar" cat "$FAKE_LOG"
check_out "the file existed when restic read it" "backed-up-file-content: FAKE-TAR" cat "$FAKE_LOG"
check "the export file is deleted afterwards" test ! -e "$WORK/vmx/hs-vm-export/vm1.tar"
if grep -q "incus export dc1" "$FAKE_LOG"; then fail "the domain controller is not exported"; else pass "the domain controller is not exported"; fi
check_out "the domain controller is explained" "samba backup file" cat "$WORK/now.out"
check_out "a container is still backed up by its files" "ct:ct1" cat "$FAKE_LOG"

echo "-- not enough room"
cat > "$BIN/df" <<'F'
#!/bin/sh
printf 'Avail\n10\n'
F
chmod +x "$BIN/df"
: > "$FAKE_LOG"
hsb now >"$WORK/now2.out" 2>&1 || true
if grep -q "incus export vm1" "$FAKE_LOG"; then fail "no export when the free space is too small"; else pass "no export when the free space is too small"; fi
check_out "the lack of space is said" "needs about" cat "$WORK/now2.out"
rm -f "$BIN/df"

echo "-- the drills"
snaps='[{"id":"aaa","time":"2026-10-01T00:00:00Z","tags":["ct:ct1"]},{"id":"bbb","time":"2026-10-02T00:00:00Z","tags":["ct:vm1","vm"]}]'
check_eq "newest ct skips the VM snapshots" "ct1	aaa" "$(printf '%s' "$snaps" | python3 "$SCRIPTS/lib/ct-image.py" newest ct | tr -d '\r')"
check_eq "newest vm finds only them" "vm1	bbb" "$(printf '%s' "$snaps" | python3 "$SCRIPTS/lib/ct-image.py" newest vm | tr -d '\r')"
check_eq "newest without an argument is the container list" "ct1	aaa" "$(printf '%s' "$snaps" | python3 "$SCRIPTS/lib/ct-image.py" newest | tr -d '\r')"
printf '%s' "$snaps" > "$WORK/snaps.json"; export FAKE_SNAPS=$WORK/snaps.json
printf 'backup/index.yaml\nbackup/virtual-machine/root.img\n' > "$WORK/list.txt"
tar -cf "$WORK/good.tar" -C "$WORK" list.txt 2>/dev/null
mkdir -p "$WORK/t/backup/virtual-machine"; echo y > "$WORK/t/backup/index.yaml"; echo z > "$WORK/t/backup/virtual-machine/root.img"
tar -cf "$WORK/good.tar" -C "$WORK/t" backup
export FAKE_TAR=$WORK/good.tar
check_out "the VM drill reads the export file out of the backup" "comes out of the backup" hsb drill ct vm1
tar -cf "$WORK/bad.tar" -C "$WORK" list.txt
export FAKE_TAR=$WORK/bad.tar
if hsb drill ct vm1 >/dev/null 2>&1; then fail "the VM drill fails on a tar without index.yaml"; else pass "the VM drill fails on a tar without index.yaml"; fi

finish
