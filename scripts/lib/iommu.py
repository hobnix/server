#!/usr/bin/env python3
"""IOMMU group listing for the VM hardware step (docs/adr/0018-vm-gpu-pci-passthrough.md). Pure parsing of /sys; changes nothing.

  iommu.py groups    prints one tab-separated row per PCI device that sits in an IOMMU group:
                       group<TAB>address<TAB>class<TAB>vendor:device<TAB>driver<TAB>boot  (empty field is "-"; boot is 1 or 0)
  iommu.py check     prints  level<TAB>code<TAB>address<TAB>text  (warn|note; address "-" when it is about the machine)
                       codes: iommu-off, iommu-cmdline, boot-gpu, shared-group, host-driver
  exit 0 always when /sys could be read (an off IOMMU is a finding, not an error); 2 when the sysfs root does not exist.
Test knobs: HS_SYS_DIR (default /sys), HS_CMDLINE (default /proc/cmdline).
Not verified on hardware: written against the documented sysfs layout and fixtures only.
"""
import os
import re
import sys

SYS = os.environ.get("HS_SYS_DIR", "/sys")
CMDLINE = os.environ.get("HS_CMDLINE", "/proc/cmdline")
BRIDGE_CLASS = "0604"   # PCI-to-PCI bridge: ACS / topology, never passed through, never blocks a group
HOST_BRIDGE_CLASS = "0600"
GPU_CLASSES = ("0300", "0302", "0380")   # VGA, 3D, other display
# Drivers that mean "the host is using it"; vfio-pci means "ready for a VM".
FREE_DRIVERS = ("vfio-pci", "pci-stub")


def _read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def _clean(s):
    return re.sub(r"[\t\r\n]+", " ", s).strip() or "-"


def groups():
    """[{group:int, address, cls, ids, driver, boot}] sorted by group then address."""
    base = os.path.join(SYS, "kernel", "iommu_groups")
    rows = []
    try:
        names = os.listdir(base)
    except OSError:
        return rows
    for g in names:
        if not g.isdigit():
            continue
        ddir = os.path.join(base, g, "devices")
        try:
            addrs = os.listdir(ddir)
        except OSError:
            continue
        for a in addrs:
            if not re.fullmatch(r"[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]", a):
                continue   # not a PCI address (platform devices also sit in groups)
            dev = os.path.join(ddir, a)
            cls = _read(os.path.join(dev, "class"))[2:6].lower()     # 0x030000 -> 0300
            ven = _read(os.path.join(dev, "vendor"))[2:].lower()
            did = _read(os.path.join(dev, "device"))[2:].lower()
            try:
                drv = os.path.basename(os.readlink(os.path.join(dev, "driver")))
            except OSError:
                drv = ""
            rows.append({
                "group": int(g), "address": a, "cls": cls,
                "ids": f"{ven}:{did}" if ven and did else "",
                "driver": drv, "boot": _read(os.path.join(dev, "boot_vga")) == "1",
            })
    rows.sort(key=lambda r: (r["group"], r["address"]))
    return rows


def cmdline_iommu():
    """(intel_on, amd_off, pt) from the kernel command line."""
    words = _read(CMDLINE).split()
    intel = "intel_iommu=on" in words
    amd_off = "amd_iommu=off" in words or "iommu=off" in words or "intel_iommu=off" in words
    return intel, amd_off, "iommu=pt" in words


def check():
    out = []
    rows = groups()
    intel, off, _pt = cmdline_iommu()
    if not rows:
        out.append(("warn", "iommu-off", "-",
                    "no IOMMU groups: the IOMMU is off or not supported (enable VT-d / AMD-Vi in the firmware; on NixOS add "
                    "boot.kernelParams = [ \"intel_iommu=on\" ] on Intel, AMD enables it by default)"))
    elif off:
        out.append(("warn", "iommu-cmdline", "-", "the kernel command line turns the IOMMU off although groups exist"))
    by_group = {}
    for r in rows:
        by_group.setdefault(r["group"], []).append(r)
    for r in rows:
        if r["cls"] in GPU_CLASSES and r["boot"]:
            out.append(("warn", "boot-gpu", r["address"],
                        "this is the card the host booted with: passing it through takes the console away and needs a second card"))
    for g, devs in sorted(by_group.items()):
        end = [d for d in devs if d["cls"] not in (BRIDGE_CLASS, HOST_BRIDGE_CLASS)]
        for d in end:
            others = [o for o in end if o is not d]
            if others and d["cls"] in GPU_CLASSES:
                out.append(("warn", "shared-group", d["address"],
                            "group %d also holds %s: all of them go to the VM together (or none)"
                            % (g, ", ".join(o["address"] for o in others))))
            if d["cls"] in GPU_CLASSES and d["driver"] and d["driver"] not in FREE_DRIVERS:
                out.append(("note", "host-driver", d["address"],
                            "bound to %s on the host: it must be released (vfio-pci) before a VM can take it" % d["driver"]))
    return out


def main(argv):
    if len(argv) != 2 or argv[1] not in ("groups", "check"):
        sys.stderr.write("usage: iommu.py groups|check\n")
        return 2
    if not os.path.isdir(SYS):
        sys.stderr.write("iommu.py: %s does not exist\n" % SYS)
        return 2
    if argv[1] == "groups":
        for r in groups():
            sys.stdout.write("\t".join([str(r["group"]), r["address"], _clean(r["cls"]), _clean(r["ids"]),
                                         _clean(r["driver"]), "1" if r["boot"] else "0"]) + "\n")
    else:
        for lv, code, addr, text in check():
            sys.stdout.write("\t".join([lv, code, addr, text]) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
