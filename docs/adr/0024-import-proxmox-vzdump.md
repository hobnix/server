# 0024: Importing Proxmox vzdump archives: read-only plan first, restore into an Incus instance later

Status: Accepted (2026-11-10) for step 1 only (the read-only plan). The restore (rule 2) gets its own record before it is built.
Issue: hobnix/server#269 (with #205)
Not tested on hardware yet.

This record is a plan. Built so far: `hs ct import-vzdump <archive>`, a read-only listing and mapping plan (scripts/import-vzdump.sh,
scripts/lib/vzdump_import.py, tests/import-vzdump.sh on small archives made by the test). Not built: any restore. Nothing here was checked
against an archive from a real Proxmox.

## Context

- A vzdump LXC archive is a tar (`vzdump-lxc-<id>-<date>.tar` with `.gz`, `.zst` or `.lzo`). It holds the root file system and, in
  `etc/vzdump/pct.conf`, the Proxmox container config. Mount points (`mpN`) are in the archive only when `backup=1`; otherwise not at all.
- A vzdump VM archive is `.vma` (a Proxmox format, not a tar; optionally `.gz`, `.zst`, `.lzo`) with the config and the disk images. Reading it
  needs `vma extract` (Proxmox's tool) or a reimplementation of the format.
- The issue asks for LXC archives as Incus instances, VM archives as a separate decision, a plan before anything happens and nothing started
  without confirmation. Hobnix instances are unprivileged Incus instances on Hobnix's network (docs/PLAN-docker-instances.md); an
  instance is made by `manage-ct.sh --create`.

## Decision

1. **Listing and plan, read-only (built).** `hs ct import-vzdump <archive>` streams the tar once, counts entries, reads only
   `etc/vzdump/pct.conf` (limit 64 KB, `[pve:pending]` and snapshot sections ignored) and prints what maps and what does not. Nothing is
   unpacked, nothing is created, a zstd archive is piped through the `zstd` binary. A `.vma` is recognised by its magic and reported
   as "separate decision".
2. **Restore into an Incus instance (not built; proposed shape; NOT decided by this record: owner 2026-11-10, only step 1 is accepted and the restore gets its own record before it is built).** A later `hs ct import-vzdump <archive> --restore --name <ct>`:
   - shows the plan from step 1 and starts nothing before the typed name of the new instance (the destructive-command rule);
   - creates an empty instance with the mapped limits, then unpacks the root file system into it with `incus file push --recursive`
     or a tar piped into `incus exec`, so the id shift of an unprivileged instance applies; extraction runs with `--no-same-owner` fallback
     rules to be decided, and refuses absolute paths and `..` in member names, device nodes and setuid files outside a known list;
   - never overwrites an existing instance, snapshots nothing in the archive's name, and is a background job for large archives;
   - `ostype` decides whether Incus' own init (cloud-init, network config) is replaced: a Debian/Ubuntu root file system uses systemd-networkd
     or ifupdown files written by Proxmox, which must be rewritten for DHCP. This is the riskiest step and has to be tried on real archives first.
3. **VM archives (separate decision, still open).** Options: (a) require `vma extract` on the server and `qemu-img convert -O raw` into an
   Incus VM volume (needs the VM wizard of #258/#259 and a decision on the UEFI/BIOS flag from the config), (b) ask people to export raw
   disks from Proxmox themselves and use the ISO/VM wizard, (c) do not support them. Recommended: (b) first, (a) after the VM wizard is
   verified on hardware.

## What cannot be mapped

| Proxmox | Incus / Hobnix | Handling |
| --- | --- | --- |
| `net0..N` (bridge, VLAN tag, static IP, MAC) | Hobnix network profile, DHCP | listed; set static addresses by hand |
| `mp0..N`, `unused0..N` | disks / shares | not restored; listed |
| `lxc.*` raw lines (cgroup, apparmor, idmap) | none | listed, never copied |
| privileged container (`unprivileged: 0`) | Hobnix creates unprivileged only | listed; owners and devices need a decision |
| `features` other than `nesting` (fuse, keyctl, mount) | partly `security.*` | listed, not mapped |
| `swap`, `cpulimit`, `cpuunits`, `startup`, `onboot`, `tags`, `protection` | other Incus keys or none | listed |
| non-amd64 `arch` | none | warned |
| the Proxmox storage name in `rootfs` | none | ignored (only the size is used) |
| snapshots, backup notes, `.lzo` archives | none | `.lzo` is refused with a hint; snapshots are not in a vzdump |

## Consequences

- The plan is useful on its own today (what would I lose?), and cheap to keep honest because it only reads.
- The restore waits for a person with a real Proxmox archive to check the file ownership and network rewriting. Until then it stays
  proposed; this record is updated or superseded by a later one.
- Nothing in the importers is part of a `hs sys` contract; the web interface does not use them yet.
