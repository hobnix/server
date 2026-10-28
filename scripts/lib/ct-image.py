#!/usr/bin/env python3
"""Helpers for `hs backup drill ct` (scripts/backup.sh); stdlib only.

  ct-image.py build <rootfs> <out.tar.gz> <name>   unified Incus image: metadata.yaml + rootfs/
  ct-image.py newest [ct|vm]                       (vm: the snapshots tagged "vm", exports of virtual machines) stdin: `restic snapshots --json` -> "<container>\\t<snapshot id>" (newest per ct:<name> tag)
  ct-image.py field <key>                          stdin: one JSON object -> its value

A container's files on the host carry the SHIFTED ids (uid 0 inside = the id of the rootfs folder on the host,
usually 1000000). Incus shifts again when it unpacks an image, so the ids are brought back to 0.. here.
"""
import io, json, os, sys, tarfile, time, platform

ARCH = {"x86_64": "x86_64", "amd64": "x86_64", "aarch64": "aarch64", "arm64": "aarch64", "armv7l": "armv7l"}


def unshift(value, base):
    """Host id -> id inside the container; ids outside the container's range are left alone."""
    return value - base if base and value >= base else value


def build(rootfs, out, name):
    base = os.lstat(rootfs).st_uid          # uid 0 inside the container
    arch = ARCH.get(platform.machine().lower(), platform.machine())
    meta = (
        "architecture: %s\ncreation_date: %d\nproperties:\n  description: hs backup drill %s\n  os: drill\n  release: drill\n"
        % (arch, int(time.time()), name)
    ).encode()
    with tarfile.open(out, "w:gz", format=tarfile.PAX_FORMAT) as tar:
        info = tarfile.TarInfo("metadata.yaml")
        info.size = len(meta)
        info.mtime = int(time.time())
        info.mode = 0o644
        tar.addfile(info, io.BytesIO(meta))
        seen = set()

        def add(path, arcname):
            ti = tar.gettarinfo(path, arcname)
            if ti is None:              # sockets
                return
            ti.uid, ti.gid = unshift(ti.uid, base), unshift(ti.gid, base)
            ti.uname = ti.gname = ""
            seen.add(arcname)
            if ti.isreg():
                with open(path, "rb") as fh:
                    tar.addfile(ti, fh)
            else:
                tar.addfile(ti)

        add(rootfs, "rootfs")
        for cur, dirs, files in os.walk(rootfs):
            dirs.sort()
            for entry in sorted(dirs + files):
                path = os.path.join(cur, entry)
                add(path, "rootfs/" + os.path.relpath(path, rootfs).replace(os.sep, "/"))
        # folders the backup leaves out (proc, sys, dev, run, tmp ...) must exist for the container to boot
        for d in ("proc", "sys", "dev", "run", "tmp", "var", "var/tmp"):
            arc = "rootfs/" + d
            if arc not in seen:
                ti = tarfile.TarInfo(arc)
                ti.type, ti.mode, ti.mtime = tarfile.DIRTYPE, 0o1777 if d.endswith("tmp") else 0o755, int(time.time())
                tar.addfile(ti)


def newest(data, kind="ct"):
    # kind "ct": containers (files); kind "vm": virtual machines (an `incus export` file, tagged "vm" besides ct:<name>)
    best = {}
    for snap in data or []:
        if ("vm" in (snap.get("tags") or [])) != (kind == "vm"):
            continue
        for tag in snap.get("tags") or []:
            if tag.startswith("ct:") and (tag not in best or snap["time"] > best[tag]["time"]):
                best[tag] = snap
    for tag in sorted(best):
        print("%s\t%s" % (tag[3:], best[tag]["id"]))


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "build" and len(sys.argv) == 5:
        build(sys.argv[2], sys.argv[3], sys.argv[4])
    elif cmd == "newest" and len(sys.argv) in (2, 3) and (len(sys.argv) == 2 or sys.argv[2] in ("ct", "vm")):
        newest(json.load(sys.stdin), sys.argv[2] if len(sys.argv) == 3 else "ct")
    elif cmd == "field" and len(sys.argv) == 3:
        print(json.load(sys.stdin)[sys.argv[2]])
    else:
        sys.exit("usage: ct-image.py build <rootfs> <out.tar.gz> <name> | newest [ct|vm] | field <key>")
