# Development notes

Per-feature history and implementation details moved out of CLAUDE.md so that every session does not pay for them. The text is kept verbatim, grouped by topic; CLAUDE.md has a short summary of each group and the hard rules. Read the matching section before changing that area.

## Storage

- `bulkType` in machine.toml chooses how /bulk is built (default "zfs"). With "snapraid" the
  data disks are single ext4 disks merged by mergerfs and protected by SnapRAID parity
  (sync every `syncEveryHours` = 24 by default, i.e. 03:00 nightly, scrub Sunday). No disk is listed in the config: members carry
  labels `bulk-data-NN` / `bulk-parity-N`, mounted under /mnt/bulk by scripts/bulk-mount.sh.
  Shares are plain folders there. mergerfs can't do `shift=true` mounts: shares go into
  containers with `raw.idmap` (uid 1000 / gid 100 mapped 1:1), sensitive folders are owned
  by the container's root (host id 1000000). `fast` is always ZFS.

- HDD spin-down (opt-in): `diskSpindownMinutes` in machine.toml (default 0 = off) -> `hs-disk-spindown.service` (only when > 0; at boot after bulk-mount, and again from a udev `add` rule for hot-plugged disks) runs scripts/disk-spindown.sh apply = `hdparm -S <value>` on every ROTATIONAL disk that is a bulk/parity/backup member (labels `bulk-data-NN`/`bulk-parity-N`/`backup`, or a member of the ZFS pool `bulk`); never SSD/NVMe, the system disk or `fast`. Encoding: 1..20 min = minutes*12 (5 s units), above that whole half hours 241..251 (cap 330 min = 5.5 h). `hs disk spindown status` (tsv: disk, rotational, member, state from `hdparm -C`, minutes) does not wake disks. Setting is lost on power cycle (so 0 needs nothing at boot; `apply` with 0 sends `-S 0`). Caveats: 10 to 20 s wake delay on first access; mirror disks wake one after another; some IronWolf firmware and USB bridges ignore `hdparm -S` (only a warning, no `-B` fallback); SnapRAID gains most (only the disk holding a file wakes, parity sleeps between syncs). SMART readers (disk list, monitor, smartctl exporter) use `-n standby`; the weekly/monthly self-tests and `hs disk <disk> health` deliberately wake the disk. Timers that touch the disks (sync every `syncEveryHours`, cache mover every 15 min) keep waking them: tune those too.

- `hs disk temp` mounts a disk that already has data (NTFS/exFAT/ext4...) read-only under
  /mnt/temp/<name> and publishes it as registry share `temp-<name>` (Domain Admins only, `force
  user root`); `copy` rsyncs it into /bulk/shares/<share>, `eject` removes share and mount. It
  never formats; disks with the system, ZFS/SnapRAID/RAID members or swap are not offered.
  Mounts are not persistent (stale `temp-*` shares are removed on the next call). To reuse
  the disk afterwards, wipe it with `hs manage-pool`. In the interface it is the mode "Other disk"
  of the Disks tab's edit mode (see "Disks tab" below); the tab reads `temp-disk.sh raw` (device|fs|label|bytes|mountpoints).

- Upload cache (snapraid layout only, `hs share-cache <share> on|off`): ZFS dataset
  `fast/hs-cache` (quota = cache size) at /mnt/bulk/cache. bulk-mount.sh merges the data disks
  twice (/bulk and /mnt/bulk/pool) and mounts, per cached share, a small mergerfs over
  /bulk/<kind>/<name>: cache folder first (`ff`), /mnt/bulk/pool/<kind>/<name> below. The cache
  folder existing = on; a marker `<name>.off` = being emptied (branch NC). scripts/cache-mover.sh
  moves files (untouched 10 min, not open) to /mnt/bulk/pool before every sync and when the
  cache is 80 % full; mover and sync share the lock /run/hs-bulk.lock. Anything that must reach
  the disks and not a cache writes to /mnt/bulk/pool, never /bulk. Containers see a cache only
  after a restart. The lower branch needs an explicit small minfree (`=RW,1M`), mergerfs's 4G
  default otherwise makes writes fail with "read-only file system".

- Adopting disks that already hold files (`hs manage-pool bulk --role adopt --disks ...`, e.g.
  an Unraid array): xfs/ext4/btrfs only, no LUKS/ntfs. Nothing is erased: the label
  `bulk-data-NN` is written (xfs_admin/e2label/btrfs label; xfs labels max 12 chars, which
  fits), the top-level folders move into `shares/` (rename on the same filesystem) as their own
  share `<disk>-<lowercased name>` (data-02-media; `--merge` keeps the plain name, so folders
  of the same name on several disks become one), then bulk-mount.sh merges the disk. Hidden folders and loose files stay. The disk is inspected
  with a read-only mount (`norecovery`/`noload`), so a dirty xfs log is refused with a hint.
  Tested on ext4 loop images (the sandbox kernel has no xfs driver: only the label and the
  failure path were exercised for xfs). Parity is a separate, destructive step afterwards.

- Renaming a share (`hs manage-shares <share> --rename <new>`, `R` in the Shares tab): the
  name is the folder name, so the folder is renamed on every data disk (`zfs rename` on ZFS)
  under /run/hs-bulk.lock; the Samba share is recreated with the same parameters and ACL, the
  entry in backup-off and share-sizes follows, and containers whose device source is the old
  path get the new one and restart. Refused while an upload cache is on. A manual move between
  two shares on the same disk (`mv` on the server, not via Windows) is a rename, not a copy.
  Tested with fake net/sharesec/incus on temp folders; not against real Samba/mergerfs. The
  pool is mounted with `category.create=mfs` and `minfreespace=10G`: a full disk gets no new
  files, the folder is created on whichever disk takes them.

- The bulk lock (scripts/lib/bulklock.sh, /run/hs-bulk.lock) is taken by parity sync, scrub, cache
  mover, share rename and, from the typed confirmation on, `hs manage-pool` replace/remove (hours
  of work, with a marker /run/hs-bulk.admin). A timer sync that finds a pool change running skips
  with exit 0; before this it died on SnapRAID's own lock and sent a failure alarm. The lock check
  comes before the "member not mounted" check in bulk-sync.sh, because a removal unmounts the disk.

- Confirmations in manage-pool.sh (`confirm_plan`): replace/remove/convert make you type the NAME OF THE DISK that is
  changed (`data-02`), add/adopt/create the pool name; do the same in every new destructive command. For the snapraid layout
  the questions are followed by "run the work as a background job?" (`offer_job`): the job repeats the command with
  `--yes` plus the answers (`--fs`, `--encrypt`) and takes the bulk lock itself; a passphrase travels in a 0600 file under
  /run/hs (`HS_DISK_PASSPHRASE_FILE`, read once and deleted by `crypt_get_pass`). `--yes` still takes the lock.

- Removing a SnapRAID data disk: sync once with the disk pointed at an empty folder (`sync -E`),
  only then leave it out of the config; SnapRAID refuses a config that just lacks a known disk.

- Disks for the snapraid layout are prepared with `--fs ext4|xfs|btrfs` (default ext4; asked on a terminal with
  the encryption question, see docs/COMMANDS-DESIGN.md 6c). Removing a data disk moves its files, then only records
  it in /var/lib/hs/removals: bulk-mount.sh keeps it in the SnapRAID config pointing at /var/lib/hs/removed/<name>
  and the next bulk-sync (scheduled, or started as a job when asked) runs `sync -E` and forgets it. Removal never
  runs a parity sync in the foreground. tests/pool.sh needs udev (lsblk labels), so it only runs in CI.

- `hs sync-shares` repairs ownership: a share folder not owned by adminuser (made by hand with
  sudo, or adopted from Unraid: nobody) gets all its files handed over (find + chown, files first,
  the folder last so an interrupted run repeats); `--fix-owner` does it for every share.

- `hs disk-health` (scripts/disk-health.sh, needs root): `smartctl -j -a` per disk, findings rated
  BAD (failed assessment, pending/uncorrectable sectors, last self-test failed, >=100 reallocated)
  or WATCH (reallocated, CRC errors, error log, wear, 5+ years, >=55 °C); `--list` is tab
  separated; `--test short|long` starts a self-test inside the disk, `--results` reads it. Tested
  with fake smartctl output only (no root here).
  Passed self-tests are recorded in /var/lib/hs/disk-tests (serial, hours, type, time, counters 5/187/199/error-log count) whenever `--list`, the detail or `--results` sees one; reallocated (<100), uncorrectable, CRC and error-log findings count only when they grew since the last passed test (age, heat, wear, BAD stay). A failed newest test drops the baseline.

- Disk table (`monitor.sh --disks` = `hs sys monitor disks`, 12 tab separated fields, the last is the free bytes): the SMART values come from the smartctl exporter on
  this host (`metrics = true`, 127.0.0.1:9633, it scrapes every 5 minutes) when it has the disk (a current temperature), else from `smartctl -n standby` directly;
  `--fresh` asks every disk itself. The Disks tab's first reading uses the exporter (fast), every later one ([r], after a change) is `--fresh`. Roles, labels, pools,
  mounts and free space always come from lsblk, zpool and df (milliseconds). Knob HS_SMARTCTL_URL (tests use file://). Not Prometheus/Grafana: the host has no address
  on the container VLAN, and the exporter is where their data comes from.

- Hot-plugged disks (scripts/disk-event.sh, tests/disk-event.sh): a udev rule in configuration.nix (`ACTION=="add|remove"`, `DEVTYPE=="disk"`, not loop/ram/zram/sr/dm/md/nbd)
  starts `hs-disk-event@<action>-<kernel name>.service` (`hs sys disk event <action> <name>`), which describes the disk (size, model, serial, what is on it: empty, data, ZFS
  labels, array member), appends a line to /var/lib/hs/disk-events (`hs disk events` shows it) and sends a push message; a removed pool member is high priority. It NEVER
  touches a disk: adding one stays `hs pool <pool> add` / the Disks tab. Every disk it has seen is in /var/lib/hs/disks-seen/<name> (serial|description|member): udev replays
  all add events at every boot and every `hs rebuild`, those are silent; the first run only seeds; no push message within 5 minutes after a boot (still logged). The Disks tab
  does not watch for disks: it reads when opened, `r` reloads (in the free-disk step `r` reads the free disks again). A SATA port without hot-plug support needs a SCSI rescan.

- Share sizes: ZFS datasets know theirs; on the snapraid layout `manage-shares.sh --measure`
  (nightly with hs-sync-shares, or `m` in the Shares tab) writes /var/lib/hs/share-sizes.

- manage-pool.sh also replaces and removes (`--replace <member> --disks <new>`, `--remove
  <member>`). SnapRAID members ever seen are recorded in /var/lib/snapraid/members, so a dead
  disk shows as MISSING and `hs pool bulk sync` refuses to sync (a sync would drop its files from
  parity). Disks released from a ZFS pool keep ZFS labels; the script lists them as free
  ("old ZFS label") and clears the labels before reuse.

- Testing storage code: adminuser has no sudo, so destructive paths were tested as root in
  throwaway Incus VMs with block volumes attached as disks (Debian for SnapRAID, Ubuntu
  24.04 for ZFS since it ships the zfs module). `incus launch` of a VM sometimes hangs on
  this host; run it with `timeout` and retry.

- **Maintenance window (HDD spin-down, 2026-10-12).** Everything that reads or writes the bulk,
  parity or backup HDDs runs between 03:00 and about 06:00 so the disks can sleep the rest of the day.
  Rule: no periodic job reads /bulk or /mnt/bulk outside the window; SMART polling always uses
  `smartctl -n standby` (tests/maintenance-window.sh greps for it); `df`/`zpool status|list` are fine
  (statfs and cached pool state do not wake disks), `ls`/`du`/`find` over /bulk in a timer are not
  (the cache mover's `find` runs on the SSD cache only). Schedules are the units' own `startAt`, no
  new option; `syncEveryHours` (default now 24) still controls the sync. No RandomizedDelaySec on HDD jobs.

  | Job | Schedule | Touches |
  | --- | --- | --- |
  | hs-bulk-sync (snapraid; moves the cache first) | 03:00 daily (`syncEveryHours`) | data + parity |
  | hs-selftest-short | Sat 03:10 | every disk |
  | hs-selftest-long | 1st of month 03:15 | every disk (hours) |
  | hs-mac | 03:30 | SSD only (Incus) |
  | hs-sync-shares (+ measure) | 03:35 | /bulk folders |
  | hs-backup (restic) | 04:00 | bulk read, backup disk |
  | ZFS autoScrub (zfs layout) | Sun 05:00, no random delay | all pools |
  | hs-bulk-scrub (snapraid) | Sun 05:00 | data + parity |
  | hs-backup-drill | 15th 05:30 | backup disk |
  | hs-backup-drill-ct | 22nd 05:30 | backup disk |
  | hs-system-gc | Sun 06:30 | system SSD |
  | hs-cache-mover --if-full | every 15 min | `df` on the SSD cache; moves only when 80 % full |
  | hs-health-check, hs-state-collect, deck/metrics | 15 min / 1 min / 10 s / 5 min | `-n standby` SMART, `zpool status`, `df` |
  | hs-share-snapshots (opt-in `shareSnapshots`, zfs) | hourly | a snapshot is a pool write and wakes the mirrors; leave off if spin-down matters |

  atime: pools are created with `-O atime=off` (datasets inherit), ext4 data/backup disks are
  mounted `noatime` (bulk-mount.sh, backup.sh, manage-pool.sh, temp-disk.sh). Logs, state.db, metrics and
  Incus live on the system disk or `fast`, never on /bulk.

- **Never move files by hand from a pool disk into the pool (2026-10-18, data loss on a real server).** `/mnt/bulk/data-NN/shares/x/f` and
  `/bulk/shares/x/f` (or `/mnt/bulk/pool/...`) are the SAME file while the disk is a mergerfs branch, but mergerfs hands out its own inode
  numbers, so `cp`, `mv` and Midnight Commander do not see "same file": the copy opens the destination with truncate (which truncates the real
  file on the branch), reads 0 bytes, and a move then deletes the source. Reproduced with mergerfs in WSL: `cp disk/f pool/f` leaves a 0-byte file,
  `mv disk/f pool/f` loses it. A cousin emptied data-04/05/06 (about 9 TB) with mc after `hs pool bulk close` (which only sets mode NC, the disk
  stays a branch). The safe way is `hs pool bulk close <disk> --drain`: it removes the branch from the mount first (`setfattr -n
  user.mergerfs.branches -v "-$dir"`), then rsyncs into the pool. `close` now says so. Recovery: unmount the disk at once, write nothing to it,
  image it, then carve with `photorec` (tested in an Incus VM, 2026-10-19: modern XFS zeroes the extent map of a freed inode, so `xfs_undelete`
  finds nothing, on both layouts the real disks have: nrext64=0/rmapbt=0 and nrext64=1/rmapbt=1; `photorec ... fileopt,everything,disable,jpg,enable,mkv,enable,mov,enable,wholespace,search`
  got 23 of 25 carvable files back whole, the two that were written in parallel (fragmented) came back 36% and 96%; names and folders are lost,
  data without a signature (random .bin) is not carvable; `ddrescue -n` to an image file and carving from the image gave the same result; the discard
  of the LUKS mappings is off (`discard_max_bytes=0`), so fstrim cannot destroy the freed blocks; enabling every photorec type produced 24 000 junk files).

- **Recovering deleted files from a data disk (2026-10-19).** `hs disk <member> recover [--to <member>] [--types media|all]` (scripts/disk-recover.sh; web: Pool page, first-aid button
  per data disk; `hs sys disk plan|start recover <member>` and `recover-finish <member>` through disk-change.sh, allowlisted in web-serve.py). The disk leaves /bulk
  (`user.mergerfs.branches` `-dir` on /bulk and /mnt/bulk/pool, umount), the device is set read-only (`blockdev --setro`), `/var/lib/hs/recovering/<member>` makes
  bulk-mount.sh leave it alone, photorec reads the whole device and writes below `<other data disk>/shares/recovered/<member>-<date>/raw`, the result is sorted into
  videos/photos/music/documents/other and videos and music are named by their tags (ffprobe). `recover-finish` removes the marks and runs bulk-mount.sh. The job holds the
  bulk admin lock for the whole run. photorec type names are checked against 7.2 (`mp4`, `avi`, `wav`, `wmv`, `docx`, `xls`, `m4a`, `webp`, `heic` are NOT names and stop it with a
  syntax error; `mov` = mp4/mov/m4v/m4a, `riff` = avi/wav, `asf` = wmv). Tested in an Incus VM on a real XFS disk labelled bulk-data-04: 15 of 15 small files back whole, truncated and
  plain-deleted alike; tests/disk-recover.sh uses fakes. A transient unit has no terminal and photorec still runs; the script path must be absolute (the unit starts elsewhere).

- **Moving a folder from one data disk to another (2026-10-19).** `hs disk <member> move shares/<folder> [--to <member>]` (scripts/disk-move.sh; web: Pool page, arrows button per data disk
  with a folder picker; `hs sys disk plan|start move <member> --path <path> [--to <member>]`, the picker reads `hs sys disk ls <member> [--path]`). It copies from `/mnt/bulk/<from>/<path>`
  to `/mnt/bulk/<to>/<path>` (rsync -aHAXR --ignore-existing --remove-source-files), so the path in /bulk never changes and /bulk shows the same files all the time; a file the target already
  has is never overwritten (it stays and is counted); a closed disk is never a target; the job holds the bulk admin lock. This is the replacement for what people try with mc: never
  copy between a branch path and the pool. Tested in an Incus VM with mergerfs (pool md5 list identical before and after).

- **Detach and attach a data disk (2026-10-19, phase B of docs/PLAN-hidden-pool-disks.md).** `hs disk <member> detach|attach` (scripts/disk-detach.sh; web: Pool page, plug button; `hs sys disk plan|start detach|attach <member>`, detach needs the typed
  name). Detach takes the branch out of /bulk and /mnt/bulk/pool (`user.mergerfs.branches -dir`), writes the time to `/var/lib/hs/detached/<member>` and, when `detached_dir` differs from `disk_dir` (phase C), unmounts the disk and mounts it at
  `detached_dir` (refused while something has files open: the disk goes back). bulk-mount.sh mounts a detached disk at `detached_dir` and keeps it out of the merge (`mdata`) but in the SnapRAID config; bulk-sync.sh skips while any disk is
  detached; health-check.sh complains after 2 hours (`HS_DETACH_MAX`). A detached disk is not in the pool, so copying from it into /bulk is an ordinary copy: tested in an Incus VM with the exact action that destroyed files while the disk was a
  branch (the source stayed intact, the copy was complete). Attach removes the mark and runs bulk-mount.sh. Test knob HS_DETACHED_ROOT stands for the phase-C mount point.

- **The pool disks moved to /var/lib/hs/disks (2026-10-19, phase C of docs/PLAN-hidden-pool-disks.md).** `disks_root` is `/var/lib/hs/disks` (README inside), a detached disk is mounted under `/mnt/bulk/<member>`; `/mnt/bulk/pool`
  and `/mnt/bulk/cache` stay. bulk-mount.sh mounts every labelled disk at its wanted place (`want_dir`), swaps the branches of a RUNNING merge (`+>` the new path, `-` the old one, in /bulk and /mnt/bulk/pool; the cached-share
  merges name `/mnt/bulk/pool/<share>` and need nothing) and lets go of the old mount points with a lazy umount once no merge lists them (an open file keeps its mount until it is closed). bulk-mount.service is never restarted by a
  switch, so rebuild.sh runs bulk-mount.sh itself right after the switch when a disk is still mounted under /mnt/bulk (`move_bulk_disks`), and the reverse (`HS_DISKS_ROOT=/mnt/bulk`) after a rollback to the previous generation. At boot nothing is
  mounted yet, so nothing needs moving. Tested in an Incus VM: two readers (one through /bulk, one through a cached share) read their files to the end with the right checksums while the disks moved, a process with its folder in /bulk kept
  working, the second run changed nothing, the way back left no duplicate branch, a reboot mounted everything at the new place, detach and attach worked on the new layout. tests/bulk-switch.sh does the same with loop devices (root, mergerfs).
  Tests that build pools under /mnt/bulk set `HS_DISKS_ROOT` in tests/lib.sh. Outside this repo anything that names /mnt/bulk/data-NN (own scripts, Prometheus rules, restic include lists) has to follow; the Grafana dashboard json knows both.

## Backup and recovery

- `hs backup` (scripts/backup.sh, restic): repository `/mnt/backup/restic` on a plain ext4 disk
  labelled `backup` (`hs backup init <device>` formats it, creates the password in
  /var/lib/hs/restic-password, and tells you to save it elsewhere). The disk is mounted only
  while a command needs it (`hs-backup.service`, nightly 04:00, `now --scheduled` does nothing
  before init). In: every share under /bulk/shares and /bulk/sensitive unless listed in
  /var/lib/hs/backup-off (default off: pelican-backups, restored; `hs backup <share> on|off`),
  containers listed in /var/lib/hs/backup-instances (`hs backup ct <name> on|off`; their files
  are read from the mounted rootfs under /var/lib/incus/storage-pools/default/containers, so
  only while running), the domain controller as `samba-tool domain backup offline` (one tar in
  /var/lib/hs/backup-dc), and the host files (machine.toml, hardware-configuration.nix,
  /var/lib/hs, /var/lib/samba/private, SSH host keys, `vault-header`; `hs secrets` lists and fixes them). Extras: `hs backup offsite set <restic repo>|now|off` (second repository, same password, creds in /var/lib/hs/backup-offsite.env, copied after every nightly run with `restic copy`; failure only warns, the health check complains after 3 days); `hs backup drill [N]` restores N random files and compares them; the host snapshot also holds /var/lib/hs/backup-inventory (Incus instances/profiles/networks/storage, lsblk, zpool, zfs as text); VMs (2026-10-27, TODO B10): `hs backup ct <vm> on` works for Incus VMs: backup.sh `ct_kind` (incus query .type), `vm_backup` runs the dump hook (guest agent), `incus export <vm> $VMX/<vm>.tar --instance-only --compression none` (VMX = ${HS_VM_EXPORT_DIR:-/var/tmp}/hs-vm-export, fixed path so restic finds its parent), `restic backup --tag ct:<vm> --tag vm`, deletes the file; needs ~1.1x the VM's used size free there; the domain controller is skipped (samba file). Chosen over files-inside because restic cannot read a VM image consistently and files-inside needs a running guest with an agent; the cost is a crash-consistent image and the export time. `drill ct` skips `vm`-tagged snapshots for the container drill (`ct-image.py newest ct|vm`) and checks one VM per run by streaming `restic dump` into `tar -t` (index.yaml + an .img/.qcow2); booting a VM is manual. tests/backup-vm.sh. Not run against a real VM yet; /var/lib/hs/backup-dump/<container> = the dump descriptor (2026-10-27, TODO B9): one command per line (blank and `#` lines ignored; a `# dump:<name>` line marks the command below it so a recipe run again replaces it), each run inside the container right before its files are backed up, a failing one does not stop the rest but fails the run; format helpers in scripts/lib/backup-dump.sh (`dump_cmds`, `dump_declare`, `dump_remove`); recipes use `install_dump_tool [sqlite]` (pushes scripts/recipes/files/hs-dump to /usr/local/sbin/hs-dump) and `backup_with_dump <name> <cmd>` from recipes/_lib.sh; `hs-dump postgres|postgres-compose|sqlite|sqlite-tree` writes to /var/backups/hs/<name>/ via a temp name and moves only a non-empty result into place (immich, synapse, authentik, arr; seerr still has its own script via media_backup); tests/backup-dump.sh; `status` estimates the size of the included shares (share-sizes file or ZFS) against the disk. Snapshots are tagged `shares`, `host`,
  `ct:<name>`; retention 7 daily / 4 weekly / 6 monthly per tag (prune and a 5 % `restic check`
  on Sundays). State for the health check is /var/lib/hs/backup.state. No Rust/hs-ui part on
  purpose; hs manage-shares is handled elsewhere. Tests use HS_STATE_DIR, HS_BACKUP_MOUNT,
  HS_BACKUP_NO_MOUNT, HS_BULK, HS_BACKUP_HOST_FILES, HS_INCUS_ROOT; `init` works on a loop device.

- Safety net (cloud, not yet run on the server): systemd timers in configuration.nix: `hs-selftest-short` (Sat 01:30) and
  `hs-selftest-long` (1st, 00:45) run scripts/selftest.sh (`hs disk selftest short|long`, state /var/lib/hs/selftest.state);
  `hs-backup-drill` (15th, 05:30, only when /var/lib/hs/restic-password exists) runs `backup.sh drill 5`, which now writes
  `drill_ok=` (only when every file came back) and `first_ok=` is written once; `hs-system-gc` (Sun 06:30) runs
  `system.sh gc 30 --yes`. health-check.sh reports disks rated BAD by disk-health.sh --list, self-test schedules stopped
  (short > 14 days, long > 45), a drill older than 45 days (or none 45 days after `first_ok`). `hs doctor` also checks the
  system disk (>= 85 %), clock sync, DNS, the domain trust (wbinfo -t) and a pending kernel change. `hs secrets [fix]`
  (secrets.sh) lists the secret files by mode/owner (never contents) and which to store elsewhere. tests/safety.sh,
  tests/health.sh.

- Drill report and "last verified" (2026-10-27, TODO A6, not run on the server yet): the timer `hs-backup-report` (25th 08:00, after the drills of the 15th and 22nd; `onFailure` -> hs-notify-failure@; only with the restic password) runs `backup.sh report --scheduled`: reads backup.state (last_ok, drill_ok, drill_ct_ok/name, drill_vm_ok/name, drill_dc_ok, offsite_ok, used_pct) and the container-drill list, adds the guide count of `docs-verified.sh --summary`, and sends ONE push through notify.sh (high/problem when something is overdue: backup > 2 days, file drill > 45, container/VM/DC > 90, off-site > 3, a failed try in 35 days, disk >= 90 %; else low/info). It touches no disk and no restic. `HS_BACKUP_NOTIFY` replaces notify.sh in tests. "Last verified": `docs/verified.tsv` (guide file name, date; no row = never; no date is ever made up), set with `hs docs verified <guide> [date]` (scripts/docs-verified.sh), shown by docs-build.sh as one italic line under the title of every German guide (no HTML), counted in the report. tests/backup-report.sh, tests/docs-verified.sh.

- Disaster recovery: docs/Neuaufbau.md (German runbook: A system disk lost, B data pool lost, C server and backup disk lost). The
  restic password is deliberately NOT in the host snapshot (it is put back by hand). tests/recover.sh rehearses the data
  part in CI (back up, delete state/host files/shares, restore with plain restic and `hs backup restore --to /`, compare
  checksums). `backup.sh restore` chowns only the restored subtree: `--to /` (restore in place) must never chown the system.
  Parts marked "noch nicht erprobt" (incus admin recover, container and domain-controller restore) are untested.

- Automatic share snapshots (ZFS layout only; `shareSnapshots = true;` -> /etc/hs/share-snapshots, default off): the timer `hs-share-snapshots`
  (hourly, only with the option and not on snapraid) runs scripts/snapshots-auto.sh: per share `auto-h-<date+hour>` (keep 24), the first of a
  day `auto-d-<date>` (7), the first of a week `auto-w-<ISO year>W<week>` (4); older ones are destroyed, manual snapshots never. Shares in
  /var/lib/hs/snapshots-off are skipped (`pelican-backups` from the start; `hs share <share> auto on|off`). `hs snapshots [list|--dry-run]`.
  Snapshots hold deleted files, so they use pool space. tests/snapshots-auto.sh.

## Encryption and vault

- Encryption (scripts/lib/crypt.sh, scripts/unlock.sh): one passphrase for every LUKS disk and
  every encrypted ZFS pool. `hs manage-pool --encrypt` = LUKS2 under the ext4 of new snapraid
  data/parity disks (mapper `hs-<12 chars of the LUKS uuid>`; labels live inside, so
  bulk-mount.sh needs nothing new) and `zpool create -O encryption=aes-256-gcm -O
  keyformat=passphrase -O keylocation=prompt`; adopting also opens LUKS disks. The server's
  LUKS disks are listed in /var/lib/hs/luks-uuids (other people's LUKS disks are never opened);
  /var/lib/hs/disk-key (optional, `hs unlock --setup-key`) makes the boot unlock itself.
  hs-unlock.service (DefaultDependencies off, before zfs-mount/bulk-mount/incus/samba) runs
  `unlock.sh --boot`: nothing encrypted -> no-op; locked -> /run/hs/storage-locked, a push
  message, and incus, zfs-mount, samba-*, bulk-mount and the bulk timers (ConditionPathExists
  "!/run/hs/storage-locked") stay down until `hs unlock` starts the units in
  /etc/hs/unlock-units. Fails open: without the marker everything starts as before. candidates() (lib/crypt.sh crypt_disk_class: own = this server's, ambiguous = same UUID on two closed devices: both never offered; foreign / copy of our vault: offered)
  with the note "[encrypted: not this server's, holds data]" and a danger line in the plan; adopting lists them as "[encrypted]". Tested with a
  stand-in for `cryptsetup open` (the sandbox has no device-mapper): real luksFormat/passphrase
  checks, mapper faked with plain loop devices; ZFS only as a dry-run command.

- Vault instead of an encrypted system disk (2026-10-06, done on the real server; docs/PLAN-vault.md = contract, docs/Vault.md = guide,
  docs/Vault-Umzug.md = how the server was moved): the system disk is plain (ESP, a 10 GiB LUKS2 partition `vault`, ext4 root) and boots
  to SSH on port 22 without a passphrase. Everything sensitive lives in the vault: LUKS label/ext4 label `hs-vault`, mapper `hs-vault`, mounted
  at /var/lib/hs-vault (`HS_VAULT_DIR`), found by the UUID in /var/lib/hs/vault-uuid. Secrets are files `<vault>/secrets/<name>` with symlinks at
  /var/lib/hs/<name> (restic password, UniFi key, disk key, ...), bind folders `<vault>/bind/<name>` (Samba's /var/lib/samba/private is bind-mounted
  from it); /var/lib/hs/vault-binds lists them. The passphrase is the same as the data disks'. `hs vault status|list|init|open|close|move|bind|
  header-backup` (scripts/vault.sh, scripts/lib/vault.sh; `vault_bind_add` compares a copy with `vault_tree_sig`, not `diff -r`, which cannot
  compare Samba's stale sockets). The LUKS header copy /var/lib/hs/vault-header is in the host snapshot; the restic password is not.
  Consumers read secrets through scripts/lib/secret.sh (`secret_state`, `secret_locked_exit`, `secret_prepare`): a closed vault gives
  "locked", never "missing". Unlock order (scripts/unlock.sh): the vault first, then the LUKS data disks (key file inside the vault when
  there is one, else the same passphrase) and the ZFS keys, then the units in /etc/hs/unlock-units. `hs-unlock.service` at boot only
  writes /run/hs/storage-locked and pushes; `hs-unlock-alarm.service` repeats the push after network-online (every 15 s, 40 tries) because
  the boot one is sent before the network exists (`hs sys unlock alarm`, HS_NOTIFY_STRICT=1 makes notify.sh fail so the loop knows). Unlock from
  a PC: `homeserver unlock` (separate repo homeserver-cli, runs `hs sys unlock stdin`). `hs update`/`hs rebuild` refuse while locked
  (`refuse_if_locked`, scripts/lib/locked.sh). `hs unlock` still opens LUKS devices it does not know (the old encrypted system disk got opened
  and recorded once): TODO. Test knobs: HS_VAULT_OPEN=1, HS_VAULT_DIR; tests/vault.sh (root, CI), vault-consumers.sh, unlock-alarm.sh.
  Push messages (notifyUrl, must NOT be a service on this server: every container is down while locked; public ntfy.sh with a random topic):
  urgent "unlock needed", "started" (only with an open vault, scripts/power-notice.sh, `hs-boot-notice`), "rebooting"/"shutting down" low
  (`hs-shutdown-notice`, ExecStop), "unlocked" low. A /var/lib/hs/notify-url written by `hs recipe ntfy` wins over machine.toml. Moving the
  system to another disk: partition the same way, rsync `-x` the root, new UUIDs in hardware-configuration.nix, `nixos-rebuild boot
  --install-bootloader` in `nixos-enter`, `dd` the closed vault partition (same LUKS UUID: never have both disks connected for the boot), unplug the old disk.

## Interface (hs-ui)

> Removed on 2026-10-22 (the web interface replaced it). Kept as history; the paths below (pkgs/hs-pool, the Rust tabs) no longer exist.

- The interface is one program, `hs-ui` (pkgs/hs-pool, Rust, ratatui): plain `hs` on a terminal
  starts it (as root), `hs monitor`, `hs manage-pool`, `hs manage-users`, `hs manage-shares` and
  `hs manage-ct` start it on their tab. src/main.rs is the frame (tab bar, key line, problem
  count from `health-check.sh --dry-run` in a background thread); each tab is a file in
  src/tabs/ implementing the `Tab` trait from src/ui.rs: overview, disks, users (the tab is called Permissions), shares,
  instances, backup, jobs, logs, commands (order: Overview, Disks, Instances, Shares, Users,
  Backup, Jobs, Logs, Commands; the Pools tab is gone, the pools are cards of the Overview). Every tab opens in view mode (nothing can be changed), `e` enters edit
  mode, esc leaves it; tabs switch with the digits or with `Tab` / `Shift+Tab` (next / previous, round the ends), in view mode only: a tab that needs `Tab` itself must be busy while it does, none does today. src/theme.rs holds the
  colours (Catppuccin Mocha). While /run/hs/storage-locked exists (encrypted storage not
  unlocked after a boot) the frame shows a red LOCKED badge and `U` runs `hs unlock` on the
  terminal, then every tab reloads (the marker is read directly, no script). The rule for all tabs: "the Rust side only draws, the script
  acts": every script has machine-readable list modes and `--dry-run`, and a change that asks
  something (pool name, password) is run on the normal terminal (`Flow::Run`). Render tests
  (`cargo test -- --nocapture`, on the server: `nix-shell -p cargo rustc gcc`) print each tab
  as text. No tab waits for a script: `load()` only starts `Job`s (ui.rs, a thread plus a
  channel), `poll()` takes what arrived; all tabs load at start; per-item details (storage of
  every instance, access list of every share, both pools) are read once into a map so moving
  a cursor never runs a script. Only user-triggered changes run scripts in the foreground. install.nix has no hs-ui: the base system uses manage-pool.sh's whiptail menus
  (`--plain`).

- Loading (main.rs `Shell::queue`, `feed`, `show`, `reload_everything`): the visible tab reads first, the other tabs one at a time behind it while nothing is reading (they all
  started at once before, and the scripts of the Overview, Shares, Containers ... made the visible tab wait for the slowest). A tab that was not read yet starts at once when it is
  opened. Timings as root on the server: monitor.sh --disks 0.24 s (0.16 with the exporter), manage-pool.sh --info/--members 0.34 to 0.40 s each; the Disks tab runs its five readings in parallel.
  `hs timing` (scripts/read-timing.sh, root) times every read the tabs make at load and prints them slowest first; measured on the server 2026-10-08: everything under 0.5 s except `sys status` 2.2 s and `sys shares overview` 1.8 s, which now run their independent sources side by side (the doctor 3 s and `backup snapshots` 0.9 s only run when opened), so the state database is NOT needed for speed. Timing: `HS_UI_TIMING=<file> hs-ui ...` (e.g. `sudo env HS_UI_TIMING=/tmp/hs-ui.log hs`) appends one line per event (start, first frame, tab shown, each `hs sys` call with its time, the Disks data arriving) to that file; src/timing.rs.

- Overview (plan: docs/PLAN-overview.md, phase 1 built): `overview-status.sh` (`hs sys status`, tests/overview-status.sh) prints one fact per line (backup state and age, encryption, the bulk-sync and scrub timers, upload cache, disk health findings, instances running, hottest disk, last disk event) and the interface chooses words and colours; the Overview tab (src/tabs/overview.rs) reads only `hs sys` (status, pool info and members of both pools, jobs running) and shows cards: Server (/proc), a card per pool (state, capacity bar, last sync, encryption/filesystem summary, problems of the pool, its members), Status, and the background jobs; it does not repeat the problems (the frame shows them). It REPLACED the Pools tab (src/tabs/pools.rs stays only for the parsers: `PoolData`, `parse_members`); a pool is changed in the Disks tab. Phase 2 (`e`, src/tabs/overview_change.rs): update the parity (`system-change.sh plan|start sync`, `bulk-sync.sh`) and scrub a pool (`scrub --pool <pool>`: `bulk-sync.sh --scrub` on SnapRAID, `zpool scrub` on ZFS) are jobs with the usual review and progress (tests/system-change.sh); doctor, cleanup report, settings and the support bundle (`sys system doctor|cleanup|config|report`) open in a scrollable LogView inside the tab. Phase 3: `system-change.sh plan|start update|rollback|gc` — the update's plan is `update-preview.sh --no-build` (new commits, diffstat, new machine.toml options, a checkout that would stop it; refused while the storage is locked or without a network), the job is `update.sh` with the live log of the progress view; a rollback is red and the word `rollback` is typed; garbage collection asks how old (7, 14, 30, 90 days) and runs `system.sh gc N --yes`. No console command is left in the Overview.

- Users (plan: docs/PLAN-users.md, phase 1 built): `user-access.sh` (`hs sys users access <user>` / `group-access <group>`, tests/user-access.sh) lists the shares a user or group reaches and through which ACL entries (the user himself, any of his groups, Everyone; the best level wins, a `denied` entry wins over everything); it reads the ACL of every share, so the interface asks for it only when a user is opened. The Permissions tab (src/tabs/users.rs, called Users until 2026-10-08; `hs-ui --tab users` still opens it; the old tab and its console keys are gone) has three panels: the choice (Users or Groups), the list of what was chosen (built-in groups hidden until `a`, `/` is the Table filter) and the information about the selected one (his groups or the group's members, and the shares reached with the entry that gives them); `←` `→` move between the panels, `↑` `↓` inside one, `Tab` is the shell's (next tab); the information loads by itself when the cursor has rested 0.3 s (every share's ACL is read for it) and is kept until the lists are read again. Edit mode (`e`) is a menu whose entries hand the terminal to the console command (`hs user <user> passwd|lock|unlock|groups|remove`, `hs user add|flush`, `hs group add|<group> remove`): Phase 2 (`user-change.sh plan|start <name> <lock|unlock|group-add|membership|flush>`, `hs sys users plan|start`, tests/user-change.sh; src/tabs/users_change.rs): lock and unlock, new group, the cache flush and the groups of a user / members of a group (a staged table with `/` filter, one review, applied one by one by `user-change.sh apply` and followed by a flush; Domain Users and Administrator in Domain Admins are refused) are flows; Phase 3 (the same script and flow): `password`, `user-add [--full]` (a masked field in the interface; `start` reads the password from the first line of standard input into a 0600 file under /run/hs that the job `user-change.sh apply-secret` reads once and deletes, then `manage-users.sh --password|--add ... --stdin` pipes it into samba-tool, whose getpass falls back to stdin without a terminal; never an argument, not in the plan, dropped from memory when the job has started), and the red `user-delete` / `group-delete` (typed name; `manage-users.sh --delete|--group-delete ... --yes` in the job; the plan lists his groups and shares, or the members and the shares with an entry). No console command is left in the Users tab.

- Shares (plan: docs/PLAN-shares.md, phase 1 started): `share-overview.sh` (`hs sys shares overview|mounts <share>|history <share>`, tests/share-overview.sh, needs jq) lists every share with the six fields of `manage-shares.sh --list` plus backup, disks (SnapRAID: data-01,data-02; ZFS: the pool) and the instances that mount it (`name(ro|rw)`, one `incus list -f json`; a mount of a folder inside a share counts for the share); `history` = ZFS snapshots (auto|manual), empty on SnapRAID.
  The Shares tab (src/tabs/shares.rs): list with detail pane, `Enter` opens `Shares › media` (access from `sys shares acl`, mounts, history; the size is measured on opening with `sys shares measure <share>` = `manage-shares.sh --measure <share>`, which rewrites only that share's line of share-sizes). Edit mode (`e`, src/tabs/shares_change.rs) is a menu: backup on/off, upload cache, rename, snapshot, roll back (red, typed name), automatic snapshots and repair are native flows over `sys shares plan|start <share> <action>` (scripts/share-change.sh, tests/share-change.sh: plan lines like pool-change.sh, every start a job, rename and cache warn which instances restart); permissions are a staged table (`sys shares plan <share> perm --set <sid>=<level>`, one review with old to new) and a new share is a form (`add --kind ... [--ct --path --as]`); restore from the backup is a flow too (`restore --snapshot <id|latest> [--path <inside>]`: snapshots from `sys backup snapshots` = `backup.sh --snapshots`, the files land in the share `restored`, the job runs `share-restore.sh --yes`); no console wizard is left in the tab. Delete (red, typed name) runs scripts/share-delete.sh: the instances that mount the share lose that device, `manage-shares.sh --rename <share>.deleted-<date>` renames the folder on every disk (checked first with its own dry run, so a refusal such as an active upload cache changes nothing), then the Samba share of the new name is removed; nothing is erased, `sync-shares.sh` lists `*.deleted-*` folders as kept and never publishes them (tests/share-delete.sh). A kept folder is removed for good with the red action `purge` (`share-change.sh plan <name>.deleted-<date> purge`, `share-purge.sh`: rm -rf on every data disk under the bulk lock, or zfs destroy -r; `sys shares deleted` lists them with their size; tests/share-purge.sh).

- Instances (plan: docs/PLAN-instances.md, phase 1 started): `manage-ct.sh --list` has two more fields at the end (bindings count, last start in UTC); `ct-bindings.sh <ct>` (`hs sys ct bindings <ct>`, tests/ct-bindings.sh, needs jq)
  joins an instance's storage (manage-ct.sh --storage) with pool, the disks the folder lives on (SnapRAID: /mnt/bulk/data-*/...), measured size (share-sizes), backup flag (backup.sh --shares), upload cache and the other instances that mount the same folder (one `incus list -f json`).
  `ct-change.sh plan|start <ct> <action>` (`hs sys ct plan|start`, actions start stop restart snapshot restore delete-snapshot add-storage remove-storage set ip update delete create, tests/ct-change.sh; a delete job runs `manage-ct.sh --delete --yes`) is the Instances counterpart of pool-change.sh: same plan lines, `danger` + `confirm_name` (the instance) only for restore and delete-snapshot, every start is a background job.
  The Instances tab (src/tabs/instances.rs; edit mode in src/tabs/instances_change.rs: instance, action, snapshot/storage/details, review, progress, the Disks flow pattern over `sys ct plan|start`; settings, fixed address, update, delete and create are further actions of the same flow; `l` opens the logs on `widgets/logview.rs` (`sys ct logs <ct>`, followed every 2 s); update-all, the Docker pane and a Logs tab are still to do) REPLACED the Containers tab in the tab bar (`hs manage-ct` opens `--tab instances`; the old src/tabs/containers.rs is deleted). It reads `sys ct list` every 5 s (cursor stays on the instance) and, on Enter, `sys ct bindings|snapshots|users <ct>` in parallel; `widgets/scrolldots.rs` draws the page dots on the bottom border of scrollable panes.

- UI rebuild (2026-10-07, docs/PLAN-ui-rebuild.md; the Disks tab is the pilot, the other tabs are still the old style and not run on the real server yet).
  This SUPERSEDES the next bullet (Disks tab edit mode) and the rule "tabs read the scripts directly": the interface calls ONLY system commands
  (`hs sys ...`, rows of kind `sys` in registry.tsv; never a script path, never a `user` row); the Disks tab lists them in `SYS_COMMANDS` (drift test
  against registry.tsv). Contract of a change (scripts/pool-change.sh, `hs sys pool plan|start <pool> <add|adopt|replace|remove|convert>`, plain
  key<TAB>value lines, never asks, tests/pool-change.sh): `plan` = `manage-pool.sh --dry-run` sorted into status/needs/reason/heading/step/note/warn/
  danger/command/confirm_name/long/option lines (exit 0 ok, 1 refused, 2 something missing); `start` needs `--confirm <confirm_name>` (the typed name is
  checked by the system layer too), a passphrase comes on stdin into a 0600 file, it runs as a background job and prints the unit; `hs sys jobs tail
  <unit> [N]` = state/exit/line/next for the progress view. The Disks tab (src/tabs/disks.rs) has no pool pane (the Overview shows the pools) and no
  `Flow::Run`: edit mode is a full-height blue frame with a breadcrumb: pool, action (per layout), role, disk, new disks, options (from the plan's
  `option` lines), review (red when the plan has a danger line; the disk name is typed), progress (blue running, green done, red failed; esc leaves, the
  job keeps running). Components in src/widgets/ (table with column priority and display width, `.filterable()` = `/` filter inside the table (`typing()`, `filter_suffix()`; `selected()` is the index in the rows that were set) and page dots (`widgets/scrolldots.rs`) on the bottom border of every `Table::draw` that does not fit, plan, dialog with ConfirmName, frame with breadcrumb,
  menu, options, progress, keymap; each has render tests); Ctrl+C (shell `cancel_key`, `Tab::cancel`; raw mode gives it as a key) closes the help/problem list, then cancels the open dialog/flow/edit mode, and quits only from the plain view; the bottom line shows `[⌘C]` (icon `Icon::Ctrl`, the Command symbol; nerd U+F0633); colours: green = view/focus, blue = edit mode, red = cannot be undone. Icons (src/icons.rs):
  `icons = "unicode" | "nerd" | "ascii"` in machine.toml -> /etc/hs/icons (HS_ICONS overrides), the unicode locks are 2 cells wide (the table measures display
  width); the console scripts do not use icons yet. Tests that run a fake `hs` use `bash`: on Windows set HS_TEST_BASH to Git's bash (the bare `bash` is WSL's).

- Disks tab edit mode (`m`: add, replace, remove, convert (snapraid only), other disk, adopt (snapraid only)) asks
  NOTHING inside the screen any more: it picks the pool (and the member for replace/remove/convert) and Enter hands the
  terminal to the console wizard `hs pool <pool> add|replace <member>|remove <member>|convert <member>` (adopt = `hs pool bulk
  add --role adopt`) through `Flow::Run`, and every tab reloads afterwards (`Tab::reload_all`). The rows are not `guided`
  (the tab builds the member argument itself when the row exists, like `t`; no row = a message, no in-tab fallback); the four
  rows are in the tab's `HS_COMMANDS` (drift test). The keys space, `x`, `g`, `o`, `r` are gone (the console asks: role, disks,
  filesystem, encryption, typed confirmation of the disk name, job offer); the tab no longer reads `manage-pool.sh
  --list-disks` or `--dry-run`. "Other disk" stays in the screen (temp-disk.sh). A disk labelled
  `backup` is never offered as free (manage-pool.sh, temp-disk.sh; tests/backup-disk-hidden.sh)
  and monitor.sh shows its role as "backup disk". The tab also merges the state database (`sys state disks`, by serial) into the table: missing disks are rows, worse ones are flagged, `f` on a missing disk asks (press `f` again, any other key cancels) and then runs `hs sys state forget <serial>`; the tab starts no user command.

- Backup tab (plan: docs/PLAN-backup.md, all phases built; src/tabs/backup.rs) reads only `hs sys backup state|overview|snapshots [<tag>]` = `backup.sh --state` (key<TAB>value: configured, last_ok,
  last_try, status, used_pct, snapshots, repo_size, disk, browse, offsite, offsite_ok, last_drill, drill_ok, next; `vault closed` when the vault is shut), `--overview` (kind shares|sensitive|ct|always, name,
  on|off, bytes or -) and `--snapshots [shares|host|ct:<name>]` (tests/backup-read.sh, no restic needed); view = two cards (backup, copies) + the list, Enter opens an entry with its snapshots; edit mode (`e`, src/tabs/backup_change.rs) is the usual flow over `hs sys backup plan|start` (scripts/backup-change.sh, tests/backup-change.sh, nothing red): switch a share or instance in/out (`toggle --name --kind shares|sensitive|ct --to on|off`), back up now (warns when the timer starts within 30 minutes), verify, restore drill, browse on/off, each a job with the progress view; the off-site copy is `offsite-set --repo <restic address>` (one form; the credentials stay in /var/lib/hs/backup-offsite.env written by hand, the plan warns when a b2/s3/... address has no file), `offsite-now`, `offsite-off`; restoring files is the Shares tab's restore flow (`shares_change::Change::restore`, started without its action menu for the share under the cursor, job `sys shares start <share> restore`), so no console command is left in the tab; `init --disk <id>` (RED, the kernel name of the disk is typed; the disks are the free ones of `sys pool disks`; refused while a disk labelled backup is plugged in, with a closed vault, or when `backup.sh init <dev> --dry-run` refuses; the job runs `backup.sh init <dev> --yes`, and as a job (HS_CALLER=job) it prints WHERE the password is, never the password itself, because a job's output goes to the journal) formats a disk as the backup disk. `backup.sh init` takes `--yes` (= HS_BACKUP_YES). The old `--shares` stays. None mounts the disk, both exit 0 before init, and they
  must stay machine-readable. `backup now` records snapshots/repo_size in backup.state. Edit
  mode toggles shares/containers; now, restore and browse run on the terminal.

- Commands tab (plan: docs/PLAN-commands.md, all phases built; src/tabs/commands.rs): three panels like the Permissions tab: the topics, the commands of the topic (`/` searches every topic at once) and the details (what it does in the server's language, the command, the tab that does the same, whether it asks, whether it is a long job, an old name's new command). The first topic is **Only in the console** (the commands no tab covers: vault, ssh-key, net, secrets, config set, ...), then Instances, Shares, Users and groups, Disks and pools, Backup, Jobs, System, Security, Network, Documentation hold the commands a tab covers; `a` adds the topics System commands and Old names. `←` `→` between the panels, `Tab` is the shell's. Every current user row of registry.tsv carries the flags `topic:<slug>` (instances shares users disks backup jobs system security network docs) and, where a tab of the interface does the same, `tab:<slug>` (overview disks permissions shares instances backup jobs logs); and `reads` (only reads) or `changes` (may change the system; the details and the review say so), tests/commands.sh and a Rust test fail for a new row without a topic, without reads/changes, or with an unknown name. Legacy rows (`legacy:` is the LAST flag: the shell reads the text up to the end) carry neither. `Enter` runs the command on the terminal and comes back; a command with `<value>`s in its path opens a small form first: each value a choice from the real names (`<share>` from `sys shares overview`, `<ct>` `sys ct list`, `<user>` `sys users list`, `<group>` `sys users groups`, `<disk>` `sys monitor disks`, `<pool>` fast and bulk) with the `/` filter, any other word a text, then optional further arguments (the new name), then the exact command line with what it does to the system; `Enter` runs it, esc goes a step back, Ctrl+C closes it.

- `hs jobs` (scripts/jobs.sh; `--list` = unit.service, description, next, last, ok|failed|never;
  `jobs.sh <unit>` = journal) feeds the Jobs tab (plan: docs/PLAN-jobs.md, all phases built, src/tabs/jobs.rs: `hs sys jobs list|running` as two tables with the `/` filter, Enter opens a job with `sys jobs show <unit>` (`jobs.sh --show`: unit, description, state running|ok|failed|never|unknown, exit, started, last, next, command; hs-* units only) and its journal in a LogView followed every 2 s while it runs (`sys jobs log <unit> [N]` = `jobs.sh --log`, plain lines); no console command is left, edit mode `e` (src/tabs/jobs_change.rs, `hs sys jobs plan|start stop|run <unit>` = scripts/jobs-change.sh, tests/jobs-change.sh, hs-* units only): stop a running job (blue; RED with the typed word `stop` for jobs that change disks: hs-job-pool-*, system sync/scrub, hs-bulk-sync/scrub, backup init, share purge; the stop is done at once, `status done`) or run a scheduled one now (`systemctl start --no-block`, the progress view tails the unit), or show its log; the Logs tab: `src/tabs/logs.rs`, read only, `hs sys logs units|show` = scripts/logs.sh (tests/logs.sh): the host journal in a LogView followed every 2 s (not while you scroll), `u` unit (all, the hs jobs, incus, samba, ssh, zfs, the kernel), `l` level (errors, warnings and worse, everything), `t` time (the last hour, today, since the boot), `/` searches the lines shown; digits 1-9). The Overview has a
  Status pane (background Job, "-" when data is missing): backup age, encryption, last parity
  sync/scrub, upload cache fill, disk-health WATCH/BAD. The problems of
  health-check.sh are a fixed panel on every tab (right column from 140 columns, otherwise a
  bottom strip; green "No problems" when none; each row shows the fix command it names as
  `-> hs ...`); key `f` (view mode, only when there are problems) opens the list, enter runs the
  first `hs <words>` of the line on the terminal. `p` no longer exists. `?` (view mode) is a help
  overlay: the tab's keys plus the global ones. The former Pools tab (gone: only its parsers stay in src/tabs/pools.rs, the pools are cards of the Overview) showed
  fast/bulk from `manage-pool.sh <pool> --info` and `--members` (parsers accept appended fields)
  and launches the user commands of registry.tsv on the terminal: `a` `hs pool <pool> add`, `e`
  `hs pool <pool>`, with the member pane focused `x` remove, `R` replace, `c` convert (snapraid
  data disks), `s` `hs pool bulk sync` (snapraid); the corner shows the command. The Commands tab is
  built from scripts/lib/registry.tsv (user rows grouped by first word, `a` also shows `sys`, help
  in the language of HS_LANG or /etc/hs/language, enter runs `hs <path>` unless the path has
  `<placeholders>`); without the file it lists the scripts. Everything the interface starts
  (ui::run, the background reads) gets HS_CALLER=ui, so `sys_guard` stays quiet; Flow::Run (the terminal handover) does NOT set it: a person sits there, and the scripts ask their questions (filesystem, encryption, guided dialogues, long-job offer).
  src/registry.rs is the shared registry parser (loaded once in main.rs, `Rc<Registry>`); a tab
  adopts a user command with `if let Some(cmd) = registry.command(&hs, &["share", name, "rename"])`
  returning `Flow::Run` before its old in-tab flow, so the interface can run AHEAD of the cloud's
  commands: no row in registry.tsv = nothing changes. `command()` only matches rows flagged
  `guided` (flags column: the script asks for what is missing and works without arguments);
  rows such as phase 2's `share <share> rename` (needs the new name) are NOT launched until
  they are flagged, so a form never turns into a usage error (docs/COMMANDS-DESIGN.md, "Contract
  with the interface"). First adopter: the Shares tab (`R` rename,
  `c` cache, `a` add -> rows `share <share> rename`, `share <share> cache`, `share add`).
  The Shares tab shows a Backup column (on/off/`-`, read in the background from `backup.sh --state` + `--shares`, `-` until `configured=yes`) and edit mode `b` toggles the selected share through the registry row `hs backup <share> on|off` (not a guided row: the tab supplies on/off itself, like `t` in Disks; `Flow::Run` with pause, the list reloads afterwards).
  Registry-first keys so far (each needs its row flagged `guided`, else a message): Disks view
  `h` `hs disk <name> health`, `v` results, `D` `hs disk replace`; `t` asks short/long and runs
  `hs disk <name> test short|long` (the one exception: the row is not guided, the interface
  supplies the argument itself when the row exists; `h` no longer switches pool in the Disks view,
  use Tab/`l`/arrows); Shares edit mode `R` rename, `c` cache, `a` add, `O` `hs share repair`
  (after a confirm), `P` `hs share <share> perm`, `B` `hs share <share> restore` (guided: asks
  folder, snapshot, confirmation; view and edit mode); Users and Containers hooks for the phase 3 rows
  (`user <user> passwd|remove`, `group <group> remove`, `ct <ct> remove|logs|console`, and
  dormant ones for the rest, table in docs/COMMANDS-DESIGN.md section 12; `L` logs and `C`
  console only exist through the registry).
  Phases 4/5 (cloud: `hs health|report|doctor|system|config|net|job|migrate|first-run`, old names
  marked `legacy:<new command>` in the flags column: still work, hidden from `hs help`, a tip for a
  person at a terminal, none for HS_CALLER=ui): the Commands tab hides legacy rows until `a` (then
  dimmed with `-> hs <new>`); Pools `s` runs `hs pool <pool> sync`, Jobs `F`/`l` run
  `hs job follow|log <unit>`; Overview view-mode keys `d` doctor, `u` system update (asks with a
  second `u`: it pulls and rebuilds), `P` report, `g` config list, each only when the registry has
  the row. DRIFT RULE: every `hs` command a tab launches is listed in that tab's `HS_COMMANDS` and
  must exist in scripts/lib/registry.tsv as a non-legacy `user` row, or `cargo test` fails
  (main.rs `every_command_the_interface_builds_is_in_the_registry`); hooks that wait for a row
  go in `PENDING` (printed, not failing): `ct <ct> edit`, `user <user> groups`.
  `manage-pool.sh <pool> --members` is `name, bytes, state, group, fs, enc` (fs ext4|xfs|btrfs|zfs|-,
  enc luks|zfs-native|-; "-" without root); the Pools tab shows them as FS/ENC columns plus a summary
  line ("all data disks: xfs, encrypted (luks)", "mixed filesystems ...", "unknown"), the Disks tab in
  replace/remove mode; parsers still accept the old 4-field form.

- `/` filters the lists of every tab (Shares, Users and groups together, Disks, Containers,
  Backup): `Filter` in src/ui.rs (`/` types, enter keeps, esc while typing clears; `busy()` is
  true while typing so the shell hands over every key). A tab keeps the full list (`all`, ...)
  and shows a filtered copy (`shown`, ...); background jobs read the full list. In the Disks tab
  `/` works on the disk list and the Other mode, the filter resets when the mode changes, and a
  SELECTED disk is never hidden by it (it is part of the plan). Not filtered: the Members pane
  and the Storage pane of Containers.

- manage-ct.sh and manage-users.sh use lib/ui.sh for their messages for people (`fail` for errors that exit 1, `ok`/`note`/`warn`, `ask` for
  the typed delete confirmation); every line the interface reads (`--list`, `--storage`, `--snapshots`, `--groups`, `--users`) and every `--dry-run`
  line is still a plain `echo`/`printf` and must stay one. tests/manage-legacy.sh checks both sides with a fake incus. Still plain:
  manage-shares.sh, create-share.sh, manage-pool.sh (whiptail in the base install).

## Commands, registry and language

- Users and groups: scripts/manage-users.sh runs samba-tool inside the domain controller
  instance (`dc1`, override with HS_DC) and reads users and groups with two ldbsearch calls
  (LDIF is unfolded and base64 values decoded there). Passwords are typed on the terminal
  straight into samba-tool, never passed through the script or the interface. It replaced the
  LDAP Account Manager container (`lam`). `--flush` = `net cache flush` on the file server.

- Language (`language = "de"` in machine.toml -> /etc/hs/language; `HS_LANG` overrides for one call;
  default "en"): scripts/lib/i18n.sh, sourced by lib/ui.sh. English text is the key; `ok/note/warn/fail/
  step/ask/confirm/spin/choose/say/die` look their static text up in scripts/lib/i18n/<lang>.tsv
  (English TAB translation, `\n` = line break); a text with values is written
  `ok "$(t 'Copied %s files' "$n")"` (sequential %s/%d, so the German keeps the order); no entry = English.
  Command descriptions come from `# help.de:` (next to `# help:`) and recipes from `# recipe.de:`, read by
  the `hs` wrapper and recipe.sh. Never translated: the interface's machine-readable output (lists, `--info`,
  `layout:`/`state:` lines, plan prefixes `Plan`/`Command`/`Note:`/`ALL DATA`/`Dry run`/`Current array`),
  push messages and health-check problems (by decision), commands and options. tests/i18n.sh checks the
  catalog against the core scripts (listed in its CORE variable: add a script there when you translate it).
  Also translated: unifi, share-cache, monitor, notify (usage and dry-run only; push messages and journal lines never), cs, new-ct and every recipe (`recipes/_lib` plus each recipe's messages: `in_ct`/`setting` titles and questions are looked up, texts with values use `t`). Recipe box bodies are written line by line with `$(say ...)`/`$(t ...)`; a backslash value (`\HOST\share`, `HOME\<user>`) goes into a variable BEFORE the heredoc, because backslashes inside `$(...)` in a heredoc are halved twice. `ask` strips a trailing `:` before the lookup, so catalog keys of questions have no colon. tests/i18n.sh also reads `in_ct`, `_tr` and `setting KEY` texts; run it on the server (`nix-shell -p python3 --run "bash tests/i18n.sh"`): on Windows Python writes CRLF into its key list and every key misses.
  Table headers for people are printed with `thead 'A' 'B'` (lib/ui.sh: every cell looked up in the catalog; tests/i18n.sh's extractor reads the quoted arguments), never with a raw `printf` header; state words in table cells go through `$(_tr '...')`; the `table` component colours the German status words too (erledigt, offen, läuft, fehlgeschlagen, nie ...). Uptime is printed language-neutral (`1 d 2 h 3 min`) in motd and monitor.

- Consistency sweep of the user commands (2026-10-05, docs/CLI-DESIGN.md "Who gets which form"): user commands print every line a person reads through the components (indent 2/4/6, no raw echo/printf, no `column -t`), every table has its `thead`, status-type commands start with `status_line "Label" "Value" ok|warn|bad` (`  Problems: None ✓`: health, unlock --status, doctor per section, secrets, cleanup, smoke, ports, ssh-key list, first-run, migrate, ct list, ct update-all), and `trail` (stdin, indent 6, dimmed) is the component for journals and tool output. `hs sys ...` rows are plain (lib/hs.sh sets HS_PLAIN=1) and tools (interface reads, timers, homeserver-cli) call only `hs sys ...` rows with `HS_CALLER=cli|ui|timer|job|test`: `hs sys unlock stdin`, `hs sys motd status` (the wrapper lets `sys motd` through without root). Left plain on purpose: motd (parsed by the interface and homeserver-cli), `notify --dry-run`, `config get`, report (file), every `--list`/`--state`/plan line. The `cancelled` answer of the guided dialogues is `fail "cancelled"` (✗ cancelled, exit 1). `hs system gc|rollback` run their long step under `spin`, so a test stub for nix-collect-garbage/nixos-rebuild must append its call to a log file (stdout of a successful step is not shown). Recipes print only through ui.sh via _lib.sh; facts in a recipe use `kv`, the closing text `box`. `unifi.sh` set-ip/clear-ip refusals and API errors go to stderr through `fail`/`warn`; its stdout for `used`, `reserved` and the dry-run lines stays machine-readable. Bare lists (manage-ct, manage-users, manage-shares) use `thead` + `table`; `sync-shares.sh` prints one table at the end.
  Storage commands (same sweep): `backup status` is `status_line` + `table` + `kv`; `die()` in backup.sh and temp-disk.sh is `fail "$@" >&2`; `backup init` confirms with `confirm_name <disk>` (`HS_BACKUP_YES` still skips it). `kv` takes `KV_WIDTH=N` for longer labels (disk-health details use 22). Lists that scripts also read (`hs snapshots list`, `hs share <share> snapshots`) print table + status_line only on a terminal (`-t 1`, no `HS_CALLER`) and the tab lines otherwise. `share-cache status` is a table; its "On the SSD pool: " note is still parsed by the Overview tile, and the mount `--dry-run` block of `temp-disk.sh` is parsed by the Disks tab: neither may change. `cache-mover.sh` uses `lib/ui.sh` (in CORE); `bulk-mount.sh` stays raw journal output on purpose. Trailing program output (`zpool status`, `df`) is indented 6, restic lists 2.
  The interface (hs-ui) speaks the server language too: pkgs/hs-pool/src/i18n.rs reads `HS_LANG`, else /etc/hs/language (`de`, anything else English; knob `HS_LANGUAGE_FILE`), and `tr`/`trf` look the English text up in the compiled-in German table src/i18n_de.rs (no entry = English). Names from the system, key letters, `hs ...` commands and script output are never translated, `Tab::title()` stays English (`--tab` matches it; the tab bar translates it), tests run in English unless one forces German with `i18n::german(|| ...)`. A new text goes in `tr(...)` and gets a row in i18n_de.rs (a test checks duplicate keys and `{}` counts).

- Command registry (phase 0 of docs/COMMANDS-DESIGN.md): `scripts/lib/registry.tsv` (kind user|sys,
  path words, script, fixed args, help, help.de; `<share>`/`<pool>`/`<ct>`/`<disk>` = values) is the one list
  of commands. The Nix `hs` wrapper only opens the interface and escalates to root; `scripts/lib/hs.sh`
  looks up the longest matching path, runs the script and prints `hs help [--all]`; `hs help <words>` (help_for) explains one command or a group offline: the
  registry help plus the comment block under `# args:` in the script (pass 1 reads every word as a command word, pass 2 lets one
  be a value: `help share rename` vs `help share docs`). `hs sys <area> <verb>`
  = machine-readable modes of the scripts (today's `--list`, `--state`...); a person at a terminal is
  warned and asked unless `HS_CALLER` is set (ui, timer, test). `hs sys registry` / `hs sys complete
  <words>` feed the zsh/bash completion (unprivileged lookups, cached 30 s in /run/hs/complete). A new
  script needs a row (tests/commands.sh). Old command names keep working until the wizards replace them.

- Pool commands: `hs pool <pool> [add|replace|remove|convert]` are registry rows over manage-pool.sh (`--replace`,
  `--remove`, `--convert <member>`, `--fs`, `--encrypt`, `--mode detach|vdev`, `--yes`). ZFS remove: a mirror of 3+ disks
  = `zpool detach`; of 2 = asked (detach leaves the other disk alone, with a warning; or `zpool remove` of the whole
  mirror after a free-space check with 10 % margin); the only vdev is refused. `--convert` (snapraid data disk) moves
  the files to the other disks, formats again and records the disk in /var/lib/hs/removals like remove. `--convert --discard`
  (web: checkbox in Convert a disk) skips the move and the free-space check: the disk leaves /bulk (`discard_disk`), is unmounted
  and formatted, its files are erased; added because convert moved hidden files (data-06/07: 0.08 TB the file manager did not
  show) into the pool. Not run on hardware yet. tests/zfs-plan.sh
  checks the ZFS decisions against a fake `zpool` (CI); tests/zfs-vm.sh runs the real commands in a throwaway Incus VM
  (`bash tests/zfs-vm.sh` on the server as adminuser; not in CI, needs KVM + internet).

- Phase 2 commands (rows in registry.tsv, `{1}`/`{rest}` in the fixed-args field = template, e.g. `--test {rest} {1}`):
  `hs disk list|<disk> health|test|results|temp [mount|copy|eject]|replace`, `hs share add|repair|<share> perm|show|cache|rename`.
  New guided scripts: share-perm.sh (names to SIDs via manage-shares.sh --principals/--acl/--set; `HS_MANAGE_SHARES`
  stand-in for tests) and disk-replace.sh (finds the member that is not ONLINE, asks for the new disk, runs
  manage-pool.sh --replace; `HS_MANAGE_POOL` stand-in). tests/guided.sh covers both and the templates.

- Phase 3 commands (registry rows over manage-ct.sh / manage-users.sh; a fixed-args token may hold a value, `ip={rest}`):
  `hs ct list|add|add-community|<ct> start|stop|restart|remove|set|ip|snapshot|snapshots|restore|update|storage [add|remove]|shell|exec|logs|console`,
  `hs user list|add|flush|<user> show|passwd|lock|unlock|remove|join <group>|leave <group>`, `hs group list|add|<group> show|remove`.
  New small scripts: ct-access.sh (`HS_INCUS` stand-in) and users-show.sh (`HS_MANAGE_USERS` stand-in). Completion knows
  `<user>`/`<group>` (wbinfo) next to `<share>`/`<pool>`/`<ct>`/`<disk>`. Not changed: manage-ct.sh, manage-users.sh.

- Phase 4/5 commands: `hs config list|get|set` (config.sh, whitelist language/gpu/notifyUrl/metrics/backupNewShares, copy in
  /var/lib/hs/machine.toml.before-config, `HS_MACHINE_FILE`), `hs system info|update|rebuild|rollback|gc`, `hs net setup|check|ip <ct> [set|clear]`
  (net-ip.sh: pinned MAC -> unifi.sh), `hs job list|running|log|follow|stop`, `hs health [test]` (health.sh: each problem with its
  fix command), `hs report`, `hs migrate [--status|--step|--yes|--reset]` (resumable, state /var/lib/hs/migrate.state, calls the
  registry commands; `HS_BIN` stand-in), `hs first-run`, plus backup rows for completion. Registry flag `legacy:<new command>` =
  old name: hidden from `hs help`, still works, prints a tip on a terminal (`HS_CALLER` set = silent); the old names are NOT
  removed because the Rust interface and the timers still call them. German cheat sheet: docs/Befehle.md. tests/phase4.sh.

- Guided dialogues (registry flag `guided`, the contract of the interface keys in docs/COMMANDS-DESIGN.md section 12): ct-guided.sh
  (`hs ct add`, `<ct> edit|snapshot|storage|ip`; executes manage-ct.sh), user-guided.sh (`hs user add`, `<user> lock|groups`,
  `hs group add`; executes manage-users.sh, the password is still asked by samba-tool) and share-restore.sh (`hs share <share>
  restore` -> backup.sh restore into the share `restored`). Each runs bare and asks what is missing; every answer is also an option
  (`--yes` skips the confirmation, no terminal without `--yes` = refuses). Old CLI forms keep working (`hs ct add web --docker`).
  Stand-ins: HS_MANAGE_CT, HS_MANAGE_USERS, HS_MANAGE_SHARES, HS_NET_IP, HS_INCUS, HS_BACKUP, HS_CREATE_SHARE; HS_GUIDED_TTY=1 = "there
  is a terminal" (tests feed answers on stdin). tests/dialogues.sh.

- Round of 2026-10-05 (tracks A-F, docs/PLAN-next.md; none of it run on the real server yet):
  * `hs sys health next` (health.sh next): PROBLEM<TAB>NEXT per problem, no header, exit 0, empty when none; a command named in the
    problem line wins over the keyword mapping. sys rows with the name after the verb (`sys pool info|members <pool>`, `sys shares acl
    <share>`, `sys ct storage|users|snapshots <ct>`) are `{1} --flag` templates (the old rows stay). doctor.sh skips the domain-trust check
    without root (`HS_DOCTOR_UID`); `system info` reads /proc/uptime (`HS_PROC_UPTIME`). Messages use the new command names.
  * The problem panel (main.rs `with_next`) appends `(hs ...)` from `hs sys health next` to problem lines that name no command, so `f`/enter
    can run it. The tabs still read the scripts directly (`scripts/x.sh --flag`), not `hs sys ...` (decided: no gain).
  * Guided snapshots: share-snap-guided.sh = `hs share <share> snapshot|rollback|auto` (rows `guided`, executes share-snap.sh and
    snapshots-auto.sh, stand-ins HS_SHARE_SNAP / HS_SNAPSHOTS_AUTO; no terminal and no --yes = refuses; the rollback warning stays in
    share-snap.sh). Shares tab keys `S` snapshot, `G` rollback, `A` auto; Overview `C` = `hs cleanup` (report only on purpose: every finding
    names its own fix command that asks for itself).
  * `hs ports` (ports.sh, read only): `ss` on the host and in every running instance, each listener expected|admin|unexpected (lists in
    the script, extended by /var/lib/hs/ports-expected and ports-admin); reads Zoraxy's `conf/proxy/*.config` through `incus exec zoraxy`
    and WARNs (exit 1) when an admin UI is a target (pelican-panel only info); cannot see the default site, path rules, other config
    locations, a stopped Zoraxy (live-connection fallback, column source). The JSON field names are from memory: check on the server.
    `hs ct update-all` (ct-update-all.sh): every running container (VMs with --include-vms) snapshot + `manage-ct.sh <ct> --update` under
    spin, continues after a failure, table plus restore hints, offers a background job; not flagged `long` on purpose.
  * `hs help --search <words>` (lib/hs.sh `search()`): registry (path + help in HS_LANG/etc language) and docs/*.md. `hs update --preview`
    (update-preview.sh): only `git fetch`; HEAD..@{u}, diffstat, machine-sync --list, dry build of the upstream tree (root:
    dry-activate, else nix-build --dry-run); knobs HS_REPO, HS_MACHINE_FILE, HS_PREVIEW_AS_ROOT. `hs ssh-key list|add|remove` (ssh-key.sh):
    rewrites `sshKeys = [ ... ]` in machine.toml (copy in /var/lib/hs/machine.toml.before-ssh-key, parse check), remove refuses the last
    key and the key of the current session (HS_SSH_CURRENT_FP stand-in); bare add/remove ask.
  * Design language of every user command: docs/CLI-DESIGN.md (the look of `hs update`; components in lib/ui.sh: step ok note warn fail spin
    ask confirm choose menu choose_multi kv danger confirm_name table box). manage-pool.sh asks with `menu_pick`/`disk_pick` (ui components;
    whiptail only for `--plain`, the installer) and confirms with `confirm_name`. New commands use these, never their own colours/boxes.
  * manage-pool plans and summaries (docs/CLI-DESIGN.md): helpers `phead pl plt pcmd pplan pnote pwarn pdanger pdry pdone` in manage-pool.sh
    print the old lines unchanged unless `$ui = gum` (then a step heading without `Plan: `, indented steps, `kv Command`, `danger`, `warn` notes,
    closing `ok`; "Current array" = heading + kv rows). The interface parses the plain text (ui::run is never a terminal), so plain output stays
    BYTE FOR BYTE: tests/pool-look.sh compares 14 dry-run plans (fake zpool/lsblk/df from tests/lib-poolfakes.sh, no root) with
    tests/pool-look/*.out; re-record with `HS_LOOK_RECORD=1 bash tests/pool-look.sh` only when a plan text changes on purpose and change the Rust
    parser in the same go. `HS_BULK_TYPE_FILE` = stand-in for /etc/hs/bulk-type. `hs pool <pool> replace|remove|convert` run bare: a person at a
    terminal (`[ -t 0 ] && [ -t 1 ]` or HS_GUIDED_TTY=1, HS_CALLER unset) is asked which member with `menu` over `--members`, replace then asks the
    free disk unless `--disks`; no terminal and no member = the usage line; the four rows `pool <pool> add|replace|remove|convert` are `guided`
    (tests/pool-bare.sh feeds answers). Question order for disks to format: encrypt?, filesystem, passphrase, then the plan; a NEW ZFS pool is
    asked about encryption; `--convert` on a ZFS pool is refused.
  * manage-pool.sh declares `steps N` per path (replace/remove/convert and ZFS create/add: 1 heading, the plan; SnapRAID add/parity/adopt: 2, "Current array" and the plan; the job offer prints no heading), so with gum the headings are a tree (├ └) while plain output stays `── Title ──` byte for byte (tests/pool-look.sh, 25 ok). `first-run.sh` reads restic-password and notify-url under `${HS_STATE_DIR:-/var/lib/hs}`, so tests/phase4.sh no longer depends on the host's backup disk.
  * gum for the last scripts (track E): manage-shares.sh, create-share.sh, recipe.sh, mac.sh use lib/ui.sh like manage-ct.sh.
    Unchanged on purpose: `--list`, `--principals`, `<share> --acl`, the plan of `--set`/`--rename --dry-run`, the share-sizes file
    of `--measure`, every Samba/ZFS/Incus call (tests/shares-ui.sh asserts them literally, stand-ins in tests/lib-standins.sh).
    Errors arrive as "  ✗ text", final lines as "  ✓ text". `--measure` shows a spinner on a terminal only. `recipe.sh` without
    a name picks with `choose` then `confirm` (no = --dry-run); an unknown name exits 1. `hs job follow [<unit>]` (jobs.sh):
    header, journal as it arrives, closing line ("✓ Finished successfully (exit status 0) after 2:05" or "✗ Failed: ..."), exit
    status of the job, Ctrl-C only stops watching, test knob HS_FOLLOW_EVERY.
  * New tests (no root, in ci.yml): jobs, doctor, system, shares-read, ct-read, disk-list, net, monitor (the last four need jq and
    have only been read, not run, on the Windows workstation), ports, ct-update-all, help-search, ssh-key, update-preview, progress.

- `hs smoke` (scripts/smoke.sh, root): 1) which of the programs the scripts call (incus, zpool, smartctl, restic, samba-tool, ...) are not
  installed, with the scripts that use them; 2) a fixed list of read-only commands (ct list, disk list, user list, doctor, ...) run with a
  time limit; a non-allowed exit code, a timeout or `command not found`/`syntax error` in the output is a failure; probes whose command
  is not in the registry of this version are skipped. `--list` is tab separated, exit 1 on any failure. Add a probe when a command is read-only
  and should work on every server. tests/smoke.sh (fake dispatcher, PATH without the tools).

- Login message: `hs motd` (scripts/motd.sh, runs as the caller, no root: the wrapper lets it through like `help`) prints three lines from
  health.state (number of problem keys), backup.state (last_ok/status) and uptime/df; configuration.nix runs it from the zsh/bash
  login hook when `$SSH_TTY` is set. `loginMessage = false;` (-> /etc/hs/login-message) silences it; `--force` ignores that. tests/motd.sh.
- 2026-10-29 DNS: `hs dns sync` and `hs sys dns plan|start` (dns-change.sh) are removed; local names come only from the gateway
  (`<service>.<siteName>.<domain>`). `hs dns list` / `sys dns list` stay (services.sh reads `raw` for explicit records that shadow the
  wildcard). `hs dns clean` removes what the old sync left (names `<siteName>`, `<x>.<siteName>`, never `*`; plan first, --yes, --dry-run).

## Recipes and apps

- 2026-10-29: the Homepage recipe (packages/homepage, providers/dashboard/homepage.sh) was removed; the dashboard is built into the web interface
  (`dashboard = web`, `/api/board`, web/src/dashboard/). `homepage` left ADMIN_TARGETS and ports.sh with it. `hs update` migrates the setting
  (`config.sh migrate-settings`), `hs services declare-known` describes containers the old known() table covered (one release), `hs cleanup`
  reports what the old recipe left.

- Every recipe is a bash script built from the helpers in scripts/recipes/_lib.sh
  (`ensure_container`, `fixed_address`, `wait_internet`, `step`, `spin`, `in_ct`, `ok`/`note`/
  `warn`/`fail`, `box`), so all of them look the same and use gum; write new ones the same way
  and never print raw command output. Bash was kept over a YAML format on purpose: recipes
  need conditions ("installed already?", "keep the password") that a list of steps can't say.
  Preferences: at first setup a recipe asks (default in brackets, enter keeps it) for the
  network if there are several VLAN profiles, the memory limit, the port of the web page
  (default 80: every container has its own address; `port_setting <what> <legacy port>`),
  the fixed address (re-asked while UniFi refuses it) and its own values via `setting KEY
  question default legacy pattern`. Answers live in /var/lib/hs/recipe-<ct>.conf, so a re-run
  asks nothing; `--ask` asks again; RECIPE_<KEY> overrides; without a terminal the defaults
  apply. A container that existed before these questions keeps its legacy value (Grafana
  3000, Uptime Kuma 3001, Immich 2283, Jellyfin 8096). `$(web)` is the page's URL;
  `low_ports` lets non-root programs bind below 1024 (sysctl in the container). Under
  `set -euo pipefail` a `$(sed ... missing-file | tail)` kills the script: add `|| true`.
  Beyond preferences, recipes ask only for what nobody else can know (cloudflared: the tunnel token via
  `ask_secret`, piped straight into the container; domain: its name, and passwords typed
  into samba-tool / net on the terminal). `fixed_address <name> <first> <last>` takes the
  address from the range of the plan below. `domain` is resumable: VM + provision, then it
  stops until the router resolves the domain, then machine.toml adDomain + rebuild + join.
  `immich` runs the official docker-compose in a Docker container: photos on
  /bulk/sensitive/immich (mounted at /mnt/immich), database on the container's own disk;
  test knob RECIPE_SKIP_STORAGE=1. Optional preference GPU (asked only when Incus reports an NVIDIA
  card, default yes; a container from before keeps no until `--ask`; RECIPE_GPU=yes|no): the card
  goes in with `nvidia_gpu`, then `nvidia_docker` (_lib.sh) installs the NVIDIA container toolkit in
  CDI mode (the legacy mode fails in Incus on the cgroup/bpf check and on the missing
  /proc/driver/nvidia/gpus; unit hs-nvidia-cdi.service regenerates /etc/cdi/nvidia.yaml at every
  boot) and docker-compose.override.yml (rewritten at every run: port, plus with GPU the `-cuda`
  machine-learning image extending hwaccel.ml.yml `cuda` and immich-server extending
  hwaccel.transcoding.yml `nvenc`) turns it on; any GPU failure = warning and the CPU path. NVENC
  also needs Administration -> Settings -> Video Transcoding -> Hardware Acceleration -> NVENC in
  Immich. Test knob RECIPE_SKIP_PULL=1. `jellyfin`: package install, share "media"
  (movies/series/music) mounted read-only at /media with the jellyfin user mapped (`--as`).

- Converting films for Jellyfin (`hs recipe tdarr`, docs/Filme umwandeln mit Tdarr.md, plugin tested against real ffmpeg by tests/tdarr-plugin.sh, Tdarr itself NOT run yet): container `tdarr` (Docker, ghcr.io/haveagitgat/tdarr, server + internal node), the share `media` mounted READ-WRITE at /media with a user `tdarr` mapped 1:1 (`--as`); Jellyfin still mounts it read-only. The local classic plugin `scripts/recipes/files/Tdarr_Plugin_hs_Jellyfin_Friendly.js` (pushed into server/Tdarr/Plugins/Local, or Local/Classic if that exists) adds an AC3 track first and default next to TrueHD/DTS-only languages, copies the video unless it is a legacy format (then H.264, NVENC with the card), remuxes odd containers to mkv, and before changing a file makes a HARD LINK of the original under /media/_tdarr-originals (no link = file left alone; the recipe tests that links work across folders of the share). Libraries, plugin stack and the 01:00-06:00 schedule are set by hand in Tdarr's page (no API calls from the recipe: the schema was not verified). Tdarr's page has no login: never a Zoraxy rule. Open points: the plugin folder name and `addAac` (needed for Chrome/Firefox) are unverified.

- Sharing a folder with another homeserver (`hs remote`, scripts/remote.sh, docs/Server-gegenseitig-teilen.md, tests/remote.sh; not run on the real server yet): NOT a pool member. `offer <share> --peer <name>` makes the domain user `remote-<name>` (random password, shown once; `manage-users.sh --add --stdin`) with READ on that one share (`share-perm.sh`) and records it in /var/lib/hs/remote-offers; `add <peer> <host> <share> --user ... --domain ...` stores the password in the vault (`secret_prepare`, `remote-<peer>.cred`), records /var/lib/hs/remote-mounts and mounts `//host/share` read-only (SMB 3, soft, 0444/0555 so any container uid reads) at /mnt/remote/<peer>/<share>; timer `hs-remote-mount` (every 2 min, `remote.sh mount-all`) retries and always exits 0, so an absent peer blocks nothing; `attach <peer> <ct>` adds a read-only disk device on /mnt/remote/<peer> with `propagation=rslave` (a later mount shows up without a restart). Never in /bulk, parity, backup or the share list; Tdarr/arr never get it. No hs-ui part yet (decided: later). Test knobs: HS_REMOTE_ROOT, HS_MANAGE_USERS, HS_SHARE_PERM, HS_MOUNT_CMD, HS_UMOUNT, HS_MOUNTPOINT, HS_INCUS, HS_DOMAIN_SHORT, HS_HOST_NAME. Not translated yet (tests/i18n.sh CORE does not list it).

- Films and series from Usenet (2026-10-10, docs/Filme und Serien automatisch laden.md, none of it run on the server; tests/media-recipes.sh): three recipes, each Docker in its own container (.20-.29), all seeing the share `media` at the SAME path `/media` (mapped users `arr` / `sabnzbd`; the helper `media_storage` in scripts/recipes/_media.sh tests a real hard link, because a finished download is imported by hard link, not copied). `arr` = Radarr 7878, Sonarr 8989, Prowlarr 9696, Bazarr 6767, optional Maintainerr 6246 (no rules, deletes nothing) and Recyclarr as a compose profile `tools` (run by hand, the TRaSH German templates are chosen by the user); `sabnzbd` = SABnzbd (unfinished in /var/tmp/sab-incomplete inside the container, finished in /media/downloads/usenet/complete, set once through its API); `seerr` = Seerr (successor of Jellyseerr/Overseerr, Jellyfin and Plex, no share). The news provider and indexer are typed by the user, API keys between the apps are wired by hand. The apps get a push topic of their own (`media_ntfy`, /var/lib/hs/media-ntfy, same server as notifyUrl, never the alarm topic), and the containers are put in the backup (`media_backup`: `hs backup ct <name> on` plus an optional dump command in /var/lib/hs/backup-dump/<ct>, a sqlite `.backup` script in the container). Rule for all recipes from now on: the closing text holds only the clicks that cannot wait and ends with `$(docs_hint <guide slug>)` (the guide's address when the docs container exists, else "hs recipe docs"); the rest goes into the guide (TODO.md lists the recipes still to shorten).

- Duplicate films and the new card services (2026-10-10, not run on the server yet; tests/dedupe.sh): Maintainerr acts on whole films, so "delete the FullHD file when a 4K file is in the same folder" is NOT a Maintainerr rule. `arr` (setting DEDUPE, DEDUPE_DAYS) installs ffprobe + python in the container and the timer `hs-arr-dedupe` (03:30, user arr, scripts/recipes/files/hs-arr-dedupe.py): per film folder under /media/movies the file with the strictly lower height goes, announced first, deleted after the grace period if the better file is still there, then Radarr RescanMovie (best effort); veto = `.keep-both` in the folder; state /opt/arr/dedupe/pending.json. Only the local share, never the remote one. `files/hs-media-notify.py` is the one sender (ntfy + Matrix hook) of these helpers and SABnzbd's notification script; config JSON `hs-media-notify.json` written by `media_notify_conf` (_media.sh; the matrix-hook recipe re-runs it for arr and sabnzbd). Matrix payload = `{"hsService": "maintainerr"|"sabnzbd", event, event_icon, title, sub, fields, footer}` (specs.py `_hs`, palettes green / red in card.py, names "Maintainerr (Script)" and "Downloadarr" (the key stays `sabnzbd`; the bot accepts `downloadarr` in mute/unmute); mute/test know both). sabnzbd.sh sets the notification script through the API once and checks sabnzbd.ini: the `nscript_*` names are from memory.

- Game streaming (2026-10-10, docs/Spiele-streamen-mit-Sunshine.md; the server container is PARKED, the recipe exits unless RECIPE_FORCE=1: on the server josh5/steam-headless `latest` (v2) ends in `/sbin/init` (systemd as PID 1) and exits 255 in Docker inside the unprivileged Incus container, its init also fails on `chmod /dev/fuse` (nobody-owned there; dropping the device fixes only that), the v1 tag `debian-1.0.3` runs but Xorg hangs probing the iGPU's /dev/dri/card1 that has no node in the container; the only reports of Sunshine+NVENC in LXC are privileged containers with hand-made udev/sys remount (braindeadx1/sunshine-lxc-proxmox), another Incus attempt (Mstaaravin) gave up and says use a VM. Not tried: a VM with the RTX 4060 passed through (VFIO; Jellyfin/Immich/Tdarr would lose the card). Never put a `raw.lxc` `lxc.cgroup2.devices.allow` line on an unprivileged container: LXC then denies every unlisted device and the container does not boot). Tested only: tests/sunshine.sh; Sunshine streams the machine that renders, so there is no "PC as a GPU node". `hs recipe sunshine` = container `sunshine` (.30-.39, Docker, josh5/steam-headless: Xorg, Steam, Sunshine on the host's RTX 4060 via `nvidia_gpu` + `nvidia_docker`; `/dev/uinput` as unix-char and `/dev/input` as disk device (NO raw.lxc devices.allow: any such line makes LXC deny every unlisted device, even /dev/null, and the container does not boot); configuration.nix loads `uinput` and opens virtual input event nodes with a udev rule; login in /var/lib/hs/sunshine-admin, vault-aware). The home PC runs Sunshine itself; `hs pc add|list|remove|wake [--wait]` (scripts/pc.sh, /var/lib/hs/pcs, magic packet from the server with python3, HS_WOL_CMD stand-in) only remembers and wakes it. Admin pages 47990/8083: never a Zoraxy rule (ports.sh knows them). Moonlight on the TV adds hosts by address (no mDNS across VLANs). Translated (i18n CORE: recipes/sunshine, pc).

- Matrix messages from the film apps (2026-10-10, not run on the server yet; `hs recipe matrix-hook`, tests/matrix-hook.sh against tests/fake-matrix.py, tests/matrix-card-smoke.py): in addition to ntfy, never instead of it (Synapse is down while the storage is locked, so the alarms stay on ntfy). The recipe installs scripts/recipes/files/hs-matrix-hook.py and matrix-card/ into the container `synapse` under /usr/local/lib/hs-matrix-hook as the service `hs-matrix-hook` (user hs-hook, config /etc/hs-matrix-hook.json, rooms.json and posters/ in /var/lib/hs-matrix-hook), plus python3-pil and fonts-dejavu-core. Radarr, Sonarr and Seerr send a Webhook to `http://<synapse>:8090/hook/<secret>/<room>`; the path is the room (made on first use by the bot user `hs-bot`, the owner `@admin:<server>` is invited, not encrypted). The bot, not the apps, holds the credentials (it logs in with the password and again on a 401); secret and password are in /var/lib/hs/matrix-hook (vault-aware via secret_prepare). Every event is a CARD (29 variants of the Claude Design "Arr Notification Cards", Nocturne look): matrix-card/specs.py maps a payload to a spec (field names from the Radarr/Sonarr source, Notifications/Webhook/*.cs, and Seerr's default JSON payload; missing fields are left out), matrix-card/card.py (Pillow only) draws it at 2x = 1800x600 PNG with a fresh halftone background (port of the design's halftone.js; the colours depend on the service, `PALETTES` in card.py: Sonarr = the design's indigo, Radarr yellow, Seerr purple, dots + glow + the icon panel of health/update cards; text colours stay), Inter + Phosphor fonts vendored in matrix-card/fonts (drawn one weight up and icons twice, to match the browser's look; the mono footer uses DejaVu Sans Mono, which Menlo derives from), the poster comes from movie/series `images[].remoteUrl` (TMDB /original/ becomes /w342/) or Seerr's `image`, cached in posters/. The card is uploaded to the media repository and sent as `m.image` (w 900, h 300, alt text = the markdown version in `body`, no `filename`, so no caption). If Pillow is missing, `cards` is false in the config, or drawing fails, the same spec goes out as markdown converted to `formatted_body` HTML (`m.text`, because Element silences `m.notice`). `GET /healthz` says whether cards are on. CHAT COMMANDS (matrix-card/bot.py, a /sync long-poll thread in the hook; pure parsing is tested by tests/matrix-chat-test.py): typed in the room "Homeserver bot" (`_commands` in rooms.json: the bot makes it at the start, `is_direct`, unencrypted, the owner is invited; a DM the owner starts in Element would be E2EE and unreadable for the bot) or in a managed room; the message rooms are READ-ONLY for the owner (power levels: bot 100, events_default 100, owner 50 so they can still redact and react, `m.reaction` 0; made at room creation and applied to older rooms at the start by `ensure_read_only`; config `read_only: false` turns it off); the owner's Matrix ID only, nothing from before the start; a command that needs a room takes its name first (`clear media to 7d`, `test media`), else the room typed in, in the bot room `media`; `help`/`?`, `clear [from T] [to T]` (T = date, date time, `7d`/`12h`, today, yesterday; a date alone is the day's start for from and its end for to; it counts the messages through /messages, asks for `yes` within `confirm_seconds` (60), then REDACTS them one by one, waiting out 429s, and also redacts the command, the question and the answer; no purge, hs-bot is no server admin), `status`, `test` (one Test card per service, ignores mutes), `mute <svc|all> [dur]` / `unmute` (mutes.json in the state dir, dropped events are not queued). The recipe lifts hs-bot's rate limit with the admin login of /var/lib/hs/synapse-admin (`override_ratelimit`), best effort. Rooms must stay unencrypted. `{"text": "markdown"}` posts plain text. Other events answer 200 and are dropped. Never a Zoraxy rule. `python3 tests/matrix-card-smoke.py scripts/recipes/files/matrix-card sheet.png <design PNG folder> 01,09` draws a contact sheet next to the design's PNGs.

- Login for public services (`hs recipe authentik`, docs/Anmeldung-Authentik.md, not run on the server yet): container `authentik` (Docker, official compose, .20-.29, 2 GB), LDAP source = AD via dc1 for the owner, local Authentik users for friends. Pelican signs in by OIDC, NOT by forward-auth in front of the panel (Wings calls /api/remote without a browser). Only the login host gets a Zoraxy rule; admin UIs stay on local DNS names (dc1) + Tailscale, no rule. The recipe makes no Zoraxy/LDAP/OIDC settings itself (prints the values).

- Documentation site (`hs recipe docs`, scripts/docs-build.sh, tests/docs.sh): container `docs` (256 MB, lighttpd, fixed address
  (Replaced 2026-10-23: no container and no Docsify any more; `hs docs build` writes Markdown and index.json for the Docs page of the web interface, capabilities/docs/NOTES.md. The text below is history.)
  .20-.29, no Zoraxy rule) serves /var/lib/hs/docs-site read-only (disk device `site` at /var/www/html). No build tool in the
  container: `hs docs build` runs on the HOST and writes plain Markdown plus one index.html; Docsify (4.13.1: docsify.min.js,
  themes vue/dark with the Google font @import stripped, search plugin) is fetched once into docs-site/vendor and kept across
  builds, without it index.html points to the jsdelivr CDN (warning). Layout: /de/ = every docs/*.md (German guides, slugged file
  names) + befehle-liste.md, /en/ = COMMANDS-DESIGN.md and PLAN-*.md + commands.md; both command pages are generated from
  registry.tsv (user rows grouped by first word, legacy rows as "old names", sys rows last; help in the page's language, tags
  escaped because Docsify would swallow `<share>`). The sidebar is a tree from `docs/categories.tsv` (lang, group, file; `@commands` = the generated page; docs/README.md is the same index for GitHub and is not a page): a new docs/*.md must be added to both, else it lands under "Weitere" and tests/docs.sh fails. A new docs/*.md shows up by itself; a new English-only document must be named
  PLAN-*.md or added to the case in docs-build.sh. rebuild.sh calls the build when docs-site exists. Test knobs: HS_DOCS_OUT,
  HS_DOCS_NO_FETCH=1, HS_DOCS_VENDOR_URL (file:// works), HS_INCUS, HS_STATE_DIR.

- `hs recipe <name>` runs scripts/recipes/<name>.sh: idempotent, no questions. `ntfy` writes
  /var/lib/hs/notify-url (wins over machine.toml notifyUrl). `hs unifi` keeps router address
  and API key in /var/lib/hs/unifi (root only, never in the repo or machine.toml) and uses the
  legacy endpoints under /proxy/network/api/s/default/ (rest/networkconf, rest/user, stat/sta)
  with the X-API-KEY header. In loops that read stdin, give `incus exec` `</dev/null`.

## Monitoring and status

- Outside view and hardware health (2026-10-08, not yet run on the server): `heartbeatUrl` in machine.toml (-> /etc/hs/heartbeat-url, `HS_HEARTBEAT_URL`) makes health-check.sh POST a
  priority-min "alive" to that ntfy topic at every real run; `vps/hs-watch.sh` (NOT under scripts/, no registry row: it runs on the VPS; the NixOS VPS (repo `proxyserver`, modules/watch.nix) carries a COPY as service+timer `ps-watch` with HEARTBEAT_URL_FILE /var/lib/proxyserver/heartbeat-url and ALERT_URL_FILE = its notify-url; elsewhere /etc/hs-watch.conf with HEARTBEAT_URL,
  ALERT_URL = the notifyUrl topic, SITES, MAX_AGE_MIN; state `HS_WATCH_STATE`; change both copies) polls `<topic>/json?poll=1&since=45m`, probes the public addresses (000 or 5xx = problem, 404 is fine) and alarms
  on change / daily / recovery; an unreachable ntfy.sh keeps the old verdict. Guide docs/Ausfall-von-aussen.md, tests/vps-watch.sh. health-check.sh also reports ZFS scrub errors, a ZFS scrub
  older than `scrub_days` (21) or never run, and a SnapRAID scrub older than that (`bulk-sync.sh --scrub` writes /var/lib/hs/scrub.state, `HS_SCRUB_STATE`). memtest86+ is in the boot menu
  (`boot.loader.systemd-boot.memtest86.enable`; `sudo systemctl reboot --boot-loader-menu=60`), docs/Hardware-Gesundheit.md. The legacy command names are gone (registry rows, tips and the Old names topic).

- Status document for displays (2026-10-09, `deckApi = true` in machine.toml, default off; not yet run on the server): `hs sys deck` (scripts/deck-status.sh, needs jq, tests/deck-status.sh) = ONE JSON document, schema 1, counters not rates (net rx/tx bytes, cpu jiffies: the client takes two readings), pools, disks, SMART findings, backup age, problems, instances, locked; no secrets, a source that fails is null. `hs-deck-status` (every 10 s, root) writes /run/hs-deck/deck.json (NOT /run/hs: that is mode 700 for passphrase files, so the DynamicUser API could not read it and answered 404 "no status yet"), `hs-deck-api` (scripts/deck-serve.py, DynamicUser) serves ONLY GET /status.json and /healthz on 9740 (503 when older than 60 s), firewall: private ranges + tailscale0. `gpu` (first NVIDIA card from `nvidia-smi`, MiB converted to bytes; null without one; needs nvidia-smi on the service PATH, /run/current-system/sw has it with `gpu = "nvidia"`) and `history` (the last 24 hours, one median per hour of cpu, mem, gpu, rx, tx and the share of the hour the machine answered, `boot` when the uptime went down; scripts/lib/deck-history.sh keeps samples/hours files in /var/lib/hs/deck-history, only written when HS_DECK_RECORD=1, which the hs-deck-status service sets; the proxyserver has a COPY of the lib) are new in schema 1 (clients must accept missing keys). The proxyserver repo sends the same shape (`kind: proxyserver`, modules/deck.nix, a COPY of deck-serve.py: change both). Clients (Stream Deck+ daemon, web dashboard/Tauri app, Home Assistant) live in a separate repo `homeserver-deck`, not here. ci.yml does not list tests/deck-status.sh yet (the token could not change workflows): add it by hand.

- State database (2026-10-09, docs/PLAN-state-db.md, not yet run on the server): `/var/lib/hs/state.db` (SQLite, WAL, plain system disk, serials unencrypted on purpose) is written ONLY by `scripts/state-db.py collect` (via `scripts/state.sh`; timer `hs-state-collect` every minute, `disk-event.sh` after each plug/unplug, works while the storage is locked: roles/pools of known disks are kept, a disk is `missing` only when lsblk no longer lists it, a failed source changes nothing) and by `history-record` (the status service). Tables: disks (state ok|missing|unknown; a missing disk stays until `hs disk <serial> forget`), events, smart (reallocated/pending/CRC/temp/hours over time; growth against the oldest reading of 14 days = `worse`), samples/hours (the 24 hour history, old deck-history files migrated once to `*.migrated`). Readers (`hs sys state ...`, `hs disk inventory`) open it read-only. health-check reports `disk:<serial>:missing|worse` and `state:stale`; the status document got `inventory` and takes its disks from the database while the last collect is under 120 s old; `deck-serve.py` also serves `/disks` and `/events` (files the status service writes, masked serials). `scripts/lib/deck-history.sh` is no longer used here (the proxyserver's copy is). Tests: tests/state-db.sh (python3 only). hs-ui still reads `sys monitor disks` (follow-up).

- Notifications: `notifyUrl` in machine.toml (ntfy.sh style, optional) -> /etc/hs/notify-url ->
  scripts/notify.sh (always logs with tag hs-notify, never fails its caller).
  One look for every push message (docs/PLAN-ntfy-style.md): `scripts/lib/ntfy.sh` holds the only `curl` (`ntfy_send`; notify.sh, the heartbeat in
  health-check.sh and vps/hs-watch.sh use it). A message has a CATEGORY (`hs notify --category alarm|lock|problem|ok|start|stop|info|heartbeat`;
  without it derived from the priority) that gives the icon (ntfy emoji tag) and default priority; Tags = icon + host name; the body is markdown
  (`ntfy_md`: bold lead lines stay, several lines become bullets, `Details: <command>` endings become `code`, a blank line = author laid it out,
  no bullets; backticks in a message you write by hand are kept) plus an italic footer with host and time (not on the heartbeat). The journal gets the plain text.
  The proxyserver repo carries a COPY (modules/notify/ntfy.sh, and modules/watch/hs-watch.sh): change both; tests/ntfy-style.sh compares the lib
  when ../proxyserver is next to this repo. Test fakes for `curl` must flatten newlines (the body has several lines). The timer
  hs-health-check runs scripts/health-check.sh every 15 minutes and sends only when the set
  of problems changes (state in /var/lib/hs/health.state, reminder once a day). Scheduled
  jobs have `onFailure` -> `hs-notify-failure@<unit>.service`; give new ones the same.

- Capacity alerts, mitigation, routing (2026-10-27, docs/PLAN-mitigation.md, not yet run on the server): `scripts/lib/capacity.sh` (called by health-check.sh)
  adds `forecast:<volume>` (days until full from the `usage` readings in state.db, written via `state.sh usage-record`, read via `state.sh usage`; maths in
  scripts/forecast.py), `ssd:<dev>:wear|wear-high` (smartctl), `space:cache-backlog`. Setting `autoMitigate` (default false) = level 1: a failing disk or a
  degraded pool/bulk member makes the health check write /run/hs-bulk.paused; `bulk_lock_job` and cache-mover.sh skip while it exists (a pool change never);
  `hs health resume` lifts it and acknowledges its causes. `hs health ack|unack <id>` (/var/lib/hs/health-ack) silences a problem until it clears.
  notify.sh: setting `quietHours` holds priorities below high until the window ends (one digest, /var/lib/hs/notify-held), `notifyUrlSecond` +
  `notifySecondMinPriority` = second ntfy-style channel. lib/ntfy.sh is unchanged (nothing to mirror in the proxyserver repo). Schema keys must not contain
  digits (tests/schema.sh matches defaults.nix names with letters only). Tests: tests/capacity.sh, mitigation.sh, notify-route.sh.

- History (optional): `metrics = true` in machine.toml switches on node-exporter (9100, plus
  /var/lib/hs/metrics/hs.prom written by health-check.sh) and smartctl-exporter (9633), open
  to private addresses only. `hs recipe monitoring` sets that line, rebuilds, enables Incus
  metrics (8444, no auth) and installs Prometheus + Grafana in the container `monitoring`
  (Grafana, anonymous viewing, random admin password in /var/lib/hs/grafana-admin; home
  dashboard generated from scripts/recipes/files/homeserver-dashboard.json). health-check.sh
  stays the only alarm. `hs recipe uptime-kuma` = service checks. Logs (opt-in preference LOGS, asked at first setup, an
  existing monitoring container keeps no until `hs recipe monitoring --ask`; RECIPE_LOGS=yes|no):
  Loki and Grafana Alloy (apt.grafana.com) in the monitoring container, Alloy reads the host journal
  through the read-only disk device `hs-journal` (/var/log/journal -> /var/log/host-journal). The
  recipe (as root) gives the container's gid 62 (host id from volatile.idmap.current, 1000062) a read
  ACL on /var/log/journal (`setfacl`, also as default for new files): mapping systemd-journal with
  raw.idmap is impossible without a subgid rebuild (/etc/subgid has only root:100 and root:1000).
  Container side: group `hs-journal` (gid 62), drop-in alloy.service.d/hs-journal.conf. Labels job,
  host, unit (kernel, session), transport, level (emerg|alert|crit|error|...). Grafana datasource
  uid loki, dashboard "Errors" (uid hs-errors), retention = the Prometheus days. Grafana shows
  dashboards without a login, so the error lines (and Explore with source Loki, if the Viewer role
  may use it) are visible to everyone who reaches Grafana: never give it a Zoraxy rule. Test: throwaway
  container, RECIPE_SKIP_HOST=1, HS_JOURNAL_DIR=<copy of the journal in a dir named like the machine id>. Recipes share
  scripts/recipes/_lib.sh (files starting with "_" are not recipes): `spin`/`in_ct` show one
  line per step with gum (plain lines without gum, a pipe, or HS_PLAIN=1) and print a step's
  output only when it fails; `fixed_address` reserves in UniFi and restarts the container
  itself until it has the address (the router often hands out the old one at first); test them without root
  with RECIPE_NAME=<test-name> HS_STATE_DIR=/tmp/... (monitoring: RECIPE_SKIP_HOST=1).

- Prometheus runs on the HOST (2026-10-09, not yet run on the server; supersedes "Prometheus ... in the container" above): with `metrics = true` configuration.nix runs `services.prometheus` on 127.0.0.1:9090 (jobs server, disks, incus; instance label = hostName; data on the system disk; `metricsDays` 30 and `metricsMaxGB` 5 in machine.toml, both limits apply), no dependency on incus/zfs/bulk/samba and no lock-marker condition, so host numbers have no gap while the storage is locked (the incus job is just down). Grafana in `monitoring` reaches it through the Incus proxy device `prometheus` (`bind=instance`, listen and connect 127.0.0.1:9090; no firewall change). `hs recipe monitoring` no longer installs Prometheus; an older container's own Prometheus is stopped and disabled BEFORE the device is added (same port; its data is left). The recipe's days answer is written to `metricsDays` (+ rebuild) and also sets Loki's retention. The status document values are not exported to Prometheus (skipped on purpose). tests/monitoring-host.sh (static + dry run; not in ci.yml yet: add by hand).

## Graphics

- Graphics: NVIDIA RTX 4060 (driver on the host) and the Intel chip of the CPU (i915).
  NVIDIA into a container: `nvidia.runtime=true` + `nvidia.driver.capabilities=all` + a
  `gpu` device with `pci=<address>`, then restart. Incus' hook mounts the host's driver
  libraries at every start, but on NixOS it can't run ldconfig, so the container needs
  `ldconfig` at boot (unit hs-nvidia-libs.service); nvidia-smi is not mounted, test with an
  encode instead. `nvidia_gpu` in scripts/recipes/_lib.sh does all of it. The CDI id
  (`id=nvidia.com/gpu=0`) does NOT work here: Incus builds the CDI devices itself through
  NVIDIA's library and most likely can't load libnvidia-ml, which NixOS keeps in
  /run/opengl-driver/lib ("Failed to detect requested GPU device"). Intel chip: `gpu
  pci=<address> gid=<render gid in the container>` (hot-add). `hs recipe jellyfin` takes the
  NVIDIA card, else the Intel/AMD chip. Passing args after `su -c` that start with "-" get
  eaten by su: build one command string.


## Round of 2026-10-11 (none of it run on the server yet)

- UPS (optional, `ups` in machine.toml: a driver string or `{ driver, name, port, shutdownMinutes, lowBatteryPercent }`, default off; docs/USV.md): configuration.nix turns on NUT `power.ups` in standalone mode (option names written from memory: run `nixos-rebuild dry-build` with `ups` set first) and writes `/etc/hs/ups` (name, shutdownMinutes). `scripts/ups.sh`: `hs ups` shows charge, runtime and load; `hs sys ups status` prints key<TAB>value lines from `upsc` (state online|battery|low|unknown, reachable, replace), exit 0 even when unreachable; `event` is upsmon's NOTIFYCMD: ONBATT sends an alarm and starts the transient unit `hs-ups-deadline` (systemd-run, after shutdownMinutes), ONLINE sends ok and stops it, SHUTDOWN/FSD sends stop, COMMBAD and REPLBATT send problem; `deadline` runs `upsmon -c fsd` if still on battery. Health problems `ups:unreachable|onbattery|lowbattery|replace`. Knobs HS_UPS_CONF, HS_UPSC, HS_NOTIFY, HS_SYSTEMD_RUN, HS_SYSTEMCTL, HS_UPSMON, HS_POWEROFF; tests/ups.sh. Open: whether `upsmon -c fsd` cuts the UPS output after the shutdown; the BIOS needs "Power On after AC loss".
- Drift, rollback, expiry: `rebuild.sh` writes `/var/lib/hs/last-rebuild-rev` (rev, dirty, time) after each successful switch; `health-check.sh` reports `config:dirty|diverged|ahead|unbuilt` from local git only (no fetch, no build; behind upstream is not a problem). `hs update` safety net (when `HS_UPDATE_NOTIFY` is set, i.e. started by `hs update`): a switch that fails after starting, or sshd/Incus not answering afterwards, runs `nixos-rebuild switch --rollback` and pushes a message; a terminal is asked first, `--yes` or no terminal rolls back at once, `--no-rollback` disables it; newly failed units only warn; the check is a small subset of `hs smoke`. After it, `rebuild.sh` watches `health-check.sh --keys` (keys only, sends and writes nothing) for up to 5 minutes (HS_HEALTH_WINDOW, HS_HEALTH_INTERVAL, HS_HEALTH_CHECK): a key that was not there before the switch (`config:*` ignored) and is still there at the end rolls back the same way; it ends early when nothing new is left, and is skipped while storage is locked and with `--no-rollback`. Knobs HS_CURRENT_SYSTEM, HS_POST_WAIT, HS_POST_TRIES, HS_UPDATE_YES, HS_NO_ROLLBACK; tests/update-rollback.sh. Expiry: `/var/lib/hs/expiry` (name TAB ISO date TAB how to renew) via `hs expiry add|list|remove` (scripts/expiry.sh, `--list` machine-readable); health `expiry:<name>:soon` (30 days or fewer), `:due` (7 or fewer), `:expired`, `:invalid`; knob HS_EXPIRY_TODAY; docs/Ablaufdaten.md.
- Container restore drill: `hs backup drill ct [<name>]` (`cmd_drill_ct` in backup.sh, scripts/lib/ct-image.py) restores the container drilled longest ago (never-drilled first, smallest first; log `/var/lib/hs/backup-drill-ct`) from its newest `ct:<name>` snapshot into `HS_DRILL_TMP` (default /var/tmp), packs an Incus image with the ids unshifted (base = uid of the rootfs folder), `image import`, `init --no-profiles` with only a root disk (no NIC, so no MAC or address clash), starts it and checks `incus exec true` (systemd state is only reported); `hs-drill-*` is always deleted (EXIT/INT/TERM trap plus a sweep at the start). It also unpacks the `backup-dc` tar from the host snapshot and looks for `sam.ldb`; restoring into a new DC stays manual (docs/Neuaufbau.md). State keys `drill_ct_ok`, `drill_ct_name`, `drill_dc_ok`; health `backup:drill-ct` after 90 days once one succeeded; timer `hs-backup-drill-ct` on the 22nd at 05:30. Knobs HS_INCUS, HS_DRILL_TMP, HS_DRILL_WAIT, HS_DRILL_POOL. Unverified: image import of the unshifted tarball, `incus init --no-profiles` on Incus 7 (fallback `-s default`), restic JSON field names.
- Smoke coverage and cheat sheet: `hs smoke --coverage` (runs nothing): every user row flagged `reads` in registry.tsv needs a probe in `default_probes()` (scripts/smoke.sh: label, words, ok exit codes, optional time limit) or an entry in `SKIP_READS` with a reason; tests/smoke.sh fails otherwise, so adding a read-only command means adding its probe. `hs cheatsheet [--out f]` (scripts/cheatsheet.sh, tests/cheatsheet.sh) prints a one-page German Markdown sheet from the rows with a `cheat:<group>` flag (server disks shares users backup update trouble; 20 to 25 rows). The docs site is English only and has no page for it.
- Tests: `tests/run-all.sh` discovers every `tests/*.sh` (`--list`, `--only <glob>`, `--jobs N`, `--root-only`); root tests (a `need_root` line) run only with `HS_TEST_ROOT=1`, `zfs-vm` only with `HS_TEST_VM=1`, exit 77 = skipped; ci.yml calls it, so a new test needs no list entry. tests/i18n.sh already failed on main (stale catalog): clean up in a separate task.
- Torrents (`hs recipe qbittorrent`, docs/Torrents mit VPN.md): container `qbittorrent` (Docker, .20-.29), ONE compose of gluetun + qBittorrent with `network_mode: service:gluetun` (no network outside the VPN by construction). The VPN account (setting `VPN_PROVIDER`, `VPN_TYPE` wireguard|openvpn; key/user typed with `ask_secret`) lives only in `/opt/qbittorrent/gluetun.env` inside the container (0600; delete it to re-ask); needs the Incus device `tun` (unix-char /dev/net/tun). Share `media` at `/media`, torrents in `/media/downloads/torrents` (hard-link import by Radarr/Sonarr); web UI port from `port_setting`; `LAN` setting for `FIREWALL_OUTBOUND_SUBNETS`; never a Zoraxy rule. Unverified: gluetun with a tun device in an unprivileged container, the seeded qBittorrent.conf keys, `FIREWALL_OUTBOUND_SUBNETS` reaching the published port. Every recipe's closing `box` is short and ends with `$(docs_hint <slug>)`; the older recipes' details are in docs/Rezepte im Detail.md; tests/media-recipes.sh fails for a recipe without a hint or with a hint whose guide file does not exist.
- Checklist for the real server: docs/Pruefliste-Server.md (phases 0-6, results table).

## Web live state, browser side (2026-10-29)

`web/src/live.svelte.js` (`live = { open, gen }`, `startLive`/`stopLive`, called from App.svelte while a user is signed in and `features.live`) wraps one EventSource on `/api/events`: `changed` sets `live.gen[topic]`, `open`/`up` set `live.open`, `error`/`down` clear it. `poll(path, ms, topic)` in data.svelte.js reads `live.gen[topic]` so a change re-runs the effect; with the stream open it sets no timer. The timing rule is the plain function `nextDelay` in web/src/polldelay.js (tests/web-live.mjs, run by tests/web-live.sh): a failed read waits the interval, a 503 with `retry_after` waits that long. Only Summary passes a topic (`status`); Shell, Health, Vault and Encryption still poll their own `status`. Not run in a browser or against a real Redis; the frontend build was not run (no node_modules here).
