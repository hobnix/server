---
paths:
  - "scripts/bulk*.sh"
  - "scripts/manage-pool.sh"
  - "scripts/manage-shares.sh"
  - "scripts/share*.sh"
  - "scripts/disk*.sh"
  - "scripts/pool*.sh"
  - "scripts/backup*.sh"
  - "scripts/crypt*.sh"
  - "scripts/unlock.sh"
  - "scripts/vault*.sh"
  - "scripts/sync-shares.sh"
  - "scripts/lib/bulkpath.sh"
  - "scripts/lib/crypt.sh"
  - "scripts/lib/secret.sh"
  - "capabilities/storage/**"
  - "capabilities/backup/**"
  - "capabilities/samba/**"
  - "tests/pool*.sh"
  - "tests/backup*.sh"
  - "tests/vault*.sh"
  - "tests/adopt.sh"
  - "tests/crypt.sh"
  - "tests/bulkpath.sh"
  - "tests/recover.sh"
  - "tests/shares*.sh"
---

# Storage, backup, encryption, shares

Loaded when you touch the files above (path-scoped rule). The root CLAUDE.md has the rules that always apply.

- **Storage** (details: docs/Entwicklungsnotizen.md#storage). `bulkType` in machine.toml ("zfs" default, or "snapraid" = single ext4 disks merged by mergerfs, SnapRAID parity, labels `bulk-data-NN` / `bulk-parity-N` mounted by scripts/bulk-mount.sh). `bulk/shares` (Samba shares, everyone acts as adminuser) and `bulk/sensitive` (container-owned, read-only for Samba users), one dataset/folder per share (`hs share add`). On snapraid, mergerfs can't do `shift=true`: shares go into containers with `raw.idmap`, sensitive folders are owned by the container's root (host id 1000000). Anything that must reach the disks and not the upload cache writes to /mnt/bulk/pool, never /bulk. The bulk lock /run/hs-bulk.lock (sync, scrub, cache mover, share rename, pool replace/remove) must be taken by anything that changes the pool; the lock check comes before the "member not mounted" check in bulk-sync.sh. Destructive confirmations in manage-pool.sh (`confirm_plan`) make you type the NAME OF THE DISK that changes (add/adopt/create: the pool name); do the same in every new destructive command and offer a background job for long work. Removing a SnapRAID data disk: `sync -E` with the disk pointed at an empty folder first; removal never runs a parity sync in the foreground. A disk labelled `backup` is never offered as free. `hs disk temp` only mounts existing-data disks read-only and never formats. The mount path of a pool disk comes from scripts/lib/bulkpath.sh (`disk_dir <member>`, `disks_root`), never a literal /mnt/bulk/data-NN (tests/bulkpath.sh checks). Pool/disk commands: `hs pool <pool> add|replace|remove|convert`, `hs disk ...`, `hs share ... rename|cache|perm`, `hs sync-shares` (repairs ownership), `hs disk-health`. Storage code was tested as root in throwaway Incus VMs (use `timeout`, retry); tests/pool.sh needs udev (CI only).

- **Backup and recovery** (details: docs/Entwicklungsnotizen.md#backup-and-recovery). `hs backup` = restic on a plain ext4 disk labelled `backup` (`/mnt/backup/restic`, mounted only while a command needs it; password in /var/lib/hs/restic-password, deliberately NOT in the host snapshot; retention 7 daily / 4 weekly / 6 monthly; nightly 04:00). The host files include /var/lib/hs, where the pool disks are mounted (scripts/lib/bulkpath.sh): backup.sh must exclude `disks_root` from the host snapshot (`host_excludes`; restic follows mounts), or the whole array lands in the backup whatever the share switches say. `hs backup prune` (web: Backup > Free space) gives space back at once: it deletes the `*-tmp-*` leftovers of a run that died of "no space left", clears stale locks, applies the retention and prunes (the nightly run only prunes on Sundays). Shares are in the backup per `backupNewShares` and /var/lib/hs/backup-on|off, containers via `hs backup ct <name> on|off`. Machine-readable modes (`--state`, `--overview`, `--snapshots`) must stay plain. `backup.sh restore` chowns only the restored subtree: `--to /` must never chown the system. `hs disk <member> recover` (scripts/disk-recover.sh, web Pool page) carves deleted files off a data disk with photorec: the disk leaves /bulk and goes read-only, output on another data disk, `recover-finish` gives it back; NEVER mv/cp/mc files between a pool disk (/var/lib/hs/disks/data-NN, before 2026-10-19 /mnt/bulk/data-NN) and /bulk or /mnt/bulk/pool (same files, the copy truncates them), use `hs pool bulk close --drain` to empty a disk or `hs disk <member> move shares/<folder> [--to <member>]` (scripts/disk-move.sh, disk to disk, same path) to move some folders. To work on a disk with a tool of your own: `hs disk <member> detach` (out of /bulk, so copying from it is safe), `attach` to put it back; forgotten detaches alarm after 2 hours. Safety-net timers (disk self-tests, restore drill, gc), `hs share <share> snapshot|rollback|auto` (ZFS only), disaster recovery runbook docs/backup-and-recovery.md (parts marked "noch nicht erprobt" are untested).

- **Encryption and vault** (details: docs/Entwicklungsnotizen.md#encryption-and-vault). One passphrase for every LUKS disk and encrypted ZFS pool (scripts/lib/crypt.sh, scripts/unlock.sh, `hs unlock`; `hs manage-pool --encrypt`). The system disk is plain and boots to SSH; secrets live in the LUKS `vault` (mapper `hs-vault`, /var/lib/hs-vault), with symlinks /var/lib/hs/<name> and bind folders. Read secrets only through scripts/lib/secret.sh (a closed vault gives "locked", never "missing"). While encrypted storage is locked (/run/hs/storage-locked) incus, zfs-mount, samba, bulk-mount and the bulk timers stay down; `hs update`/`hs rebuild` refuse. notifyUrl must NOT be a service on this server (everything is down while locked; use public ntfy.sh with a random topic). Never have both system disks connected when moving the system (same LUKS UUID). The server's LUKS disks are listed in /var/lib/hs/luks-uuids; other people's are never opened.

- `bulk-mount.service` has `restartIfChanged = false` and must keep it: the mergerfs daemons run inside its process group, so a restart during `hs rebuild` (any change under scripts/ changes the unit) kills /bulk and mounts it anew, and every container with a folder of the old mount (Jellyfin `/media`, Immich, pelican-wings backups) gets "Transport endpoint is not connected" until it is restarted. Check with `incus exec <ct> -- ls <path>`; fix = `incus restart <ct>`.

- `backupNewShares` (machine.toml, default false) -> /etc/hs/backup-new-shares (on|off). Off: a
  share is in the backup only when listed in /var/lib/hs/backup-on (`hs backup <share> on`);
  the first time, backup.sh writes the shares that are in the backup then (not in backup-off)
  to backup-on, so switching the default drops nothing; shares created later start off. On
  (or no file yet): the old rule, in unless listed in backup-off. Both lists are kept in step.

- Shares: every dataset under bulk/shares and bulk/sensitive is its own registry share
  (`hs sync-shares`), new ones open to Domain Admins only; per-user access is set from
  `hs manage-shares` (or from Windows: fsmgmt.msc, type names as `HOME\user`). The catch-all `shares`/`sensitive` are
  admin-only. On disk everything is written as adminuser (`force user`).

- Share permissions are checked when a connection is opened: after changing them, test
  with a fresh connection (`sudo systemctl restart samba-smbd`).

- `sharesec` needs SIDs, not names with spaces (`wbinfo -n "HOME\Domain Admins"`).
