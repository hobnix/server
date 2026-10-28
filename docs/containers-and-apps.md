# Containers and apps

How to create containers and VMs, give them a fixed address, limits and storage, keep them safe with snapshots, and install ready-made apps
with recipes and packages.

## Before you start

- A running server with the pool `fast` and the default network: [Install](install.md).
- For storage from the data disks, a share: [Storage and disks](storage-and-disks.md) and [Users and shares](users-and-shares.md).

## Plan an instance

Decide three things before you type anything.

- **Name:** short, lower case, letters, digits and dashes (`photos`). It appears in Incus, in your router and in every command.
- **Address:** pick the fixed address from a range outside your router's DHCP range, so it never clashes with a device that got an
  address automatically. Many people keep one range per purpose (access, apps, tools) so that they can find things later.
- **Storage:** where does the data live?

| Place | Put there |
| --- | --- |
| Inside the instance (pool `fast`) | The app, its database, everything small and fast. Snapshots of the instance include it |
| A volume on `fast` | Data that must be fast and outlive the instance |
| `/bulk/shares/<name>` | Large files **you** edit from a computer: media, downloads, documents |
| `/bulk/sensitive/<name>` | Large files **the instance** manages: backups, archives. Read-only from a computer |

## Create an instance

The guided dialogue asks for what is missing:

```bash
hs ct add
```

Or give everything as options. An empty Debian container:

```bash
hs ct add --kind empty --name <name> --ram 1024
```

A container for Docker (this switches on the three security settings Docker needs inside a container; set them only where Docker really
runs):

```bash
hs ct add --kind docker --name <name> --ram 2048
```

A virtual machine, for software that needs more than a container may do. It gets 2048 MB of memory, 2 cores and 20 GB of disk unless you
say otherwise, because a VM reserves them:

```bash
hs ct add --kind vm --name <name>
```

More options: `--cpu <n>`, `--disk <GB>`, `--ip <address>` and `--profile <vlan>` to join a network other than the default (the one with
`default = true` in `machine.toml`). Every new instance starts again after a reboot of the server and has its MAC address pinned.
Check it:

```bash
hs ct list
```

The instance must be running with an address from the container network. `hs status` shows the same list. To test the connection from
inside:

```bash
hs ct <name> exec ping -c 2 1.1.1.1
```

## Give it a fixed address

The address comes from your router, which hands it out by MAC address. That holds only when the MAC never changes. `hs ct add` pins it;
for an instance made another way:

```bash
hs mac <name>
```

If you have a UniFi router, store its address and an API key once, and `hs` reserves addresses for you:

```bash
hs net setup
```

```bash
hs ct <name> ip <address>
```

With another router, reserve the address in the router's settings for the MAC that `hs ct list` shows. Restart the instance and check
that the address is the one you chose and that the MAC is pinned:

```bash
hs ct <name> restart
```

```bash
hs status
```

## Change memory, CPU and disk

The memory limit is a ceiling, not reserved memory: the instance uses only what it needs. A limit keeps one app from taking the whole
server. Change several values at once:

```bash
hs ct <name> set ram=2048 cpu=2
```

The disk can only grow:

```bash
hs ct <name> set disk=50
```

`hs ct <name> set` also takes `autostart=yes|no` and `docker=yes|no` (restart the instance after changing `docker`). The guided form is
`hs ct <name> edit`; it shows the current values first.

## Add storage

Mount a folder of the data disks into the instance. The kind is `fast` (a volume), `shares` or `sensitive`:

```bash
hs ct <name> storage add shares <share> /srv/<share>
```

Add `--readonly` for a read-only mount. On a `zfs` server the user ids of the instance are shifted onto the disk: user 1000 inside is the
owner of the share, and root inside is root. To let one user of the instance write as the owner instead, map it 1:1; only one user per
instance can be mapped, and root cannot:

```bash
hs ct <name> storage add shares <share> /srv/<share> --as 1000:100
```

On a server with `bulkType = "snapraid"` a share is always mounted this way (user 1000, group 100 when you give nothing). What is
mounted is not part of the instance's snapshots. List and remove mounts:

```bash
hs ct <name> storage list
```

```bash
hs ct <name> storage remove <device>
```

Creating the shares themselves, and who may open them, is in [Storage and disks](storage-and-disks.md) and
[Users and shares](users-and-shares.md).

## Snapshots and updates

A snapshot is a frozen state to come back to. It takes a second and costs nothing at first. Every instance also gets one every night,
kept for seven days. Take one before every change:

```bash
hs ct <name> snapshot before-update
```

```bash
hs ct <name> snapshots
```

**Going back loses everything changed since, and it only works to the newest snapshot:** to go back further, the newer snapshots are
deleted first (add `--dry-run` to see which). Mounted storage is not rolled back.

```bash
hs ct <name> restore before-update
```

Update the software inside an instance (a snapshot is taken first):

```bash
hs ct <name> update
```

Update every running container in one go, with a report and the way back:

```bash
hs ct update-all --dry-run
```

Drop `--dry-run` to do it. For a shell, one command, the journal or the console:

```bash
hs ct <name> shell
```

`hs ct <name> exec <command>`, `hs ct <name> logs [lines]` and `hs ct <name> console` (leave with `Ctrl+a q`) work the same way. To delete
an instance with its snapshots (the mounted folders stay) you type its name to confirm:

```bash
hs ct <name> remove
```

## Install an app with a recipe

A recipe is a package that sets up one app in its own container or VM and connects it to the server. List them:

```bash
hs recipe --list
```

Run one. A recipe asks a few questions the first time (network, memory, port, address): Enter keeps the value in brackets. Without a
terminal the defaults are used.

```bash
hs recipe <name>
```

The answers are kept per container, so a second run asks nothing and only repairs or updates what differs. Useful variations follow.

To see what a recipe would do, without changing anything:

```bash
hs recipe <name> --dry-run
```

To see what an update would change, piece by piece (`current` or `would update`; only recipes that name their pieces can say, the others
tell you so):

```bash
hs recipe <name> --check
```

To be asked the questions again:

```bash
hs recipe <name> --ask
```

To give answers up front, for example the port, memory and address:

```bash
sudo RECIPE_PORT=8080 RECIPE_RAM=2048 RECIPE_IP=192.168.1.25 hs recipe <name>
```

To run a recipe a second time under a container name of its own, for a second instance of the same app:

```bash
hs recipe <name> --name <container>
```

A recipe ends with a short text that holds only the clicks that cannot wait (creating the first account, for example). What the app does
and how to use it is in its own guide: open the **Docs** page of the web interface and look in the group **Apps**. A guide is shown
there while its package is installed.

The web interface runs recipes too: **Instances > Apps** shows the list with a form for the questions. A recipe that needs a person at a
terminal (one that asks you to type a password into a setup) says so and runs only from the command line.

Two rules hold for every recipe. An admin page (Incus, the reverse proxy, a Docker manager, the dashboard, the docs, Grafana) never gets a
public route. And nothing becomes public by itself: reaching a service from the internet is a separate, deliberate step with
`hs services`, which asks you to type the host name.

## Install packages from a repository

Recipes and extensions are both packages. Those that ship with the server are listed here; others come from repositories, from signed
release tags only.

```bash
hs pkg list
```

The list shows each package with its version and the version last applied here. Personal recipes (built around one setup) are hidden
unless you add `--all`. Find out whether something is newer:

```bash
hs pkg updates
```

Look at what the repositories offer, after refreshing them:

```bash
hs pkg fetch
```

```bash
hs pkg available
```

```bash
hs pkg install <name>
```

An installed package is a read-only copy. A package runs as root on your server, so an update shows you what changed first and asks:

```bash
hs pkg update <name>
```

A package update does not touch a running app. For a recipe it replaces the package files; run `hs recipe <name>` to apply them.
`hs pkg remove <name>` forgets the package files only, never a container.

Add a repository of your own (a typed repository name confirms it; releases must be signed with a key you trust):

```bash
hs pkg repo add <name> <url> --key <allowed-signers-file>
```

`hs pkg repo list` and `hs pkg repo remove <name>` show and remove them. Extensions are switched on and off with `hs ext enable <name>`
and `hs ext disable <name>`, and `hs ext list` shows them.

## Check that it worked

```bash
hs ct list
```

Every instance you made is `RUNNING` with the address you expect and a pinned MAC. For an app, open its address in a browser (the recipe
printed it) and see `hs doctor` for anything else that needs attention.

## If something goes wrong

| Symptom | Cause | Fix |
| --- | --- | --- |
| The instance gets no address | The network does not reach your router, or there is no DHCP | Check `vlans` in `machine.toml` and your router; then `hs rebuild` |
| It has an address but no internet | Traffic is blocked at the router, or the host firewall drops bridged traffic | Check the router's rules for that network |
| The address changed after a reboot | The MAC was not pinned, or the reservation sits on an old router entry | `hs mac <name>`, then reserve the address for that MAC |
| Docker does not start inside a container | The Docker security settings are missing | `hs ct <name> set docker=yes`, then `hs ct <name> restart` |
| An install stops with `killed` | Not enough memory | `hs ct <name> set ram=4096` and run it again |
| No space left in the instance | The disk is too small | `hs ct <name> set disk=<GB>`; keep large data on `bulk` |
| A file in a share cannot be changed from Windows | The instance wrote it as root | Mount the share with `--as` for the user the app runs as |
| `hs recipe <name> --check` says the recipe does not report its pieces | That recipe cannot say yet | Use `--dry-run` instead |

## Next

- The guide of the app you installed, on the **Docs** page in the group **Apps**.
- [Storage and disks](storage-and-disks.md): shares, pools and disk health.
- [Backup and recovery](backup-and-recovery.md): back up the instances too.
