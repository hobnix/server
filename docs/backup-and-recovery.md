# Backup and recovery

How the server is backed up, how to get files and containers back, and how to build the server again after a disk or the whole machine is
gone. A backup is a second, separate copy: snapshots and parity on the same disks protect against a failed disk, not against a folder
you deleted by mistake.

## Before you start
- A server installed with [Install](install.md), logged in as `admin` with `sudo`.
- A spare disk for the backup, **not** the system disk or a pool disk. It is erased.
- A password manager, and a second place for paper copies. Two secrets belong there and nowhere else: the **backup password** and the
  **passphrase of the vault and the encrypted disks** ([Encryption and vault](encryption-and-vault.md)). Neither is in the backup, on
  purpose. Without the backup password the backup is worthless; without the passphrase the vault and encrypted disks are unreadable.

## What is backed up
`hs backup` uses restic on a plain ext4 disk labelled `backup`. The disk is mounted only while a command needs it. The repository is
encrypted with its own password. It runs every night at 04:00.

| In the backup | Not in the backup |
| --- | --- |
| shares, but only the ones you switch on (see below), tag `shares` | the backup password and the vault passphrase |
| host files, tag `host`: `machine.toml`, `hardware-configuration.nix`, `/var/lib/hs`, the SSH host keys, the Samba domain-member secrets, an inventory of containers, profiles, networks and disks | the operating system: it comes from the repository with `hs rebuild` |
| containers and VMs you switch on, tag `ct:<name>` | shares and containers you switched off |
| the domain controller, if you run one, with Samba's own backup | accounts in outside services (Cloudflare, Tailscale, the router) |
| | the upload cache and game server backups (they are backups already) |

The pool disks are mounted under `/var/lib/hs`, which the host backup includes; `hs backup` excludes them explicitly, so the whole array
never ends up in the host snapshot.

A new share starts **out** of the backup so large replaceable data (films, downloads) does not fill the disk. Set `backupNewShares =
true` in `machine.toml` to change that default. Retention is 7 daily, 4 weekly and 6 monthly snapshots.

## Set up the backup disk
Look at the disks first. **The chosen disk is erased.**

```bash
lsblk -o NAME,SIZE,MODEL,FSTYPE
```

Make it the backup disk. Without a device the free disks are listed to pick from; `--dry-run` shows the plan. You type `backup` to
confirm. At the end the **password is shown once**.

```bash
sudo hs backup init /dev/sdX
```

**Copy the password into your password manager now.** Then choose what goes into the backup:

```bash
sudo hs backup photos on
sudo hs backup ct radarr on
```

`hs backup <share> on|off` switches a share, `hs backup ct <name> on|off` a container (it has to be running) or a VM. Run the first
backup and look at the state:

```bash
sudo hs backup now
hs backup status
```

From then on it runs by itself each night. A push message arrives when a run fails, when the last good run is older than 36 hours or
when the backup disk is 85 % full. `hs backup status` shows what is in the backup, how big it is, how old, and whether the chosen
shares fit on the disk (sizes are measured overnight).

## Restore files
Files come back to a separate folder, **never over the live copy**. By default that is the share `restored`; create it once.

```bash
hs backup list
hs backup find invoice.pdf
sudo hs share add restored
sudo hs backup restore latest /bulk/shares/photos/2024 --to /bulk/shares/restored
```

The full original path appears below the target. Use `--tag ct:<name>` for a container and `--tag host` for the server settings. For a
single share without typing paths: `sudo hs share <share> restore`.

To look through the whole backup from a computer, read-only, as the share `backup-browse` (administrators only):

```bash
sudo hs backup browse
sudo hs backup browse --off
```

## Give space back
When the backup disk is full, or a run ended with "no space left":

```bash
sudo hs backup prune --dry-run
sudo hs backup prune
```

It deletes the leftovers of a run that ran out of space, clears stale locks, applies the retention and prunes. The nightly run prunes
only on Sundays, so this is the way to free space at once. `hs backup verify` checks part of the stored data.

## A second copy outside the house
The backup disk usually sits in the same case as the server: fire, theft or a power surge takes both. Add a second repository with the
same password: a folder on another disk (which you can carry away), another computer over SFTP, or a cloud bucket.

```bash
sudo hs backup offsite set /mnt/usb/hs-backup
sudo hs backup offsite set sftp:user@host:/path
sudo hs backup offsite set b2:my-bucket:homeserver
sudo hs backup offsite now
sudo hs backup offsite off
```

Put credentials (`B2_ACCOUNT_ID=...`, `B2_ACCOUNT_KEY=...`, one per line) in `/var/lib/hs/backup-offsite.env`, readable by root only
(`chmod 600`; the vault keeps it when a vault exists). Every nightly run then copies the new state along, for the shares and
containers that are switched on.

## Databases and VMs
A running database cannot be backed up by copying its files. Each container has a dump description, `/var/lib/hs/backup-dump/<container>`,
with one command per line (blank lines and lines starting with `#` are ignored); the backup runs each command inside the container and
stores its output next to the files. The recipes `immich`, `synapse`, `authentik`, `arr` and `seerr` set this up themselves with the
helper `hs-dump`. For your own application add a line:

```bash
hs-dump postgres <container> <database>
hs-dump postgres-compose <container> <folder> <service> <user> <database>
hs-dump sqlite <container> <file>...
hs-dump sqlite-tree <container> <folder>
```

To restore, put a `.pgdump` back with `pg_restore -d <database>` (inside the Docker Compose service:
`docker compose exec -T <service> pg_restore -U <user> -d <database> < file`), and copy SQLite files back into place while the
application is stopped.

`hs backup ct <name> on` also accepts a **VM**. restic cannot read a running VM disk, so the whole machine is exported to one file each
night. That needs about the used size of the VM as free space in `/var/tmp` (or `HS_VM_EXPORT_DIR`); with too little space the run warns,
skips the VM and counts as failed. The nightly backup waits for the export.

## Check that restoring works
A backup counts only if you can restore from it. These three checks exist; run them yourself and let the server run them for you.

```bash
sudo hs backup drill
sudo hs backup drill ct
sudo hs backup drill ct radarr
```

- `drill` restores 5 random files from the newest backup into a temporary folder and compares them with the originals (run it every
  quarter).
- `drill ct` restores the container that was checked longest ago (smallest first) into a throwaway instance without a network, boots it
  and deletes it. It needs about twice the container's size free in `/var/tmp` (`HS_DRILL_TMP` changes the place). It also checks the
  domain controller backup file and the export file of one VM.
- On the 25th of every month a push message reports the state of the drills; `sudo hs backup report` sends it now (`--dry-run` only
  shows it).

Once a year, also do the by-hand version: pick three random files, restore them, and compare.

```bash
find /bulk/shares/photos -type f | shuf -n 3
sudo hs backup restore latest <path> --to /bulk/shares/restored
diff <path> /bulk/shares/restored<path>
```

No output means the files are equal. A difference is normal if the file changed since last night's 04:00 run; a missing file or an error
is not: run `hs backup verify` and read the message. Empty the `restored` folder afterwards.

## Snapshots (ZFS layout)
On a ZFS server a share can also be rolled back to a frozen state, which is faster than a restore. `hs share <share> snapshot`,
`snapshots` and `rollback`, and the automatic hourly snapshots, are described in [Storage and disks](storage-and-disks.md). With the
SnapRAID layout there are no snapshots; the backup is the history.

## Rebuild the server
Read the checklist now, not on the day something breaks.

### Checklist for today
- [ ] The backup password is in the password manager, not only on the server (`hs secrets` reminds you).
- [ ] The vault passphrase is there too, and on paper in a second place.
- [ ] You know how to unlock after a boot (`sudo hs unlock`) and have done it.
- [ ] The backup disk is not in the same case as the server, or an off-site copy exists.
- [ ] You can reach the Git repository of the server configuration.
- [ ] You wrote down where the credentials live that are not in the backup: the Cloudflare account, the Tailscale account, the router.
- [ ] `hs backup status` shows a fresh backup, and `hs health` reports no stale restore test.

Not tested on hardware yet: a complete reinstall onto an empty disk with data from the backup, as a whole. The restore of the host files
and the shares is replayed by the repository's test suite.

### Case A: the system disk is gone, the data disks are fine
This is the common case. The pools and their data are untouched. The system disk is plain (GPT with an EFI partition and an ext4 root) plus
a small partition for the vault, so a new one is built the same way, and the server then boots to SSH and is unlocked with `hs unlock`.

1. **Have the backup password and the vault passphrase ready.** The new vault may use the same passphrase as before.
2. **Boot the NixOS installer, prepare the new disk.** Set up network and SSH, work as root over SSH. Name the disk only by `by-id`, and
   check with `lsblk -o NAME,SIZE,MODEL,SERIAL,MOUNTPOINTS` that it is not a data disk.

   ```bash
   D=/dev/disk/by-id/<new-system-disk>
   nix-shell -p gptfdisk parted dosfstools git
   sgdisk --zap-all $D
   sgdisk -n1:0:+512M -t1:ef00 -c1:ESP-new -n2:0:-10G -t2:8300 -c2:nixos -n3:0:0 -t3:8309 -c3:vault $D
   partprobe $D; udevadm settle
   mkfs.ext4 -L nixos ${D}-part2
   mkfs.vfat -F32 -n BOOT -i "$(printf %08X $((RANDOM*65536+RANDOM)))" ${D}-part1
   mount ${D}-part2 /mnt
   mkdir -p /mnt/boot && mount -o umask=0077 ${D}-part1 /mnt/boot
   ```

   The third partition stays empty; the vault is made later.
3. **Get the repository.**

   ```bash
   git clone <your-repository> /mnt/etc/nixos
   ```

4. **Mount the backup disk and restore the host files.** There is no `hs` yet, so use restic directly. A snapshot with the tag `host`
   must be listed.

   ```bash
   mkdir -p /mnt-backup && mount LABEL=backup /mnt-backup
   export RESTIC_REPOSITORY=/mnt-backup/restic
   export RESTIC_PASSWORD='<from the password manager>'
   nix-shell -p restic --run 'restic snapshots'
   nix-shell -p restic --run 'restic restore latest --tag host --target /tmp/host'
   ```

   The files come back with their old full paths under `/tmp/host`. Copy them into the new root:

   ```bash
   cp -a /tmp/host/etc/nixos/machine.toml /mnt/etc/nixos/machine.toml
   mkdir -p /mnt/var/lib/hs && cp -a /tmp/host/var/lib/hs/. /mnt/var/lib/hs/
   cp -a /tmp/host/etc/ssh/ssh_host_* /mnt/etc/ssh/
   ```

   Copying the SSH host keys keeps your computers from warning about a "new server". `/var/lib/hs` also holds `vault-uuid` (the UUID of the
   **old** vault, not a secret). The links to the secrets point nowhere until a vault exists.
5. **Generate `hardware-configuration.nix` again; do not copy the old one**, it has the UUIDs of the dead disk.

   ```bash
   nixos-generate-config --root /mnt
   ```

   Check that `/` and `/boot` are listed by UUID, and that there is no `boot.initrd.luks` block. If the hardware is different, check the
   network card name (`nic` in `machine.toml`). Old `machine.toml` lines `encryptedRoot`, `unlockIp` and `unlockGateway` have no effect
   and can be deleted.
6. **Install and unmount.**

   ```bash
   nixos-install --no-root-passwd
   umount /mnt/boot /mnt /mnt-backup
   ```

   If name resolution fails during the install, write a `nameserver` line to `/mnt/etc/resolv.conf`.
7. **Set the boot order.** The firmware now knows a new "Linux Boot Manager" entry and still the one of the dead disk. Put the new disk
   first in the firmware menu, or with `efibootmgr` (`nix-shell -p efibootmgr`): `efibootmgr -v` lists the entries, `efibootmgr -n <number>`
   tests one boot (look for `BootNext:`), `efibootmgr -o <n>,<n>` sets the order, `efibootmgr -b <number> -B` removes the old entry.
   Do not choose the legacy entry the menu also shows for the same disk.
8. **First boot.** The server starts as far as SSH on port 22; everything encrypted is locked. Log in and build the system:

   ```bash
   ssh admin@homeserver
   sudo hs rebuild
   ```

9. **Make the vault and put back the secrets that are deliberately not in the backup.**

   ```bash
   sudo hs vault init /dev/disk/by-partlabel/vault
   printf '%s' '<backup password>' | sudo tee /var/lib/hs/restic-password >/dev/null
   hs vault status
   ```

   Not tested on hardware yet: writing the password through the link into a fresh vault; if the link is missing, `hs vault list` shows
   what exists. Everything else is made again: the router credentials with `hs net setup`, the monitoring password, the off-site access with
   `hs backup offsite set`.
10. **Pools.** ZFS: `sudo zpool import -f fast bulk`. SnapRAID: disks are found by their labels and mounted automatically; check with
    `hs pool bulk`. Encrypted: `sudo hs unlock`.
11. **Containers and VMs.** Not tested on hardware yet. If they live in `fast`, the new Incus does not know them; this finds and registers
    them again:

    ```bash
    sudo incus admin recover
    hs ct list
    ```

    Check the MAC addresses (`hs mac`) and the router reservations.
12. **Finish.** `hs first-run`, `hs doctor`, `hs health`; open a share from a computer (users sign in again); `sudo tailscale up` if you
    use Tailscale; then `sudo hs backup now`.

After **every** boot the server is locked until someone runs `sudo hs unlock`. Without it the web interface shows LOCKED, Incus waits on
purpose, and `hs update` and `hs rebuild` end with an error. `hs unlock --status` shows what is still closed. Set `keyMap` in
`machine.toml` if you type the passphrase at the console.

### Case B: a data pool or disks are lost
1. Install the new disks (and, if the system is new too, do Case A up to step 10).
2. **Create the pool again.** The dialog asks for the filesystem and encryption; do not forget the parity disk with SnapRAID.

   ```bash
   sudo hs pool bulk add
   ```

3. **Bring the shares back to their old place** (the backup knows the full paths), publish them and set permissions:

   ```bash
   sudo hs backup restore latest /bulk/shares --to /
   sudo hs backup restore latest /bulk/sensitive --to /
   sudo hs share repair
   ```

   Then `sudo hs share <share> perm` for permissions, and `sudo hs pool bulk sync`. Only one share or file: `hs share <share> restore
   [<path>]` puts it into the share `restored`.
4. **Containers.** Not tested on hardware yet. Create a container of the same kind (`hs ct add <name>`), restore the files from the snapshot
   `ct:<name>` and copy them in:

   ```bash
   sudo hs backup restore latest <path-in-container> --tag ct:<name> --to /var/tmp/restore
   incus file push -r /var/tmp/restore/<path> <name>/<path>
   ```

   Docker applications: restore the project folders and load the databases from the dumps in `/var/lib/hs/backup-dump/<container>`.
   `hs backup drill ct` proves each month that a container boots from its snapshot; restoring into a new container is not covered by it.
5. **Domain controller.** Not tested on hardware yet. Make a new `dc1` VM with the recipe `domain`, then apply the backup file
   `/var/lib/hs/backup-dc/*.tar.bz2` with `samba-tool domain backup restore` (see the Samba documentation for `--targetdir` and the new
   server name).

### Case C: the server and the backup disk are both gone
Only the off-site copy is left. Do Case A with a new vault, but read the host files from the off-site repository:

```bash
export RESTIC_REPOSITORY='<address from the password manager, e.g. sftp:user@host:restic>'
export RESTIC_PASSWORD='<same password>'
restic snapshots
```

Afterwards set up a new backup disk with `hs backup init` and the off-site copy again with `hs backup offsite set ...`.

### After a rebuild
- [ ] `hs doctor` is green and `hs health` reports nothing.
- [ ] `sudo hs backup now`, then `sudo hs backup drill`: the new server backs up and can restore.
- [ ] A share opens from a computer and the permissions are right.
- [ ] Containers run, fixed addresses exist in the router (`hs net ip <ct>`), and any tunnel is connected.
- [ ] `hs secrets` shows the right permissions, and the backup password still has a second copy.

### Practise
Once a year, rehearse in a throwaway VM: a virtual machine with the NixOS installer, two small virtual data disks and a virtual `backup`
disk (a copy of the repository, or a fresh `hs backup init` with test data). Do Case A (disk with a vault partition, clone the
repository, host files with restic, a new `hardware-configuration.nix`, `nixos-install`, boot order, `hs vault init`, the password by
hand, `sudo hs unlock`, `hs rebuild`, pools). Then Case B: empty the data disks, add the pool, restore the shares and compare
checksums. This is the part nobody has run on real hardware yet. Write down what did not match this guide and report it.

## Check that it worked
- `hs backup status` shows a snapshot from last night and enough free space on the backup disk.
- `sudo hs backup drill` reports equal files.
- `hs health` has no backup problem and no stale restore test.
- Both passwords are in the password manager and on paper in a second place.

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| `hs backup now` says the vault is closed | the server is locked | `sudo hs unlock` |
| a run ends "no space left" | the backup disk is full | `sudo hs backup prune`, then add disk space or switch shares off |
| a share is missing from the backup | new shares start out | `sudo hs backup <share> on` |
| the container is not in the backup | it was not running, or not switched on | `sudo hs backup ct <name> on` while it runs |
| restic cannot open the repository | wrong password or the wrong disk | check the password in the password manager and the disk label |
| the first restore after a rebuild shows no `host` snapshot | the wrong repository or an empty backup | `restic snapshots` and check `RESTIC_REPOSITORY` |
| the `hs` command does not exist on the new system | the first `hs rebuild` has not run | `sudo nixos-rebuild switch`, then `hs` is there |
| everything is locked after the rebuild | normal | `sudo hs unlock` |

## Next
- [Encryption and vault](encryption-and-vault.md): the passphrase and the vault you remake in Case A.
- [Operations](operations.md): health messages and alerts that tell you about a failed backup.
- [Storage and disks](storage-and-disks.md): replace a failed data disk without a rebuild.
