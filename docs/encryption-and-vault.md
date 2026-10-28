# Encryption and vault

How Hobnix protects data at rest: one passphrase opens a small encrypted vault for the server's secrets and every encrypted data disk.
After each boot someone unlocks the server. This guide sets it up, explains what is locked while the server is locked, and covers
encrypting disks, moving the vault and replacing the system disk.

## Before you start
- A server installed with [Install](install.md), logged in as `admin` with `sudo`.
- **One passphrase for everything**: a long sentence of five or six random words. It opens the vault and every encrypted disk and ZFS
  pool. Write it in your password manager **and** on paper in a second place. It is deliberately not on the server and not in the
  backup. **If it is lost, the vault and all encrypted disks are unreadable, and nothing can recover them.**
- A recent backup ([Backup and recovery](backup-and-recovery.md)).
- A push address for the "unlock needed" message that is **not** a service on this server (see [Get told after a boot](#get-told-after-a-boot)).

## How it fits together
The system disk is **not** encrypted. It boots without anyone typing anything, as far as the SSH server (port 22). What must stay
secret (passwords, keys, credentials) is not `/nix/store`; it lives in a small encrypted partition on the system disk, the **vault**.
Data disks and the pool `fast` can be encrypted too. After a boot the vault and the encrypted disks are closed until `hs unlock` runs.

| What | Where | Opened by |
| --- | --- | --- |
| the server's secrets | the vault, a LUKS2 partition of about 10 GiB on the system disk, mounted at `/var/lib/hs-vault` | `hs unlock` (the passphrase) |
| encrypted data disks (SnapRAID layout) | LUKS on each disk | `hs unlock` |
| encrypted ZFS pools (`fast`, ZFS `bulk`) | ZFS native encryption | `hs unlock` |

What is in the vault, under `/var/lib/hs-vault/secrets/<name>` (the old path `/var/lib/hs/<name>` is a link, so scripts keep working):
the backup password (`restic-password`), the off-site backup credentials (`backup-offsite.env`), the optional disk key file
(`disk-key`), the router credentials (`unifi`), the monitoring admin password (`grafana-admin`), and whatever else `hs secrets` lists;
also the Samba domain-member secrets and other host secrets that are bound into the vault as whole folders.

Not in the vault: the push address (`notify-url`, it must work while the vault is closed), the SSH host keys (sshd needs them to
start) and `machine.toml` (public keys only).

## Set up the vault
Do this once, on a free partition of the system disk named `vault`. If you partitioned the disk during [Install](install.md) it exists.
The partition must be empty and never mounted.

Look at the partition first:

```bash
lsblk -o NAME,SIZE,PARTLABEL,FSTYPE
```

`vault` must be a partition of the system disk (about 10 GiB) without a filesystem. Then make the vault. You are asked for the
passphrase twice; type it **exactly as it applies to your encrypted data disks**, so one `hs unlock` opens everything.

```bash
sudo hs vault init
```

Without an argument it lists free partitions to choose from. `--dry-run` shows the plan. A partition that is mounted or holds a
signature is refused; `--wipe` allows it, and only ever on the `vault` partition of the system disk. Name the partition by
`/dev/disk/by-partlabel/vault` or by-id, never `/dev/sdX`. `init` also saves a copy of the LUKS header (below).

Move the existing secrets into the vault and check:

```bash
sudo hs vault move
hs vault status
hs vault list
```

`move` leaves a link at the old place so scripts still find each secret. Without names it moves the usual ones that exist. A whole
folder goes in with `hs vault bind <name> <folder>`. `hs vault open` and `hs vault close` open and close the vault by hand; closing is
refused while something uses it.

Save a copy of the LUKS header **outside the server**. If the header of the partition is damaged, the vault cannot be opened even with
the passphrase. The file is as sensitive as the vault itself (with the passphrase it opens it): keep it in the password manager, not on
an unencrypted disk.

```bash
sudo hs vault header-backup
```

This writes `/var/lib/hs/vault-header` (part of the host backup). Not tested on hardware yet: restoring a vault from this header.

## Unlock after every boot
At boot nothing is opened. The server writes the marker `/run/hs/storage-locked` and sends the push message "unlock needed". Then:

```bash
ssh admin@homeserver
sudo hs unlock
```

`hs unlock` asks for the passphrase once and opens, in this order: the vault; every other encrypted disk and ZFS pool (with the key file
from the vault if there is one, otherwise the typed passphrase); then it starts the services that wait for them (Incus, Samba, the
pool mounts and timers). It also unlocks only disks that belong to this server: LUKS disks that are not listed in
`/var/lib/hs/luks-uuids` are other people's and are never opened (`--all` opens and adopts unknown ones on purpose).

| Command | Does |
| --- | --- |
| `hs unlock` | asks for the passphrase and opens everything |
| `hs unlock --status` | what is encrypted and whether it is open |
| `hs unlock --list` | the same for tools: type, device, state, size, tab separated |
| `hs unlock --setup-key` | keeps a key file for the data disks in the vault, so they open without a second prompt |
| `hs unlock --remove-key` | deletes that key file |
| `hs unlock --passphrase-stdin` | reads the passphrase from standard input, for tools that unlock over SSH |

The vault itself always needs the passphrase; the key file only saves typing it again for the data disks. A wrong passphrase changes
nothing (ZFS says "Incorrect key provided").

**Unlocking from another computer.** Any computer with SSH can do it: `ssh admin@homeserver` then `sudo hs unlock`. A tool can call
`hs unlock --passphrase-stdin` over SSH and pass the passphrase on standard input, never as an argument. Your SSH public key must be in
`sshKeys` of `machine.toml` (`sudo hs ssh-key add "<public key>"`, then `sudo hs rebuild`). Tell your SSH client about a new host key
if you replaced the system disk without restoring the old one.

**The console keyboard.** If you type the passphrase on the server's console, set `keyMap` in `machine.toml` (for example `hs config set
keyMap de`, then `hs rebuild`); the default is a US layout, where `y` and `z` are swapped.

## What is locked while the server is locked
- Incus (containers and VMs), the ZFS mounts, Samba, the pool mounts and the pool timers stay down. Shares and containers are gone
  until `hs unlock`.
- Everything that needs a secret says so: "The vault is closed: run `hs unlock`", and stops with an error, instead of a puzzling "file
  not found". Scheduled jobs skip their run and write a log line.
- The backup does not run (its password is in the vault).
- `hs update` and `hs rebuild` refuse until you unlock.
- `hs health` reports the lock. The push message still works because its address is not in the vault. The messages are: urgent "unlock
  needed" (at boot, repeated until it arrives), normal "started, vault open", low "restart" and "shutting down", and "unlocked" after
  `hs unlock` (it also shows when somebody else did it).

## Get told after a boot
When the storage is locked, every container is down, including a notification container of your own. So the push address must point to a
service outside the server, for example a public ntfy topic with a long random name. That topic is the only secret: anyone who knows it
can read your messages.

```bash
sudo hs config set notifyUrl https://ntfy.sh/<long-random-topic>
sudo hs rebuild
```

Subscribe to the topic in the ntfy app. A file `/var/lib/hs/notify-url` written by a recipe takes precedence over `machine.toml` and must
be removed first.

## Encrypt data disks (SnapRAID layout)
New disks are encrypted when you add them:

```bash
sudo hs pool bulk add --role data --encrypt
```

The dialog asks for the passphrase and checks it against a disk that is already encrypted. To encrypt a disk that holds data, convert
it: its files move to the other disks, the disk is formatted with LUKS and ext4, and the files come back.

**Before you convert anything**, make sure the backup is fresh, the parity is current (`sudo hs pool bulk sync` says the parity is up to
date) and `hs health` is clean. Then, one disk at a time:

```bash
sudo hs pool bulk convert data-01 --encrypt
sudo hs pool bulk sync
```

Check `hs pool bulk`: the disk shows `luks` under encryption. The passphrase is asked again for each disk.

**The parity disk has no `convert`.** Remove it and add it again encrypted; in between nothing protects the data, so a failed disk
would be restored from the backup instead. Do this only with a fresh backup and no unlock or reboot in between:

```bash
sudo hs pool bulk remove parity-1
sudo hs pool bulk add --role parity --encrypt --disks <parity-disk>
sudo hs pool bulk sync
sudo hs pool bulk sync --scrub
```

The first sync after this reads every disk (many hours); let it run as a background job (`hs job list`, `hs job follow <unit>`). Disks
that hold files from another system (Unraid, NTFS) are first adopted or mounted with `hs disk temp`, then optionally converted
([Storage and disks](storage-and-disks.md)).

## Encrypt the pool `fast` (ZFS)
**A ZFS pool cannot be encrypted afterwards, and `hs` has no command for this. Do it only if you must.** The way is to build a new
encrypted pool on one SSD of the mirror, send the data over, swap the pools and re-attach the second SSD. All containers are stopped for
the whole time (an hour for about 15 GB), so plan a window with a screen and keyboard at the server. The procedure was rehearsed
end to end in a throwaway VM (ZFS 2.2); on a server with another ZFS version, do not skip the checks marked MUST. Not tested on hardware
yet: the boot path with `hs unlock` for an encrypted `fast`.

`fast` needs a fresh backup first. Open `bash` (not zsh) and stay in **that one session**; the variables only exist there. `A` and `B`
are the two SSDs of the mirror by-id names, `B` becomes the new pool.

```bash
B=/dev/disk/by-id/<ssd-b>
A=/dev/disk/by-id/<ssd-a>
zpool status fast
```

Both must be `ONLINE` without errors. Then:

1. **Stop everything that uses `fast`.** Stop all containers, Incus with its sockets, Samba, and anything that uses the upload cache:

   ```bash
   incus stop --all
   systemctl stop incus.service incus.socket incus-user.service incus-user.socket incus-startup.service
   zfs snapshot -r fast@migrate
   ```

2. **Take SSD B out of the mirror and build the new pool on it.** The new pool has no redundancy until step 5. Do not reboot while two
   pools named `fast` exist; NixOS imports by name and could pick the wrong one.

   ```bash
   zpool detach fast <ssd-b-name-in-zpool-status>
   wipefs -a $B
   read -rs -p "Passphrase: " P; echo
   printf %s "$P" | zpool create -o ashift=12 -O compression=lz4 -O atime=off -O xattr=sa \
     -O encryption=aes-256-gcm -O keyformat=passphrase -O keylocation=prompt fast2 $B
   ```

3. **Send each top-level dataset, with `-x encryption`.** Without that switch the data arrives unencrypted, with no warning.

   ```bash
   zfs send -R fast/incus@migrate | zfs recv -u -x encryption fast2/incus
   zfs get -r -H -o name,value encryption fast2 | grep -c ' off$'
   ```

   The count **MUST be 0**. Anything else: stop, `zpool destroy fast2`, and `zpool attach fast <ssd-a-name> <ssd-b-name>` restores
   the mirror. Send any other top-level dataset the same way (`zfs list -r -o name fast`).

4. **Swap the pools.** The old one is exported, the new one is imported as `fast`:

   ```bash
   zpool export fast
   zpool export fast2
   zpool import -d /dev/disk/by-id fast2 fast
   printf %s "$P" | zfs load-key fast
   zfs mount -a
   zpool list
   ```

   Exactly one pool `fast` must show, on SSD B. Start Incus again (`systemctl start incus.socket incus.service`), check
   `incus list` and one container, then `zfs destroy -r fast@migrate`.

5. **Rebuild the mirror.** **This erases SSD A, the last copy of the old unencrypted pool.** Until now it is your way back (import it
   read-only with `zpool import -d /dev/disk/by-id -o readonly=on -R /oldroot <number> oldfast`).

   ```bash
   wipefs -a $A
   zpool attach fast <ssd-b-name> <ssd-a-name>
   zpool status fast
   zpool scrub fast
   ```

After the next reboot `fast` is locked, Incus and Samba wait, and `hs unlock --status` shows the pool as locked; `hs unlock` opens it
together with the data disks. If the pool does not appear, the plan B at the console is `zpool import -d /dev/disk/by-id fast`, `zfs
load-key fast`, `zfs mount -a`, `systemctl start incus.socket incus.service`.

The **backup disk** stays unencrypted on purpose: the restic repository on it is already encrypted with its own password, and a second
layer would only add another unlock step. That password is in the vault and **not in the host backup**: keep a copy in your password
manager.

## The system disk stays unencrypted
Encrypting the system disk (LUKS root with SSH in the initrd) is not supported any more: it was fragile, and its `encryptedRoot`,
`unlockIp` and `unlockGateway` options are gone. A server built that way no longer boots with the current configuration; move it with
the steps below.

What a thief sees of a switched-off server (or one that was rebooted and not unlocked yet):

| Sees | Does not see |
| --- | --- |
| `/nix/store` (public programs), `machine.toml` (public keys, host name, no passwords), the logs and the normal state under `/var/lib/hs` | the vault: the backup password, router key, off-site credentials, disk key file |
| the SSH host keys (they could impersonate the server, not sign in) and the push address | shares and containers, if the data disks and `fast` are encrypted |
| | the backup disk contents (encrypted with the backup password) |

Not protected: a running, unlocked server (root access there is everything), and any data disk you left unencrypted. Secrets that were
once stored unencrypted on a disk before the move into the vault stay readable in its free blocks; on an SSD you retire,
`blkdiscard` clears them.

## Move the system to a new disk
Use this to replace the system disk while the old one still works. The old disk stays unchanged and is the way back at every step. If
the old disk is dead, rebuild instead ([Backup and recovery](backup-and-recovery.md)).

**Only one system may run at a time**: it shares the same pools and data disks. Have a screen and keyboard at the server. Every command
as root; name disks by their `by-id` path.

```bash
A=/dev/disk/by-id/<new-system-disk>
readlink -f $A
findmnt /
```

The first must show the new disk, the second must not. Partition it with EFI (512 MiB), the vault partition (the **same size as on the
old disk**, 10 GiB) and the rest as root, format and copy the running system. The `-x` keeps rsync on the root filesystem. Give the
EFI filesystem its own random ID, otherwise two EFI partitions may share one.

```bash
nix-shell -p gptfdisk dosfstools rsync parted e2fsprogs efibootmgr
sgdisk --zap-all $A
sgdisk -n1:0:+512M -t1:ef00 -c1:ESP -n2:0:+10G -t2:8309 -c2:vault -n3:0:0 -t3:8300 -c3:nixos $A
partprobe $(readlink -f $A); udevadm settle; sleep 2
mkfs.ext4 -L nixos-new ${A}-part3
mkfs.vfat -F32 -n BOOTNEW -i "$(printf %08X $((RANDOM*65536+RANDOM)))" ${A}-part1
mkdir -p /mnt/new && mount ${A}-part3 /mnt/new
mkdir -p /mnt/new/boot && mount -o umask=0077 ${A}-part1 /mnt/new/boot
rsync -aAXHx --info=progress2 --exclude='/dev/*' --exclude='/proc/*' --exclude='/sys/*' --exclude='/run/*' \
  --exclude='/tmp/*' --exclude='/mnt/*' --exclude='/lost+found' / /mnt/new/
mkdir -p /mnt/new/{dev,proc,sys,run,tmp,mnt}; chmod 1777 /mnt/new/tmp
```

In the copy, put the new root and boot UUIDs (from `blkid -s UUID -o value ${A}-part3 ${A}-part1`) into
`/mnt/new/etc/nixos/hardware-configuration.nix`; keep the old and new boot UUID different. Then install the boot loader (the chroot has
no name resolution, hence `resolv.conf`):

```bash
rm -f /mnt/new/etc/resolv.conf; echo "nameserver 192.168.1.1" > /mnt/new/etc/resolv.conf
nixos-enter --root /mnt/new -c 'nixos-rebuild boot --install-bootloader'
sync; umount /mnt/new/boot /mnt/new
```

Reboot into the new disk (firmware menu, entry "Linux Boot Manager" of the new disk, or `efibootmgr -n <number>` for one boot only).
Check:

```bash
findmnt / /boot
hs unlock --status
```

Make the vault on the new disk (`sudo hs vault init ${A}-part2`, then `sudo hs vault move`), or copy the old one:
**the vault copy has the same LUKS UUID as the old vault, so only one of the two disks may be connected when you boot**. Not tested on
hardware yet: how `hs vault` behaves with two equal UUIDs.

```bash
sudo hs vault close
dd if=<old-vault-partition> of=${A}-part2 bs=1M status=progress conv=fsync
sudo hs unlock
```

Let the new system run for a week, with a reboot and an update, before you erase the old disk. Erase it with `sgdisk --zap-all`, and
`blkdiscard -f` on an SSD to clear leftover secrets. Remove the stale "Linux Boot Manager" entries with `efibootmgr -b <number> -B`.

## Check that it worked
- `hs vault status` shows the vault open after `hs unlock`, and `hs vault list` lists the secrets.
- After a test reboot: `ls /run/hs/storage-locked` exists, the push message arrived, `sudo hs unlock` opens the vault and all disks with
  one entry, `hs unlock --status` shows nothing locked.
- `hs pool bulk` shows `luks` (and `fast` as ZFS-encrypted) for every disk you encrypted.
- The passphrase and the backup password are in the password manager and on paper in a second place.

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| after a reboot `/bulk`, containers and Samba are gone | the server is locked, not broken | `sudo hs unlock` |
| `hs update` or `hs rebuild` refuses | locked | `sudo hs unlock` first |
| `hs unlock` opens the vault but not the disks | the vault passphrase differs from the disks' | check which passphrase each uses; the vault can be made again with `hs vault init --wipe` only while it holds nothing you need |
| `hs vault init`: "already holds a ... signature" | the partition is not empty, or it is the wrong one | check with `lsblk -o NAME,SIZE,PARTLABEL,FSTYPE`; `--wipe` only on the `vault` partition |
| no push message after a boot | `notifyUrl` is missing or points at a service on this server | set a public ntfy topic |
| SSH says "host key changed" | new system disk without the saved SSH host keys | remove the old entry from your `known_hosts` |
| a disk is missing from the unlock list | its LUKS UUID is not in `/var/lib/hs/luks-uuids`, or its filesystem is unsupported | `hs unlock --all` adopts a disk you know; `sudo blkid -p /dev/sdX1` shows `crypto_LUKS` when encrypted |
| the passphrase is lost | nothing can recover the vault or the disks | build a new server from the backup with a new passphrase and vault |

## Next
- [Backup and recovery](backup-and-recovery.md): rebuild after a disk failure, with a new vault.
- [Storage and disks](storage-and-disks.md): the disk layouts that you encrypt here.
- [Operations](operations.md): health messages and alerts.
