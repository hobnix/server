# Disk failures

What to do, case by case, when a disk or a pool fails: what to check first, what to do, and what not to do. For people who run a server
with [Storage and disks](storage-and-disks.md).

## Before you start
- A server with pools set up as in [Storage and disks](storage-and-disks.md). You are logged in as `admin` over SSH and use `sudo`.
- A backup you can restore from ([Backup and recovery](backup-and-recovery.md)). A pool protects against a failed disk, not against damage
  to files.
- **None of these cases was run on a real failure. Not tested on hardware yet.** A step that uses a plain ZFS or SnapRAID tool instead of
  `hs` says so, because `hs` does not wrap it.

Rules for every case: do not reboot, power off or unplug anything before you know which disk it is. Name a disk by its `/dev/disk/by-id/`
name or by its pool name (`data-02`), never by `/dev/sdX`. Start here:

```bash
hs health
```

`hs health` lists each problem with the command that helps. Then see the disks:

```bash
hs disk list
```

## A ZFS pool is `DEGRADED`
A disk of a mirror failed. The pool works and every file is still on the other disk. Find the failed disk (`FAULTED`, `UNAVAIL` or
`REMOVED`):

```bash
zpool status -v bulk
```

Fit a new disk that is at least as large, then replace the old one. **All data on the new disk is erased.** You type the name of the disk
that is replaced.

```bash
sudo hs pool bulk replace <member> --disks <new-disk>
```

ZFS copies the data onto the new disk in the background (resilver) and the pool stays usable. Follow it with `zpool status bulk`.
Not tested on hardware yet.

Do not:
- Pull the second disk of the same mirror, even if it looks healthy: until the resilver ends it holds the only copy.
- Run `zpool clear` to make the warning go away; it hides the errors you still need to read.

## A disk is gone
It is unplugged or dead. First check cable and power and plug it in again; look at what the server saw:

```bash
hs disk events
```

If the disk comes back, nothing else is needed: ZFS resyncs the gap by itself, and SnapRAID catches up with the next sync. If it stays gone:

- **ZFS:** the pool is `DEGRADED`. A disk that vanished completely shows as a long number (its GUID) in `zpool status`, and `hs` takes that
  number as the member: `sudo hs pool bulk replace <guid> --disks <new-disk>`. Not tested on hardware yet.
- **SnapRAID data disk:** see [A SnapRAID data disk failed](#a-snapraid-data-disk-failed).
- **The disk is never coming back:** after the replacement, remove its entry from the inventory. The command asks first.

```bash
sudo hs disk <serial> forget
```

Do not run `hs pool bulk sync` while a SnapRAID disk is missing. It refuses, and `--force` would not help: SnapRAID would treat the files of
the missing disk as deleted and overwrite the parity that can rebuild them.

## A SnapRAID data disk failed
The disk shows as `MISSING` or not `ONLINE`:

```bash
sudo hs pool bulk
```

Files written since the last sync (nightly at 03:00) are lost; everything older can be rebuilt from parity. The nightly sync now fails and
pushes a message. That is expected and protects the parity.

Fit a new disk (not larger than the parity disk) and replace the failed one. **All data on the new disk is erased.** You type the name of the
old disk.

```bash
sudo hs pool bulk replace <member> --disks <new-disk>
```

SnapRAID rebuilds the files from parity and then updates the parity. This reads every disk and takes many hours; the dialog offers a
background job (`hs job list`, `hs job follow <unit>`). Not tested on hardware yet.

Do not:
- Format, repair (`fsck`) or write to the old disk before the rebuild is done, even if it still half works.
- Start a sync or a second replace while the rebuild runs.
- Expect this to work with no parity disk: a data disk cannot be replaced then. Restore the files from the backup instead.

## The SnapRAID parity disk is lost
No data is lost, but nothing protects the data disks now: a second failure before the new parity is built loses that disk's files. The
health check shows the parity member (for example `parity-1`) as `MISSING` or not `ONLINE`, and the nightly sync stops with "not mounted".

Replace the parity disk like a data disk. It must be at least as large as the largest data disk; the command refuses a smaller one.
**All data on the new disk is erased.**

```bash
sudo hs pool bulk replace parity-1 --disks <new-disk>
```

`hs` formats the disk and recomputes the whole parity from the data disks. This takes many hours; run it as a job. Not tested on hardware yet.

Do not:
- Delete large amounts of data to "make room" while the parity is missing: without parity a delete cannot be undone.
- Use `hs pool bulk add` for this: `replace` is the path that handles a parity member that is listed but gone.

## Scrub errors on a ZFS pool
`hs health` shows `zfs:<pool>:scrub-errors`. ZFS repairs a bad block from the other mirror disk by itself; errors that remain mean no good
copy exists. List the damaged files:

```bash
zpool status -v bulk
```

Then:
1. Look at the disk verdicts (`hs disk list`). A disk with growing errors is failing: replace it as in [A ZFS pool is
   `DEGRADED`](#a-zfs-pool-is-degraded).
2. Restore each damaged file from the backup (`hs backup restore latest <path>`), or delete it.
3. Scrub again with `sudo zpool scrub bulk` (a plain ZFS command), then read `zpool status bulk`. Only when the scrub is clean, run
   `sudo zpool clear bulk`.

Not tested on hardware yet.

Do not run `zpool clear` before you have noted the damaged files, and do not ignore errors that repeat on the same disk: it is the disk.

## Scrub errors on a SnapRAID pool
The weekly scrub ended with "The check did not finish" and pushed a message. Read what it found:

```bash
journalctl -u hs-bulk-scrub -n 50
```

`hs` does not repair by itself; the repair is a decision for a person, on purpose. The next command is the SnapRAID tool, not an `hs` command:

```bash
sudo snapraid -c /var/lib/snapraid/snapraid.conf status
```

Then:
1. Find the disk the errors are on and look at its verdict: `hs disk <disk> health`. If it is failing, replace it first.
2. Make sure no sync ran since the damage, so the parity still holds the good data.
3. Repair only the blocks the scrub found wrong:

```bash
sudo snapraid -c /var/lib/snapraid/snapraid.conf -e fix
```

To check the result, run the scrub again (`sudo hs pool bulk sync --scrub`; it checks the oldest 12 % of the data, so it is a spot check) and
read `sudo snapraid -c /var/lib/snapraid/snapraid.conf status`. Not tested on hardware yet.

Do not run `hs pool bulk sync --force` to make the message go away: it makes the damage permanent. Do not change files under
`/var/lib/hs/disks/` by hand.

## A ZFS pool does not import
`hs health` shows `zfs:<pool>:missing` ("ZFS pool is not imported"), or `/bulk` or the containers are missing after a boot. Rule out the
common cause first: encrypted pools wait for the passphrase after every boot ([Encryption and vault](encryption-and-vault.md)).

```bash
sudo hs unlock
```

If the pool is still not there, read why it did not import:

```bash
journalctl -u zfs-import-bulk -b
```

Then list the pools ZFS can see. This changes nothing:

```bash
sudo zpool import
```

Missing disks in that list point to a cable, a controller or a dead disk (`hs disk list`). If the pool is listed as `ONLINE` or `DEGRADED`,
import it by name (a plain ZFS command):

```bash
sudo zpool import bulk
```

Then check `hs health`. Not tested on hardware yet.

Do not:
- Add `-f` just because the plain import failed. It overrides the check that another system still uses the pool and can corrupt it. Use
  it only when you are sure the other system is off.
- Use `zpool import -F` (rewind) before you have asked for help; it throws away the last transactions.
- Run `hs pool bulk add` or `zpool create` on the disks to start again: **that erases the data.** A pool you cannot see is not a pool that
  is gone.
- Reboot in a loop. Read the journal first.

## Check that it worked
- `hs health` lists no problem for the pool or the disk.
- `hs pool bulk` shows every member `ONLINE`; `zpool status` shows no resilver or errors on a ZFS pool.

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| `hs pool bulk replace` says "Can't find ... in zpool status" | the disk has no name in the pool any more | use the number (GUID) that `zpool status` shows |
| `hs pool bulk sync` refuses: a disk is missing | a disk is out or failed | replace or re-attach it first |
| a command says a disk is in use | a program still uses it; nothing was changed | `fuser -vm /var/lib/hs/disks/data-04` shows which |
| more than one disk failed | a second failure before the rebuild ended | stop; restore from the backup ([Backup and recovery](backup-and-recovery.md)) |

## Next
- [Storage and disks](storage-and-disks.md): add, replace and remove disks when nothing is wrong.
- [Backup and recovery](backup-and-recovery.md): the second copy.
