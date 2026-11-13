# Install Hobnix

This guide takes you from a bare PC to a running Hobnix server: NixOS on a system disk, storage pools, Samba shares, Incus for containers
and the web interface. It ends with the first-run checklist. Everything after that is optional and has its own guide.

## Before you start

- A PC for the server with UEFI boot, one disk for the system, and the disks for your data. **Every disk you use is erased.** Back up
  what you want to keep first.
- A second computer on the same network with an SSH client, and a USB stick for the installer.
- A decision about how the data disks work, made **before** the install because `bulkType` is read during it (see
  [Storage and disks](storage-and-disks.md)):
  - `zfs` (the default): disks in mirrored pairs, every file stored twice, protected at once.
  - `snapraid`: single disks of any size merged into one folder, with a parity disk; new files are protected after the next nightly sync.
  The pool `fast` for the SSDs is always a ZFS mirror.

## Create an SSH key

The server accepts SSH keys only. Create one on your own computer, in a terminal on Linux or macOS:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_hobnix -C "hobnix"
```

On Windows, in PowerShell:

```powershell
ssh-keygen -t ed25519 -f $env:USERPROFILE\.ssh\id_hobnix -C "hobnix"
```

This writes two files. `id_hobnix` is the **private** key and never leaves your computer. `id_hobnix.pub` is the **public** key you give to
the server. Show it so you can copy the whole line later:

```bash
cat ~/.ssh/id_hobnix.pub
```

## Install the system

Choose one way. Both end with the same system: NixOS with the base configuration and one user, `adminuser`, who logs in by SSH key
only.

### Option A: the installer image

Not tested on hardware yet.

The installer image is the minimal NixOS installer plus a copy of this repository and the command `hs-install`. Download
`homeserver-installer-<version>.iso` (for example `homeserver-installer-v0.1.0.iso`) from the releases of the server repository, or build it yourself (the file name carries the output of `git describe`; the stick also holds it in `/etc/hs-installer-version`):

```bash
bash scripts/dev/build-iso.sh
```

Write the image to the USB stick (`dd`, Rufus in DD mode or balenaEtcher), boot the server from it in **UEFI mode**, and run:

```bash
sudo hs-install
```

It asks for the system disk, a server name, your public SSH key, a time zone and a preset (`minimal` is the plain one). **Only the system
disk is erased**, and you confirm by typing its name. Every question has an option for unattended runs (`--disk`, `--confirm-disk`,
`--hostname`, `--key-file`, `--timezone`, `--preset`). It installs the base system, writes `machine.toml` with a generated `hostId` and
applies the preset. Reboot, remove the stick, and continue with [First start](#first-start).

To bring back a dead server from its backup instead, see [Restore from a backup](#restore-from-a-backup).

### Option B: install by hand

Not tested on hardware yet.

Download the **NixOS minimal ISO** from nixos.org, write it to the USB stick, and boot from it in UEFI mode. On the server:

```bash
sudo -i
```

```bash
ls /sys/firmware/efi
```

If that lists nothing, the server did not boot in UEFI mode: fix the boot setting before you go on.

```bash
passwd nixos
```

This sets a temporary password so you can continue from your own computer. Note the server's address:

```bash
ip a
```

On your computer, connect and become root:

```bash
ssh -o PubkeyAuthentication=no nixos@<server-address>
```

```bash
sudo -i
```

Find the system disk. Check the name carefully, the data disks are probably connected too:

```bash
lsblk -o NAME,SIZE,MODEL
```

**The next commands erase the disk you name.** Replace `<disk>` with the system disk, for example `sda` or `nvme0n1` (for NVMe the partitions
are called `nvme0n1p1` and so on: add the `p`). The layout is 1 GB boot, 8 GB swap, a 1 GB partition called `vault` (left empty; `hs vault init` uses it later), the rest for the system:

```bash
parted /dev/<disk> -- mklabel gpt
```

```bash
parted /dev/<disk> -- mkpart root ext4 1GB -9GB
```

```bash
parted /dev/<disk> -- mkpart swap linux-swap -9GB -1GB
```

```bash
parted /dev/<disk> -- mkpart ESP fat32 1MB 1GB
```

```bash
parted /dev/<disk> -- set 3 esp on
```

```bash
parted /dev/<disk> -- mkpart vault -1GB 100%
```

The message "You may need to update /etc/fstab" after each command is harmless. Format and mount (partition 1 is the system, 2 the swap,
3 the boot partition):

```bash
mkfs.ext4 -L nixos /dev/<disk>1
```

```bash
mkswap -L swap /dev/<disk>2
```

```bash
mkfs.fat -F 32 -n boot /dev/<disk>3
```

```bash
mount /dev/disk/by-label/nixos /mnt
```

```bash
mkdir -p /mnt/boot
```

```bash
mount -o umask=077 /dev/disk/by-label/boot /mnt/boot
```

```bash
swapon /dev/<disk>2
```

Let NixOS describe the hardware (the generated `hardware-configuration.nix` stays as it is):

```bash
nixos-generate-config --root /mnt
```

On your own computer, get this repository and copy what the base system needs to the server:

```bash
git clone https://github.com/hobnix/server.git
```

```bash
scp -r -o PubkeyAuthentication=no server/configuration.nix server/install.nix server/machine.toml.example server/config server/capabilities server/scripts server/pkgs server/web nixos@<server-address>:/tmp/
```

Back on the server, put the files in place:

```bash
cp -r /tmp/configuration.nix /tmp/install.nix /tmp/config /tmp/capabilities /tmp/scripts /tmp/pkgs /tmp/web /mnt/etc/nixos/
```

```bash
cp /tmp/machine.toml.example /mnt/etc/nixos/machine.toml
```

Open `machine.toml` and set the first values. The base system needs two, a third for `snapraid`; leave the rest for later.

```bash
nano /mnt/etc/nixos/machine.toml
```

| Setting | What to put there |
| --- | --- |
| `hostId` | A random value: run `head -c4 /dev/urandom \| od -A none -t x4` and use the result, for example `"a1b2c3d4"`. It must never change later, ZFS remembers it |
| `sshKeys` | The whole line of `id_hobnix.pub`, in quotes, inside the brackets |
| `bulkType` | Only for `snapraid`: remove the `#` in front of `bulkType = "snapraid"` now, not later |

With `hostId` still `CHANGEME` the install stops with a hint. Install the base system:

```bash
NIXOS_CONFIG=/mnt/etc/nixos/install.nix nixos-install
```

The `NIXOS_CONFIG` part makes the installer use the base system (`install.nix`) instead of the full configuration. At the end it asks for
a root password. Then set the password of `adminuser`, which `sudo` asks for:

```bash
nixos-enter --root /mnt -c 'passwd adminuser'
```

```bash
reboot
```

Remove the stick when the server restarts.

## First start

On your computer, forget the installer's host key and connect (use the name from `~/.ssh/config` if you made one, or the address):

```bash
ssh-keygen -R <server-address>
```

```bash
ssh -i ~/.ssh/id_hobnix adminuser@<server-address>
```

The prompt must say `adminuser@`. If it says `nixos`, the installer stick is still running: remove it and reboot. Check the system:

```bash
systemctl --failed
```

Ideally this shows `0 loaded units listed`.

```bash
sudo whoami
```

It prints `root` after asking for the password of `adminuser`.

## Create the storage pools

`zpool status` reports no pools yet, which is right. The disk menu lists the free disks with size and model, asks which pool to create
(`fast` from SSDs, `bulk` from the data disks) and shows its plan, including the exact `zpool create` command, before you type the pool
name to confirm. The system disk and disks that are in use are never offered.

```bash
sudo bash /etc/nixos/scripts/manage-pool.sh
```

Run it once for `fast` and once for `bulk`. With `bulkType = "snapraid"` the data disks are added the same way and one of them is the
parity disk. The full story, including adding, replacing and removing disks later, is in [Storage and disks](storage-and-disks.md).

Check the result:

```bash
zpool status
```

`fast` must be `ONLINE` with a `mirror-0`. With `zfs`, `bulk` is `ONLINE` as well. With `snapraid`, `zpool status` shows only `fast`, and you
check `bulk` like this:

```bash
df -h /bulk
```

## Apply the full configuration

Now the base system becomes the server. Open `machine.toml` again and check the values that depend on your network, even when they
already hold an example:

```bash
sudo nano /etc/nixos/machine.toml
```

| Setting | What to put there | How to find it |
| --- | --- | --- |
| `nic` | The name of the network card | `ip link` (not `lo`) |
| `hostName` | The name of the server, also in the Windows network (`\\<hostName>`), at most 15 characters | you choose |
| `smbAllow` | The network your PCs are in, plus `127.0.0.1`, for example `"192.168.1.0/24 127.0.0.1"` | `ipconfig` or `ip a` on a PC |
| `vlans` | The network the containers join; exactly one entry has `default = true` | keep the example if unsure |

A VLAN is not required: the server starts even when your router does not know the one in the example, and containers then simply have no
network until you adjust it. Optional settings such as `gpu`, `language`, `adDomain` or `notifyUrl` are explained, one per paragraph, in
`machine.toml.example`; the Setup page below covers the common ones.

Apply it. This is the command you run after **every** change to the configuration:

```bash
sudo nixos-rebuild switch
```

The first run takes long. Your SSH connection may drop while the network is rebuilt as a bridge: reconnect (the address may change; look
it up in your router). From now on the short form exists:

```bash
hs rebuild
```

If a build goes wrong, the previous version is still bootable from the boot menu. Restart once and check:

```bash
sudo reboot
```

```bash
ip a
```

`br0` has an address; the VLAN bridge exists without one. Every `hs` command exists from now on.

## Pick a preset

A preset is a ready-made list of choices. `minimal` switches on nothing special: storage, Samba shares, Incus and the web interface. It
only fills settings that are not set yet and asks before it does, so it never overwrites a value. First look at what it would set:

```bash
hs preset show minimal
```

```bash
hs preset apply minimal
```

Add `--dry-run` to see only the plan. `hs preset list` shows the others; `example-server` is a fully equipped example, not a recommendation.

## Keep the configuration updatable

The installer makes `/etc/nixos` a git checkout of the public repository (`origin` is https://github.com/hobnix/server.git) at the exact
revision the stick was built from: a stick from release `v0.1.0` gives a checkout at `v0.1.0`, and `hs update`, the update channels and
the version shown work from the first boot. The files are not changed by this, so `git -C /etc/nixos status` is clean; your `machine.toml`
and `hardware-configuration.nix` are not in the repository and stay yours. The installer says in its plan ("Git checkout") what it will do.

Without a network during the install, or with a stick that does not name its published revision (built from unpublished work), the
installer still finishes, says "No git checkout was made" and leaves no `.git` in `/etc/nixos`. Once the server is online, make the checkout by
hand; your `machine.toml` and `hardware-configuration.nix` stay:

```bash
git clone https://github.com/hobnix/server.git ~/hobnix
```

```bash
sudo mv /etc/nixos /etc/nixos.bak
```

```bash
sudo mv ~/hobnix /etc/nixos
```

```bash
sudo cp /etc/nixos.bak/machine.toml /etc/nixos.bak/hardware-configuration.nix /etc/nixos/
```

The clone follows `develop` (the channel `edge`); `hs update` moves to the newest release tag on the channel `stable`.

Not tested on hardware yet: the installer's git step ran against a local repository in `tests/install-wizard.sh`, not on a stick or in a VM.

```bash
sudo cp /etc/nixos.bak/machine.toml /etc/nixos.bak/hardware-configuration.nix /etc/nixos/
```

```bash
sudo chown -R adminuser:users /etc/nixos
```

```bash
hs rebuild
```

When that succeeds, `/etc/nixos.bak` can go. To update later:

```bash
hs update
```

It pulls the latest configuration, rebuilds, and goes back by itself if new problems show up (`--no-rollback` turns that off). When new
options appeared in `machine.toml.example`, it syncs your file to the new layout and asks whether to rebuild now or stop (`--yes` never
asks).

## Sign in to the web interface

The web interface is the main way to operate the server. It is off until you switch it on. Never edit `machine.toml` with `sed`; use
`hs config set`:

```bash
sudo hs config set webUi true
```

```bash
hs rebuild
```

The first build takes a few minutes. Open `http://<server-address>:8480` in a browser (the port is `webPort`). The page speaks plain HTTP
and is meant for your home network and Tailscale: never give it a public route. Sign in as `adminuser` with the password you set during
the install; with a domain, members of Domain Admins can sign in too ([Users and shares](users-and-shares.md)). Not tested on hardware
yet.

### First setup with a one-time code (proposed)

Design: ADR 0022 (`docs/adr/0022-first-run-console-token.md`). The server part is built; the boot step that shows the code on the screen is not
yet, so a fresh install does not use this by itself. Not tested on hardware yet.

On a server whose setup is waiting, the sign-in page becomes **First setup**. The server's own screen (or serial console) shows a one-time
code; type it into the page and choose a password for `adminuser`. The code works once and for 60 minutes, five wrong tries make it
useless, and it is only ever printed on the console, never sent anywhere. You are then signed in.

Lost or expired code, or somebody else may have seen it: on the console run

```bash
sudo hs setup-code issue
```

The old code stops working at once. `hs setup-code status` says whether a setup is waiting. The page is plain HTTP, so do the setup on your
home network only.

## Work through the first-run checklist

The first-run command does four things in this order: it asks for the language of the messages (the rest of the run is already in that
language), asks for a notification address (`--notify none` removes it), fetches the **core packages** and lists what is still open, with
the command for each item. The core packages are the few apps the core refers to by name (`hs pkg install --core`); they come from the
package repositories, so the server needs internet. If that fails, the command says so and the rest still runs; try again later with
`hs pkg install --core`.

```bash
hs first-run
```

Over `ssh` without a terminal (`ssh <server> hs first-run`) `hs` stops with a message, because `sudo` would ask for a password and cannot
here. Log in with `ssh -t <server>` instead, or use `--language`, `--notify` and `--yes` as `root`. Not tested on hardware yet.

The same list is the **Setup** page of the web interface and the output of `hs sys setup list`. Each open item leads to the page where it is
done:

| Item | What it is for | Command |
| --- | --- | --- |
| Language | The language of the messages (`en` or `de`) | `hs config set language de` |
| Time zone | Without it times in messages are UTC | `hs config set timeZone Europe/Berlin` |
| Notifications | A push address, so you hear about a disk problem | `hs config set notifications true` |
| Storage pool | A pool, if you skipped it | `hs pool bulk add` |
| A first share | A folder you see from Windows | `hs share add <name>` |
| Backup disk | A disk for `hs backup` | `hs backup init <device>` |
| Vault (secrets) | Only with a vault: the vault must be open for backup and the like | `hs unlock` |
| Optional parts (capabilities) | Metrics, Tailscale and so on | `hs config set capabilities ...` |
| Wildcard DNS for the gateway proxy | Only with the gateway part on: names of the proxy must resolve | `hs gateway check` |
| Setup finished | Your own decision; the last row of the list | `hs config set setupDone true` |

When everything you want is done, press **Mark setup as finished** on the Setup page (or run `hs config set setupDone true`) and the
reminder on the summary page disappears. Everything can also happen later; the page only keeps the list. The machine-readable form for
scripts is `hs sys setup list`.

## Answers file for unattended installs

Not wired into hs-install yet; `hs-restore` reads the restore keys (see Restore from a backup). Not tested on hardware yet.

An answers file holds the answers to the questions of `hs-install` in one TOML file, so a later unattended install can run without them.
`hs-install` does not read the file yet; today only the check exists. A key you leave out is asked later, so a partial file is fine.
A complete unattended run needs `install.disk` and `install.confirm_disk`.

```toml
version = 1                      # required; the only version is 1

[install]
role = "homeserver"              # homeserver, edge or minimal
disk = "nvme0n1"                 # the system disk: it is erased
confirm_disk = "nvme0n1"         # must equal disk: an unattended run never erases on a guess
hostname = "nas"
timezone = "Europe/Vienna"
preset = "minimal"
nic = "enp3s0"
smb_allow = "192.168.1.0/24"
bios = false

[ssh]
key = "ssh-ed25519 AAAA... admin@example.com"   # a public key; or use key_file, not both

[secrets]
admin_password_file = "/run/keys/adminuser-pw"
```

| Key | Option of `hs-install` | Rule |
| --- | --- | --- |
| `version` | none | the integer `1` |
| `install.role` | `--role` | `homeserver`, `edge` or `minimal` |
| `install.disk` | `--disk` | a device name such as `nvme0n1` |
| `install.confirm_disk` | `--confirm-disk` | equal to `install.disk` |
| `install.hostname` | `--hostname` | a name of letters, digits and hyphens (up to 63) |
| `install.timezone` | `--timezone` | a name such as `Europe/Vienna`; looked up when the zone database is present |
| `install.preset` | `--preset` | a preset name |
| `install.nic` | `--nic` | an interface name |
| `install.smb_allow` | `--smb-allow` | an address or network such as `192.168.1.0/24` |
| `install.bios` | `--bios` | `true` or `false` |
| `ssh.key` | `--key` | a public SSH key; exactly one of `ssh.key` and `ssh.key_file` |
| `ssh.key_file` | `--key-file` | an absolute path to a public key file |
| `secrets.admin_password_file` | none | an absolute path to a regular file, mode 600 or stricter, not empty |
| `secrets.backup_passphrase_file` | `hs-restore --password-file` | same rules as `admin_password_file`; the backup password for [Restore from a backup](#restore-from-a-backup) |
| `restore.backup_device` | `hs-restore --backup-device` | a device name such as `sdb1` (the partition of the backup disk) |
| `restore.snapshot` | `hs-restore --snapshot` | `latest` or a snapshot id (8 to 64 hex digits) |

**Secrets are never written into the file.** A key that looks like a secret (password, passphrase, token, secret, key) with a value in
the file is an error; give the path of a file instead (`<name>_file`). The check looks at that file's mode and size only: it never reads
or prints the content. An unknown key anywhere is an error, so a typo never passes.

Check a file:

```bash
hs installer check-answers answers.toml
```

The command lists every problem with its key and exits 0 when there are no errors, 1 when there are errors and 2 when the file cannot
be read or is not valid TOML. It changes nothing.

## Restore from a backup

**UNVERIFIED: not tested on hardware.** Not tested on hardware yet. The reading of the backup, the plan and the files laid over the new
configuration are covered by `tests/install-restore.sh` with a fake `restic` and no disk. Partitioning, mounting the backup disk, the
real restic repository, `nixos-install` with the restored settings and the ISO itself have never run. Use the checklist below on a spare
machine first.

Use this when the system disk (or the whole host) is dead and you have the backup disk and the backup password. It automates
[Case A of the recovery guide](backup-and-recovery.md#case-a-the-system-disk-is-gone-the-data-disks-are-fine) up to the first boot.
Case B (data pools) and Case C (the backup disk is gone too) stay manual.

Boot the installer stick in UEFI mode and connect the backup disk (the one labelled `backup`). Then run:

```bash
sudo hs-install
```

With no options it asks **New install** or **Restore from backup**. The restore can also be started directly:

```bash
sudo hs-restore --dry-run
```

It mounts the backup disk **read-only**, asks for the backup password (no echo; or `--password-file <file>`), lists the host snapshots and
reads the settings of one (`latest` unless you pass `--snapshot`). It then shows the plan: the backup, the snapshot, the new system disk
(erased), the server name, role, time zone and SSH key taken from the restored `machine.toml`, and the files that come back.
The backup disk stays read-only the whole time, so restic runs with `--no-lock` and writes nothing to it. `--dry-run` also asks for the name of
the new system disk (the plan names it), then stops and changes nothing; with `--disk <name>` it does not ask. Without `--dry-run` you type the **name of the system disk** to continue; an unattended run needs
`--disk <name> --confirm-disk <same name>`. The data disks and the backup disk are never touched; the backup disk is refused as a target.

After the confirmation the normal installer runs with the restored settings: the same disk layout and `nixos-install` as a new install, and
it asks for the password of `adminuser`. What comes back from the host snapshot:

- `/etc/nixos/machine.toml` (and `machine.nix` if there is one), including the old `hostId`, so the ZFS pools can be imported
- the state folder `/var/lib/hs`, except `restic-password` and the `disks/` folder; links into the vault are not copied
- the SSH host keys, so your computers do not warn about a new server

`hardware-configuration.nix` is generated again for the new machine and never taken from the backup. These are **not** restored by the
installer: the backup password (put it into the new vault by hand), the vault itself, the pools, shares and containers. After the first
boot, continue with step 8 of Case A: `sudo hs rebuild`, `sudo hs vault init ...`, import the pools, `sudo hs unlock`, then
`sudo hs backup restore` for the shares (Case B).

Known gaps: a BIOS-only machine only works for the `edge` role, as in a new install; the `adminuser` password file of the answers file is not
read yet; a restored `machine.toml` that names hardware of the old machine (`nic`) needs a look after the first boot.

The answers file (format above) may carry `[restore]` and `secrets.backup_passphrase_file`: `hs-restore --answers answers.toml`.

### Checklist for the first real run

Not tested on hardware yet. Do it on a spare machine or a VM with a copy of a real backup disk, and write down every difference.

- [ ] The stick boots and `hs-install` offers New install and Restore from backup.
- [ ] `hs-restore --dry-run` finds the disk labelled `backup`, mounts it read-only (`findmnt` shows `ro`), accepts the password and lists the snapshots.
- [ ] A wrong password is refused with nothing changed.
- [ ] The plan names the right new disk, the right server name and the files above; it lists no `restic-password`.
- [ ] A different name than the disk's cancels; the backup disk is refused as a target.
- [ ] The restore runs to the end; the backup disk can be unmounted afterwards and was not written to.
- [ ] The new system boots, `ssh adminuser@<name>` works with the old key and without a host-key warning.
- [ ] `/etc/nixos/machine.toml` is the backed-up one; `hs rebuild` works; the pools import with the old `hostId`.

## Check that it worked

```bash
hs doctor
```

It reports problems from the health check, failed jobs, running jobs, pending parity work and locked storage. A healthy server reports
no problems.

## If something goes wrong

| Symptom | Cause | Fix |
| --- | --- | --- |
| `nixos-install` stops and mentions `networking.hostId` | `hostId` is still `CHANGEME` | Set it in `machine.toml` as described above |
| SSH says the host key changed | The key of the installer is still known | `ssh-keygen -R <server-address>` |
| The prompt says `nixos` after the reboot | The installer stick is still in the boot order | Remove the stick and reboot |
| `hs rebuild` stops at the start with a message about `machine.toml` | The check found a typo, a wrong type or `CHANGEME` | `hs config check` shows the line |
| The connection drops during the first rebuild | The network is rebuilt as a bridge | Reconnect; look up the new address in your router if it changed |
| Containers get no address | The VLAN does not reach your router or there is no DHCP | Adjust `vlans` in `machine.toml`, then `hs rebuild` |

## Next

- [Storage and disks](storage-and-disks.md): add, replace and check disks; shares and their permissions start here.
- [Users and shares](users-and-shares.md): who may open which share, and central users with a domain.
- [Containers and apps](containers-and-apps.md): create containers and install your first app.
- [Backup and recovery](backup-and-recovery.md): a disk for `hs backup`.
