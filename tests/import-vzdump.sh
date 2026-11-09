#!/usr/bin/env bash
# hs ct import-vzdump (scripts/import-vzdump.sh, scripts/lib/vzdump_import.py) on small archives built here with python (tar, tar.gz, and a fake VMA
# header). No Proxmox, no root. Real archives of a real Proxmox are not tested (UNVERIFIED).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi
export HS_LANG=en HS_PLAIN=1
IMP="bash $ROOT/scripts/import-vzdump.sh"
runi() { "$@" </dev/null 2>&1; }
mk=$WORK/mk.py
cat > "$mk" <<'PY'
import io, sys, tarfile
out, kind = sys.argv[1], sys.argv[2]
conf = """arch: amd64
cores: 2
features: nesting=1,fuse=1
hostname: web1
memory: 1024
net0: name=eth0,bridge=vmbr0,hwaddr=AA:BB:CC:DD:EE:FF,ip=192.168.1.5/24,tag=20,type=veth
ostype: debian
rootfs: local-zfs:subvol-100-disk-0,size=8G
mp0: /tank/media,mp=/media
swap: 512
unprivileged: 1
lxc.cgroup2.devices.allow: c 10:200 rwm
[pve:pending]
memory: 99999
"""
mode = "w:gz" if kind == "gz" else "w"
with tarfile.open(out, mode) as t:
    if kind != "noconf":
        b = conf.encode()
        i = tarfile.TarInfo("./etc/vzdump/pct.conf"); i.size = len(b); t.addfile(i, io.BytesIO(b))
    for n, d in (("./etc/hostname", b"web1\n"), ("./usr/bin/x", b"x")):
        i = tarfile.TarInfo(n); i.size = len(d); t.addfile(i, io.BytesIO(d))
PY
python3 "$mk" "$WORK/vzdump-lxc-100-2026_11_01.tar.gz" gz
python3 "$mk" "$WORK/vzdump-lxc-100.tar" plain
python3 "$mk" "$WORK/noconf.tar" noconf
printf 'VMA\0\1\2\3 rest' > "$WORK/vzdump-qemu-101.vma"
printf 'not an archive at all' > "$WORK/junk.tar"

echo "-- LXC archive"
for a in vzdump-lxc-100-2026_11_01.tar.gz vzdump-lxc-100.tar; do
  out=$(runi $IMP "$WORK/$a") && rc=0 || rc=$?
  check_eq "$a: exits 0" 0 "$rc"
  grep -q 'LXC archive' <<<"$out" && pass "$a: recognised as LXC" || fail "$a: not recognised"
  grep -q 'limits.cpu=2' <<<"$out" && grep -q 'limits.memory=1024MiB' <<<"$out" && pass "$a: cpu and memory mapped" || fail "$a: cpu/memory missing"
  grep -q 'security.nesting=true' <<<"$out" && pass "$a: nesting mapped" || fail "$a: nesting missing"
  grep -q 'fuse=1 is not mapped\|fuse is not mapped' <<<"$out" && pass "$a: fuse flagged" || fail "$a: fuse not flagged"
  grep -q 'mp0' <<<"$out" && pass "$a: mount point flagged" || fail "$a: mp0 missing"
  grep -q 'net0' <<<"$out" && pass "$a: NIC flagged" || fail "$a: net0 missing"
  grep -q 'raw LXC setting' <<<"$out" && pass "$a: raw lxc flagged" || fail "$a: raw lxc missing"
  grep -q '99999' <<<"$out" && fail "$a: read the pending section" || pass "$a: pending section ignored"
  grep -q 'restore.*not built' <<<"$out" && pass "$a: says the restore is not built" || fail "$a: no restore note"
done
ls "$WORK" | grep -qE '^(etc|usr)$' && fail "files were unpacked" || pass "nothing unpacked"

echo "-- other input"
out=$(runi $IMP "$WORK/vzdump-qemu-101.vma") && rc=0 || rc=$?
check_eq "VMA exits 0" 0 "$rc"
grep -q 'VM archive' <<<"$out" && grep -q 'separate decision' <<<"$out" && pass "VM archive only recognised" || fail "VM archive not handled"
out=$(runi $IMP "$WORK/noconf.tar") && rc=0 || rc=$?
check_eq "tar without pct.conf exits 0" 0 "$rc"
grep -q 'pct.conf is not in the archive' <<<"$out" && pass "missing pct.conf said" || fail "missing pct.conf not said"
out=$(runi $IMP "$WORK/junk.tar") && rc=0 || rc=$?
check_eq "junk refused" 1 "$rc"
out=$(runi $IMP "$WORK/none.tar") && rc=0 || rc=$?
check_eq "missing file refused" 1 "$rc"
out=$(runi $IMP) && rc=0 || rc=$?
check_eq "no argument refused" 1 "$rc"
finish
