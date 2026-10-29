---
paths:
  - "scripts/manage-ct.sh"
  - "scripts/ct*.sh"
  - "scripts/mac.sh"
  - "scripts/net*.sh"
  - "scripts/unifi.sh"
  - "scripts/dns*.sh"
  - "scripts/recipes/_lib.sh"
  - "capabilities/incus/**"
  - "capabilities/ad/**"
  - "tests/ct*.sh"
  - "tests/net.sh"
  - "tests/dns.sh"
---

# Containers, VMs, network, directory

Loaded when you touch the files above (path-scoped rule). The root CLAUDE.md has the rules that always apply.

- "fast" storage for an instance = an Incus custom volume on the default (SSD) pool.
  Shares are mounted with a 1:1 user mapping when an app user is chosen (`--as uid:gid`,
  raw.idmap "uid 1000 <uid>"): that user's files are adminuser's on disk. One such user per
  container; root can't be mapped (it would make container root the host's adminuser).
  Profiles set a nightly snapshot kept 7 days; ZFS can only restore the newest snapshot, so
  manage-ct.sh deletes newer ones first. Share ACLs are edited via `sharesec` (needs root;
  SIDs via wbinfo).

- PC uses the domain controller (example.lan) for DNS; Windows appends that suffix to lookups.

- A Samba AD DC can't run in an unprivileged container (setting the `security.NTACL` xattr is
  denied); it needs a VM. In VMs the NIC is `enp5s0`, not `eth0`.

- Once a MAC is pinned, `volatile.eth0.hwaddr` is empty; read the device's `hwaddr` instead.

- Incus 7: `incus launch -d root,size=...` is refused ("Device from profile(s) cannot be
  modified"); create with `incus init`, `incus config device override <name> root size=...`,
  then start. The NIC of a running VM can't be overridden either: pin the MAC before the
  first start (manage-ct.sh --create does both).

- Passing hardware (USB, GPU, PCI) goes only through `scripts/ct-device.sh` (`hs ct hardware`, `hs ct <ct> device ...`). Its `--hardware`
  and `--list` lines are a contract with the web interface; PCI into a VM needs a typed address; read docs/Entwicklungsnotizen.md
  "Hardware passthrough" before changing it.

- New container: `hs ct add <name> [--docker]`, then UniFi reservation, then restart.
