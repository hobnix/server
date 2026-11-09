"""Read a Proxmox vzdump archive WITHOUT extracting it (scripts/import-vzdump.sh). Standard library (+ the zstd binary for .zst).

  vzdump_import.py <archive>

Prints rows, tab separated: kind, level, where, text (kind kind|summary|map|unmapped|top; level info|warn).
Only etc/vzdump/pct.conf is read (at most 64 KB); every other member is counted and never written to disk. An LXC archive
(vzdump-lxc-*.tar[.gz|.zst|.lzo-not-supported]) gets a mapping to Incus settings; a VM archive (vzdump-qemu-*.vma[.zst|.gz|.lzo]) is only
recognised: disk conversion is a separate decision (docs/adr/0024). Exit 0 ok, 2 not readable (message on stderr).
UNVERIFIED on archives made by a real Proxmox beyond the fixtures built in tests/import-vzdump.sh.
"""
import re
import subprocess
import sys
import tarfile

MAX_CONF = 64 * 1024


def die(msg):
    sys.stderr.write(msg + "\n")
    sys.exit(2)


def clean(s):
    return re.sub(r"[\t\r\n]", " ", s)


def opener(path):
    """(file object, closer) for the raw tar stream."""
    with open(path, "rb") as f:
        head = f.read(8)
    if head[:4] == b"\x28\xb5\x2f\xfd":
        try:
            p = subprocess.Popen(["zstd", "-dc", "--", path], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        except OSError:
            die("this archive is zstd compressed and the zstd program is missing")
        return p.stdout, lambda: (p.stdout.close(), p.kill(), p.wait())
    if head[:4] == b"VMA\x00":
        return None, None
    if head[:4] == b"\x89LZO":
        die("lzo compressed archives are not supported: recompress with zstd -d / lzop -d first")
    f = open(path, "rb")
    return f, f.close


def parse_conf(text):
    conf = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("["):   # [pve:pending] and snapshot sections are not the current config
            break
        k, sep, v = line.partition(":")
        if sep:
            conf[k.strip()] = v.strip()
    return conf


def kvs(v):
    d = {}
    for part in v.split(","):
        k, sep, val = part.partition("=")
        d[k.strip()] = val.strip() if sep else ""
    return d


def main(argv):
    if len(argv) != 1:
        die("usage: vzdump_import.py <archive>")
    path = argv[0]
    base = path.rsplit("/", 1)[-1]
    try:
        stream, close = opener(path)
    except OSError as e:
        die("cannot read the archive: %s" % e.strerror)
    rows = []
    if stream is None:
        rows.append(["summary", "info", "kind", "VM archive (VMA)"])
        rows.append(["unmapped", "warn", "disks", "a VM archive holds disk images in the VMA format; converting them (vma extract, qemu-img) is a separate decision and is not done here"])
        rows.append(["unmapped", "warn", "restore", "restoring into an Incus VM is not built"])
        emit(rows)
        return
    conf_text = None
    n_files = n_bytes = 0
    tops = {}
    try:
        with tarfile.open(fileobj=stream, mode="r|*") as tf:
            for m in tf:
                name = m.name.lstrip("./")
                n_files += 1
                n_bytes += max(m.size, 0)
                top = name.split("/", 1)[0] or "."
                tops[top] = tops.get(top, 0) + 1
                if name == "etc/vzdump/pct.conf" and m.isfile() and m.size <= MAX_CONF:
                    conf_text = tf.extractfile(m).read().decode("utf-8", "replace")
    except (tarfile.TarError, EOFError, OSError):
        die("not a readable tar archive (a vzdump LXC archive is a tar, optionally gz or zst)")
    finally:
        if close:
            close()
    rows.append(["summary", "info", "kind", "LXC archive"])
    rows.append(["summary", "info", "entries", "%d files, %d bytes unpacked" % (n_files, n_bytes)])
    for t in sorted(tops, key=lambda k: -tops[k])[:8]:
        rows.append(["top", "info", t, "%d entries" % tops[t]])
    if conf_text is None:
        rows.append(["unmapped", "warn", "pct.conf", "etc/vzdump/pct.conf is not in the archive: not a vzdump LXC archive, nothing can be mapped"])
        emit(rows)
        return
    c = parse_conf(conf_text)
    if "hostname" in c:
        rows.append(["map", "info", "hostname", "instance name: %s (check it is a valid Hobnix name)" % c["hostname"]])
    if "ostype" in c:
        rows.append(["map", "info", "ostype", "%s: the root file system comes from the archive, no image is downloaded" % c["ostype"]])
    arch = c.get("arch", "amd64")
    rows.append(["map", "info" if arch == "amd64" else "warn", "arch", arch if arch == "amd64" else "%s: this server runs amd64 only" % arch])
    if "cores" in c:
        rows.append(["map", "info", "cores", "limits.cpu=%s" % c["cores"]])
    if "memory" in c:
        rows.append(["map", "info", "memory", "limits.memory=%sMiB" % c["memory"]])
    if c.get("unprivileged") == "1":
        rows.append(["map", "info", "unprivileged", "security.privileged=false (Incus default); file owners in the archive are shifted by the id map: UNVERIFIED"])
    else:
        rows.append(["unmapped", "warn", "privileged", "the container ran privileged; Hobnix instances are unprivileged, file owners and device access need a decision"])
    feats = kvs(c.get("features", ""))
    if feats.get("nesting") == "1":
        rows.append(["map", "info", "features", "nesting=1 -> security.nesting=true"])
    for k in sorted(feats):
        if k not in ("nesting", ""):
            rows.append(["unmapped", "warn", "features", "%s is not mapped" % k])
    if "rootfs" in c:
        rf = kvs(c["rootfs"].split(",", 1)[1]) if "," in c["rootfs"] else {}
        rows.append(["map", "info", "rootfs", "root disk size=%s (the volume name %s is a Proxmox storage and means nothing here)" % (rf.get("size", "?"), clean(c["rootfs"].split(",")[0]))])
    for k in sorted(c):
        if re.fullmatch(r"net\d+", k):
            n = kvs(c[k])
            ip = n.get("ip", "-")
            rows.append(["unmapped", "warn", k, "bridge %s, ip %s, vlan %s: the NIC is not mapped; the instance gets Hobnix's network and DHCP, set static addresses by hand" % (n.get("bridge", "-"), ip, n.get("tag", "-"))])
        elif re.fullmatch(r"(mp|unused)\d+", k):
            rows.append(["unmapped", "warn", k, "%s: mount points and extra volumes are not in the rootfs and are not restored" % clean(c[k])])
        elif k in ("swap", "cpulimit", "cpuunits", "nameserver", "searchdomain", "startup", "onboot", "protection", "tags", "lock", "template", "cmode", "console", "tty", "lxc.apparmor.profile"):
            rows.append(["unmapped", "warn", k, "%s: not mapped" % clean(c[k])])
        elif k.startswith("lxc."):
            rows.append(["unmapped", "warn", k, "raw LXC setting %s is not mapped" % clean(c[k])])
    rows.append(["unmapped", "warn", "restore", "restoring into an Incus instance is not built; only this read-only plan is (docs/adr/0024)"])
    emit(rows)


def emit(rows):
    for r in rows:
        print("\t".join(clean(x) for x in r))


if __name__ == "__main__":
    main(sys.argv[1:])
