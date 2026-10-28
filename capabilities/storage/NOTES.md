# storage

The pools and disks of a home server: the ZFS pools (`fast`, `bulk`) or the SnapRAID + mergerfs layout of `/bulk`, the share datasets, the
LUKS unlock at boot (`hs-unlock`), scrub and TRIM, SMART self-tests, the disk event log, the standby timer, `hs remote` mounts and the PCI bind.
Module: module.nix, moved verbatim out of configuration.nix. The system derivation of a home server did not change:
checked by comparing the `nix-instantiate <nixpkgs/nixos> -A system` store paths before and after (three machine.toml variants, same scripts/ folder).

- On with `role = "homeserver"` (the default, so an existing machine.toml needs no change). Off for `edge` and `minimal`: no ZFS, no
  mergerfs/SnapRAID, no restic, cryptsetup or smartmontools in the package list, no hostId, no disk services.
- Lists that several parts add to (packages, `boot.supportedFilesystems`, tmpfiles rules, udev rules) stay in configuration.nix and are gated there
  with `hasStorage`: moving a list item into another module can change the order and so the store path.
- The helpers shared by the four home capabilities (`bulkReady`, `whenUnlocked`, `notifyFailure`, `scripts`, `ad`) come from the `hs` argument
  (configuration.nix).
- `bulk-mount.service` keeps `restartIfChanged = false` (CLAUDE.md, Gotchas).
