# Storage and disks

How the server stores data, how to create the pools, add, replace and remove disks, keep the data protected, look after disk health and
get files back. For a new server you do the first two sections once; the rest is for later.

## Before you start
- A server installed with [Install](install.md). You are logged in as `admin` over SSH and use `sudo`.
- A recent backup of anything you cannot replace. A pool protects against a failed disk, not against a deleted folder
  ([Backup and recovery](backup-and-recovery.md)).
- The disks you want to use, plugged in. Refer to them by their name under `/dev/disk/by-id/`, never by `/dev/sdX`: the letters change
  between boots.

```bash
ls -l /dev/disk/by-id/ | grep -v part
```

## Pick a layout for the data disks
The pool `fast` (SSDs, for containers and VMs) is always a ZFS mirror. The data disks, mounted as `/bulk`, come in two layouts. You
choose with `bulkType` in `machine.toml` **before you install**; the installer reads it only once.

| | `bulkType = "zfs"` (default) | `bulkType = "snapraid"` |
| --- | --- | --- |
| Disks | mirrored pairs of equal size | single disks of any size, each with its own filesystem |
| Usable space | half of all disks | all data disks; the parity disk does not count |
| After a disk fails | nothing is lost, every file is on two disks | the parity disk rebuilds it, but only as of the last sync |
| New and changed files | protected at once | protected after the next sync (nightly at 03:00 by default) |
| Growing | pair by pair | disk by disk |
| Snapshots of shares | yes | no (the backup is the history) |
| Fits when | you have pairs of equal disks and want the data protected all the time | you have disks of different sizes and mostly store large files that rarely change |

The catch with SnapRAID: files written since the last sync are lost if their disk fails, and without a parity disk nothing is
protected at all. SnapRAID is not a backup.

Check which layout the server has:

```bash
cat /etc/hs/bulk-type
```

If it prints `zfs` but you wanted `snapraid`, stop: `bulkType` was missing at install time. Do not create `bulk` as a ZFS pool; reinstall
with the value set.

## Create the pools
Before the full configuration is applied there is no `hs` yet, so the first pools are made with the pool menu. **It erases the disks
you select.** Look first: `--dry-run` shows the plan and changes nothing.

```bash
sudo bash /etc/nixos/scripts/manage-pool.sh --dry-run
```

Run it without `--dry-run` once per pool. It asks which pool (`fast` or `bulk`), lists the free disks (never the system disk or disks
already in a pool), shows the plan and asks you to **type the pool name** before it changes anything.

**`fast`:** select two SSDs. The menu builds a mirror and the dataset `fast/incus`, where Incus keeps containers and VMs.

**`bulk` with ZFS:** select an even number of disks. Equal-sized disks are paired into mirrors. The menu creates the datasets
`bulk/shares` and `bulk/sensitive`.

**`bulk` with SnapRAID:** run the menu twice. First choose role `data` and select the data disks (they become `data-01`, `data-02`, ...),
then role `parity` and select one disk that is at least as large as your largest data disk. Until a parity disk exists the menu warns
that a failed disk loses its data.

Add `--encrypt` to encrypt new disks with the server's one passphrase ([Encryption and vault](encryption-and-vault.md)). A ZFS pool cannot
be encrypted afterwards, so decide now.

Once the full configuration runs, the same dialogs are `hs pool <pool> add`, `replace`, `remove` and `convert`.

## Check the pools
```bash
hs pool fast
hs pool bulk
df -h /bulk
```

- `fast` is `ONLINE` with a mirror of two disks. `zpool status` shows the ZFS detail.
- With ZFS, `bulk` is also `ONLINE`, and `/bulk/shares` and `/bulk/sensitive` exist.
- With SnapRAID `zpool status` lists only `fast`; that is correct. `hs pool bulk` lists every data disk and the parity disk, and `df -h /bulk`
  shows the size of all data disks together.

## Where shares live
`bulk` has two top folders. Each folder below them is one network share ([Users and shares](users-and-shares.md)).

| Folder | From Windows | For |
| --- | --- | --- |
| `/bulk/shares/<name>` | read and write | files people keep and edit: media, documents, photos |
| `/bulk/sensitive/<name>` | read only | files a container manages, such as game server backups |

```bash
sudo hs share add photos
sudo hs share add app-backups --sensitive
```

With ZFS each share is its own dataset; with SnapRAID it is an ordinary folder. The command is the same. `hs share repair` hands the
files of every share back to the right owner, and `hs share cleanup --dry-run` lists shares whose folder is gone.

## Add disks
```bash
sudo hs pool bulk add --dry-run
sudo hs pool bulk add
```

The dialog lists the free disks and asks what you need:

- **ZFS pool:** choose an even number of disks. Disks of different sizes in one pair make the pair as large as the smaller one; the plan
  says so.
- **SnapRAID `bulk`:** choose the role (`data` or `parity`), whether to encrypt, and the filesystem (ext4, xfs or btrfs). A data disk may
  not be larger than the parity disk.

**All data on the chosen disks is erased.** The plan lists every disk and the command to be run; you confirm by typing the pool name. A
disk marked `[old ZFS label]` was in a ZFS pool before; the dialog clears the leftovers first. With SnapRAID, files on a new disk are
protected after the next sync. Long work can run as a background job: the dialog offers it, and `hs job list` shows it.

## Replace a disk
Install the new disk first, then:

```bash
sudo hs pool bulk replace data-02 --disks <new-disk>
```

Without a member the dialog asks which disk goes out. **All data on the new disk is erased.** You type the name of the disk that is
replaced.

- **ZFS:** the data is copied to the new disk in the background (resilver) and the pool stays usable. Follow it with `zpool status`. The
  new disk must be at least as large.
- **SnapRAID:** the new disk is formatted and takes the old name. For a data disk SnapRAID rebuilds its files from parity, then updates
  the parity. This reads every disk and can take many hours. A disk that is gone completely shows as `MISSING` and can still be replaced.
  A data disk cannot be replaced when there is no parity disk, because there is nothing to rebuild from.

## Remove a disk
```bash
sudo hs pool bulk remove data-02
```

You type the name of the disk. What happens depends on the layout:

- **ZFS** removes the whole mirror pair the disk belongs to. The data moves to the other pairs first, so they need enough free space.
  `--mode detach` takes one disk out of a two-disk mirror and leaves the other alone; `--mode vdev` removes the whole mirror.
- **SnapRAID** removes one disk. For a data disk the files move to the other data disks first (`--mode move`, the default), then the
  parity is updated; this can take hours. `--mode nomove` leaves the files on the disk. The disk itself is not erased.
- **Removing the only parity disk** leaves nothing protecting the data; the plan says so in red.

To empty a disk and keep it in the pool, or to change its filesystem, use `close` and `convert`:

```bash
sudo hs pool bulk close data-04 --drain
sudo hs pool bulk convert data-04 --fs xfs
sudo hs pool bulk open data-04
```

`close` stops new files going to the disk (it stays in `/bulk`); `--drain` also moves its files to the other disks. `convert` empties
the disk onto the others, formats it again (`--fs`, `--encrypt`) and fills it back. `open` lifts a close.

If the data on the disk is not needed any more, `--discard` skips the moving and erases the files with the disk, including files that
`/bulk` does not show:

```bash
sudo hs pool bulk convert data-06 --fs xfs --discard
```

You type the name of the disk first, and the files cannot be brought back. Not tested on hardware yet.

## Keep the data protected
**ZFS pools** are scrubbed every week by the system (every block is read and checked against its checksum). Look at the result with
`zpool status`. `ONLINE` is healthy; `DEGRADED` means a disk failed: the data is still there, replace the disk soon.

**SnapRAID** updates the parity once a night at 03:00. Change the interval with `syncEveryHours` (default 24):

```bash
sudo hs config set syncEveryHours 6
sudo hs rebuild
```

Every Sunday at 05:00 a scrub checks part of the data against the parity (about 12 % per run). Run either by hand:

```bash
sudo hs pool bulk sync
sudo hs pool bulk sync --scrub
```

`sync` refuses in two cases, because a sync makes deletions permanent:

- A disk is missing. SnapRAID would treat all its files as deleted and overwrite the very parity that can rebuild them. Fix the disk
  ([Replace a disk](#replace-a-disk)) first.
- More than 100 files were deleted since the last sync. Check that this was on purpose, and only then add `--force`.

On a ZFS server `hs pool bulk sync` just says there is nothing to do.

## Upload cache (SnapRAID only)
A new file is unprotected until the next sync. The upload cache closes that gap for the shares where it matters: new files land first on
the mirrored SSD pool `fast` and move to the data disks before each sync. You see one folder; it does not make uploads faster.

```bash
sudo hs share movies cache on
sudo hs share movies cache size 300G
sudo hs share movies cache off
```

Turning the cache on or off restarts containers that have the share mounted (otherwise they would not see files still in the cache);
`--restart` does it directly. The first `on` creates the cache (200 GB by default). A full cache
is not a problem: new files go straight to the disks, and the server clears it at 80 %. Only files unchanged for ten minutes and not open
move. `hs cache-mover` moves them now. The cache shares the SSD pool with your containers: leave them enough room.

## Disk health
```bash
hs disk list
hs disk data-01 health
sudo hs disk data-01 test short
hs disk data-01 results
sudo hs disk selftest short
```

`hs disk list` gives every disk a verdict (SMART). `health` shows age, bad sectors and errors for one disk; `test short|long` starts a
self-test inside the disk, and `results` shows the outcome. `hs disk selftest` starts one in every disk. Replace disks with a bad
verdict first; disks of six years and more are the biggest risk. `hs disk events` shows disks that were plugged in or removed lately,
`hs disk inventory` every disk the server has had, and `hs disk <serial> forget` drops a missing one from that list.

```bash
hs disk baseline
```

Every night at 03:05 the server compares each disk with its reading of the night before. A disk where pending or uncorrectable sectors
appeared, or many reallocated sectors, is `failing`; small changes and cable (CRC) errors are `watch`. A change stays listed for 7 days, and
the server sends a push message. `sudo hs disk baseline run` does the check now. Not tested on hardware yet.

A `failing` disk also pauses the parity sync, the scrub and the cache mover when `autoMitigate` is on (`hs health resume` lifts the pause);
`watch` never does. A long self-test runs every night in ONE disk, ordered by serial, so a disk is tested every N nights. A disk that cannot be
tested that night (still busy with its last test, or no self-test support) is skipped and the next one is tried; a long test that takes more
than a day can overlap the next night's test of another disk. Disks in a ZFS mirror or raidz get a short error recovery time (7 seconds) at every boot (`hs disk erc list` shows them);
single disks and SnapRAID disks keep the default. Not tested on hardware yet.

To let spinning disks sleep, set `diskSpindownMinutes` (for example 30) in `machine.toml` and run `hs rebuild`. `hs disk spindown` shows the
state. SSDs never sleep. The first access after sleep takes 10 to 20 seconds.

`hs health` lists problems with the command that helps, and the server sends a push message when the set of problems changes
([Operations](operations.md)).

## Work on a disk by hand (SnapRAID)
**Never copy or move files by hand between a disk of the pool and `/bulk`** (with `cp`, `mv`, `rsync`, a file manager). While a disk is in
the pool, its files and the files in `/bulk` are the same files. Copying a file onto itself empties it first, and the "move" then deletes
it. This has lost terabytes without a single error message.

That is why the pool disks are not under `/mnt/bulk/data-NN` but under `/var/lib/hs/disks/data-NN`. Do not browse there. Use these
instead:

| I want to | Do this |
| --- | --- |
| put a folder on another disk | `hs disk <disk> move` |
| empty a disk | `hs pool bulk close <disk> --drain` |
| work on a disk with my own tool | `hs disk <disk> detach`, later `attach` |
| move files to another folder or share | move them inside `/bulk` (this is a rename, nothing is copied) |
| get deleted files back | `hs disk <disk> recover` |

**Move a folder to another disk.** The copy goes disk to disk with the same path, so `/bulk` shows the same files the whole time. A file
that already exists on the target is never overwritten. A closed disk is never a target. It runs as a background job.

```bash
sudo hs disk data-04 move shares/media/movies --to data-05
```

**Take a disk out for a while.** A detached disk is not in the pool, so copying from it into `/bulk` is safe. Its files are missing in
`/bulk` meanwhile, and the parity check is skipped. After 2 hours the health check reminds you.

```bash
sudo hs disk data-04 detach
sudo hs disk data-04 attach
```

A disk with open files is not detached; nothing changes then.

### Look at an old disk (USB, hot-plug)
For a disk with data that is not part of the server (for example NTFS from Windows): it is mounted read-only and offered as a share.
Nothing is formatted.

```bash
hs disk temp
sudo hs disk temp mount /dev/sdX1
sudo hs disk temp copy <name> <share>
sudo hs disk temp eject
```

`mount` shares it as `temp-<name>` for administrators (`--rw` mounts it writable); `copy` copies everything into an existing share
(create one with `hs share add`). All of them take `--dry-run`. A disk Windows did not shut down cleanly can only be mounted read-only.

## Recover deleted files (SnapRAID)
This works only while the freed space on the disk has not been overwritten. **Stop writing to that disk at once.**

```bash
sudo hs disk data-04 recover --to data-03
```

The disk leaves `/bulk`, is set read-only and is read completely (roughly one hour per 500 GB). It is never written to. Without `--to` the
disk with the most free space is used. The result is in the share `recovered`, in the folder `data-04-<date>`, sorted into `videos`,
`photos`, `music`, `documents` and `other`. Copy what you want to keep to its place inside `/bulk`, then give the disk back:

```bash
sudo hs disk data-04 recover-finish
```

What to expect: the file names and folders are gone (files come back numbered, found by their content); a file written in one piece
usually comes back whole, a file written in pieces can come back truncated; data with no recognisable start cannot be found. Until you
finish, the files of that disk are missing in `/bulk`; the health check complains after 3 days.

## Move existing disks into the server (for example from Unraid)
Disks that already hold files can join the pool **where they are**: nothing is copied or erased. Their filesystem stays (xfs, ext4 or
btrfs), also when encrypted with LUKS. Every top folder of a disk becomes a folder inside its `shares/` folder, which is a rename.
Unraid's parity is replaced by SnapRAID's. Not tested on hardware yet with a real Unraid server; the technique is tested with test disks.

**Before you start:** copy what matters to somewhere else (the parity disk is erased and there is a window without protection), stop
Unraid's array cleanly (an unclean disk is refused), and keep the passphrase of encrypted disks at hand. The parity disk must be at least
as large as your largest data disk. Copy configuration you need from the cache pool to a data disk; the cache SSDs become `fast` and are
erased.

1. Install with `bulkType = "snapraid"` ([Install](install.md)) and create `fast` from the old cache SSDs.
2. Look at the old disks. This changes nothing.

   ```bash
   hs migrate check --parity <parity-disk>
   ```

3. See what would happen. Encrypted disks ask for the passphrase and show as `[encrypted]`. Check that exactly your data disks appear and
   that each shows its files.

   ```bash
   sudo hs pool bulk add --role adopt --dry-run
   ```

4. Adopt **one** disk first. You type `bulk` to confirm.

   ```bash
   sudo hs pool bulk add --role adopt --disks <by-id-name>
   ```

   Check `df -h /bulk` and `ls /bulk/shares`, then adopt the others, separated by commas. Each top folder becomes a share named
   `<disk>-<folder>` (for example `data-02-media`). To merge same-named folders from several disks into one share, as Unraid does, add
   `--merge`. If Samba may not change the files (they belong to `nobody:users`), add `--chown`; it is slow on big disks.
5. Publish the shares, then check a few files from a computer.

   ```bash
   sudo hs share repair
   ```

6. Only now the parity. **The parity disk is erased, also an old Unraid parity, and there is no way back to Unraid.** Until the first
   sync finishes (about a day) nothing protects against a disk failure.

   ```bash
   sudo hs pool bulk add --role parity --encrypt --disks <parity-disk>
   sudo hs pool bulk sync
   ```

   Leave out `--encrypt` if the disks are not encrypted.

Before step 6 all files are still there and a folder can be moved back with `mv`. Afterwards the old parity is gone, but the files are on
the disks and SnapRAID protects them after the first sync. Later, replace small old disks one by one with `hs pool bulk replace data-NN
--disks <new-disk>`; it rebuilds from parity.

## Snapshots of shares (ZFS only)
A snapshot is a frozen state of a share that costs almost nothing while little changes. Take one before a big clean-up.

```bash
sudo hs share photos snapshot before-cleanup
hs share photos snapshots
sudo hs share photos rollback before-cleanup
```

**A rollback loses everything written after the snapshot**, and ZFS can only go back to the newest snapshot, so newer ones are deleted
first; the command asks before it does. With `shareSnapshots = true` in `machine.toml` (then `hs rebuild`) the server snapshots every
share each hour and keeps 24 hours, 7 days and 4 weeks; your own snapshots are never touched. `hs share <share> auto off` leaves one out.
With SnapRAID use the backup: `hs share <share> restore` brings files back ([Backup and recovery](backup-and-recovery.md)).

## Check that it worked
- `hs pool bulk` lists every disk with state `ONLINE`; with SnapRAID also the parity disk, and the last sync is recent.
- `hs disk list` shows no disk with a bad verdict.
- `hs health` reports no problem.
- A test file written to a share and read back from a computer works.

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| `cat /etc/hs/bulk-type` prints `zfs` on a SnapRAID plan | `bulkType` was missing at install time | stop; reinstall with `bulkType = "snapraid"` |
| `hs pool bulk sync` refuses: a disk is missing | a disk is out or failed | replace or re-attach it before any sync |
| `hs pool bulk sync` refuses: files deleted | more than 100 deletions since the last sync | check them; `--force` only if intended |
| a command says a disk is in use | a program still uses it; nothing was changed | `fuser -vm /var/lib/hs/disks/data-04` shows which |
| a disk is `MISSING` | gone or unplugged | plug it in, or replace it |
| files are missing in `/bulk` | a disk is detached or in recovery | `hs pool bulk` shows `detached` or `recovery`; `attach` or `recover-finish` |
| `DEGRADED` pool | a ZFS disk failed | replace the disk |
| `hs pool bulk add` does not offer a disk | it is the system disk, already in a pool, or has a signature | check `lsblk`; a disk with foreign data is offered only with a warning, never select one you want to keep |

## Next
- [Users and shares](users-and-shares.md): who may use which share.
- [Encryption and vault](encryption-and-vault.md): one passphrase for every disk.
- [Backup and recovery](backup-and-recovery.md): the second copy.
