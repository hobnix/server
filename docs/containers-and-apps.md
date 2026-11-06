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

A recipe that has a web page registers it as a service. While a reverse proxy is set (`reverseProxy`), it asks two more questions for
a service that may be public: "Make '<title>' public?" (default no) and, on yes, "Public name?" (default `<service>.<first entry of
proxyDomains>`). The answers are stored in `/var/lib/hs/recipe-<container>.conf`. Preset them with `RECIPE_PUBLIC_<NAME>=yes` and
`RECIPE_PUBLIC_NAME_<NAME>=media.example.org` (terminal), or `--set PUBLIC_<NAME>=yes` through `hs sys recipes plan|start`. Admin pages never
ask. A recipe only registers the wish: the route appears with `hs services apply`. Not tested on hardware yet.

Two rules hold for every recipe. An admin page (Incus, the reverse proxy, a Docker manager, the dashboard, the docs, Grafana) never gets a
public route. And nothing becomes public by itself: reaching a service from the internet is a separate, deliberate step with
`hs services`, which asks you to type the host name.

### Paths, login and headers of a public service
A service descriptor (`/var/lib/hs/services.d/<name>.toml`) can say more than "public". Not tested on hardware yet.
- `public_paths`: the only paths a public route may reach; the root of the host is a dead end.
- `blocked_paths`: paths that answer with an error page (Zoraxy, probably 502) or 403 (`traefik-public`), even when another service would serve them. Not tested on hardware yet (Zoraxy).
- `auth = "authentik"`: visitors log in first. The service named `authentik` must exist, else the plan shows `blocked` and the service gets no route. `auth_skip` lists paths that stay open (for example an API).
- `request_headers`, `response_headers`: `"Name: value"`, at most 8. They are not secrets: the file is readable by everyone.

```bash
hs services plan
```

The plan shows what the proxy will do. A proxy that cannot render a key (Zoraxy: headers and login) gets a `manual` row; set those by hand. With `reverseProxy = traefik-public` all keys are rendered (see the guide of the gateway proxy).

## Install packages from a repository

Recipes and extensions are both packages. They come from repositories, from signed release tags only. The project's two repositories
(`recipes` and `extensions`) are there from the start; you can add more.

In the web interface this is the **Marketplace** page: every package of every repository with its state (not installed, installed, update),
Install / Update / Remove, and a Repositories tab to add or remove a repository. Adding a repository asks for its public signing key and for
the repository name to be typed. Not tested on hardware yet. The commands below do the same.
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

`hs pkg repo list` and `hs pkg repo remove <name>` show and remove them. (The Marketplace only adds signed repositories; `--unsigned` is
for the command line, and a repository without signatures lets its owner run code on your server.) Extensions are switched on and off with `hs ext enable <name>`
and `hs ext disable <name>`, and `hs ext list` shows them.

## Write a package of your own

A package is a folder in a checkout of a package repository: `recipes/<name>/` in hobnix/recipes, `extensions/<name>/` in
hobnix/extensions, or the same layout in a repository of your own. `hs pkg new` writes one that passes the checks as it is. Run it inside
the checkout (or name it with `--dir <path>`):

```bash
hs pkg new my-app --template recipe --title "My app: what it does"
```

A recipe gets `package.toml`, `run.sh` (creates the container `my-app` and runs one step in it), `guide.md` and `i18n/de.tsv`. An
extension (`--template extension`) gets `package.toml`, `capability.toml` with one web read, `commands.tsv` with `hs ext <name> list` and
its data twin `hs sys ext <name> list`, `list.sh`, `NOTES.md`, `guide.md` and `i18n/de.tsv`. Both get an entry in `index.toml` with the
version `0.1.0`. The command never overwrites: a folder or an index entry with the same name stops it. A template for capabilities follows
with the service extensions.

Replace the example step or command with your own, keep the header lines of `run.sh` and `package.toml` in step, then check the package
(`<core>` is the checkout of the core, `/etc/nixos` on a server):

```bash
python3 -I <core>/scripts/pkg.py repo-check .
```

The repository's CONTRIBUTING.md has the rest: versions, branches, releases. Not tested on hardware yet.

## Apps in Docker (the Docker page)

When the capability `docker` is on, the locked container `docker` holds apps that are
Compose projects. Open them in the web interface under **Instances > Docker**:

- The list shows every app with its state, how many of its containers are running,
  published ports, images and whether it is managed by the web interface (`web`),
  by a recipe (`recipe`) or created by hand (`other`).
- Start, stop or restart an app from the actions column or from the drawer that
  opens when you click a row.
- **Pull** fetches newer images and recreates the containers; it runs as a
  background job because it can take a while.
- The **Logs** tab shows the Compose log of the selected app. Log output may hold
  secrets, so it is never cached by the web interface.
- On the **Instances** page the locked `docker` row shows how many apps it holds
  and can be expanded to open a specific app directly.

### Edit an app

Click **Open editor** in the Compose tab of an app, or **New app**, to open the editor on its
own page (`/instances/docker/app/<app>`, `/instances/docker/new`). The compose file is on the
left and the real text of the `.env` file on the right; on a phone they are stacked. The page
is for administrators only, so the env file is shown as it is and fully editable. Values of
keys whose name contains PASS, TOKEN, SECRET or KEY are hidden until you press **show** on
that line. The editor completes compose keys, marks YAML errors and unknown keys, a missing
`${VARIABLE}`, a port that another app already publishes and a name that is taken. **Test**
checks both files on the server without changing anything (`docker compose config`, the port
and container-name owners, bind sources that do not exist) and shows every problem at its line
in the panel; what has no line (for example an error of Docker without a line number) appears
in a banner above the panels. **Save** writes both files and leaves the running app as it is;
**Apply** writes them and recreates the app. Both run the Test first and show their plan (the
env names that are set, changed or removed, never their values) only when the Test found no
error; warnings do not stop them. If the app changed on disk meanwhile, a banner offers
**Reload** (your edits are lost). An env file over 64 KiB is not shown: edit it in a terminal, and
Apply keeps it as it is. The page shows "Changed, not saved yet." and the browser warns before you close or reload the tab with unsaved changes (moving to another page inside the interface does not warn yet). The env text is
read fresh each time, never kept in the web cache, a log or the browser storage. On **New app**,
**From docker run** takes a pasted `docker run ...` command and fills both panels (and the name,
if empty): `-p`, `-v`, `--restart`, `--network`, `--user`, `--cap-add`, `--device`, `--gpus` and
more become compose keys, every `-e` value goes to the `.env` panel. A flag that is not converted
stays as a `# not converted:` comment and a warning, and a named volume becomes a folder next to
the compose file. Check the result, then Test and Apply. Not tested on hardware yet.

#### Bind a share into an app

**Bind share** (top right of the editor) adds one volume line to the service your cursor is in.
Choose the share, an optional subfolder and the path inside the container; **Read only** adds
`:ro`. Docker sees a share at `/shares/<share>`. A share that Docker has already is inserted at
once. Otherwise the second step gives the share to Docker first: it shows the plan, and a local
share changes the user mapping of the container `docker`, which **restarts Docker and with it
every app in it** (the plan lists the running apps). The line is added when that job has ended.
Docker has one fixed user for all shares (the one it maps already, else `1000:1000`); the page
warns when the `PUID` and `PGID` in the app's `.env` are different. A share of another server
is read only. While you type, the editor warns about a `container_name` that another app
uses, a bind source that is not in a share (it lives on the container disk of Docker), and a
read-only mount without `:ro`. Inside a `volumes:` entry it completes the mount paths and then
the folders of the share, and `${` completes the names of the `.env` panel. Not tested on
hardware yet.

### Creating and editing apps

Apps marked `web` are created and edited on this page: **New app** opens the
editor with a small Compose template and an empty `.env`. The compose file is
sent as is; secrets go into the `.env` text of the editor. Each save is checked for an optimistic revision: if the
app changed meanwhile the editor keeps the text and offers **Reload**.

A failed update restores the previous compose and env files and starts them
again. **Rebuild** runs `docker compose up -d --build --pull always` and needs
any Dockerfile or build context in the folder of the app (`apps/stacks/<app>` in the share `apps`, or the older `/opt/apps/<app>`). **Delete** takes a
snapshot of `docker` first and stops and removes the containers after you type the
app name. **Delete** keeps the folder of the app: the app stays in the list with the state
`stopped` (a folder with a compose file and no container), can be edited, and **Start**
brings it up again with `docker compose up -d`. **Delete with data** also removes the folder of the app
(the config and the data).

### Files changed on disk, and containers hobnix did not start

Compose files and `.env` files can also be changed outside the page, for example over Samba in the share `apps`. Nothing starts by itself.
`hs sys docker apps` (the page reads it) compares the files in `apps/stacks/<app>` and `apps/recipes/<app>` with the running containers
(`docker compose config --hash '*'` against the label `com.docker.compose.config-hash`) and adds a last column `files`:

| Value | Meaning |
|---|---|
| `same` | the containers run what the files say |
| `changed` | the files changed after the containers were made: Apply (`recreate`, up -d) starts the new version |
| `new` | a folder with a compose file and no containers yet |
| `invalid` | `docker compose config` reports an error in the file, or the name exists in both `stacks/` and `recipes/`: fix the files first |
| `-` | old apps in `/opt/apps`, unmanaged containers, or the hash could not be read (never shown as changed) |

A container that was started by hand (`docker run`) has no Compose project. It is listed as an `unmanaged` row and can only be looked at.
The open editor reads `hs sys docker rev <app>` every 30 seconds to notice a change on disk and shows the banner "This app changed on
disk"; it never reloads by itself.

In the web interface the list shows the chips "Changed, not applied" and "New, not started" next to the name, with an Apply button that
opens the plan of `recreate` (`docker compose up -d` from the folder: it never pulls, builds or removes a volume). For `invalid` files Apply is disabled and says why. "Unmanaged" rows
have no Start, Stop or Edit. The editor also warns when a `user:` of a service differs from the user Docker maps for all shares.

Giving a person access to a share that holds a `.env` file (the share `apps` always) shows a warning in the plan: those files can
contain passwords and keys of apps.

Not tested on hardware yet. The flag `--hash` of `docker compose config` is unverified on Compose 2.26.1; without it every app shows `-`.

### Private registries (Instances > Docker > Registries)

An image from a private registry (for example `ghcr.io/you/app`) needs a login. Add it
on **Registries** (or `hs docker registry add ghcr.io --user <user>`; the token is asked
for, never put in a command line). For GitHub use a classic token with `read:packages`
only. The token is tested with a login, then kept in the vault
(`/var/lib/hs/docker-registry-<host>`); the list in `/var/lib/hs/docker-registries.tsv`
holds only the host and the user.

A pull, a rebuild, a save of an app and the pull of a recipe app give the token to the
container for that one command, in a throwaway Docker config on tmpfs that is deleted
afterwards. Nothing is left in `/root/.docker` and nothing in the backups of the container.
While the vault is closed these actions are refused with the fix `hs vault open` (a
terminal: the web interface cannot open the vault); start, stop and restart never need the
token. `hs docker registry list` shows each registry as `ok`, `locked` (vault closed) or
`missing`. Remove a login with `hs docker registry remove <host>` after typing the host.

Not tested on hardware yet.

### Move an app from Arcane by hand

Copy its compose file, put the secrets into the env fields, save it here, then
stop it in Arcane. Remove Arcane later with `hs ct arcane delete`.

Not tested on hardware yet.

### Move the apps of an older server into the share apps

Apps made before the share `apps` existed live in `/opt/apps` inside Docker. Move them once:

```bash
hs docker move-apps --dry-run
hs docker move-apps
```

The plan lists every app with its new folder (`apps/stacks/<name>` when it has the `.hs-webui` marker, else `apps/recipes/<name>`) and
its size, and refuses when a target folder exists already, when the SSD pool is too full for a copy or when the share `apps` is not
mounted in Docker (`hs docker enable` fixes that). It takes a snapshot of `docker`, asks you to type `docker` and offers to run in the
background. Each app is stopped for a short time, copied, its compose file rewritten (the paths that start with `/opt/apps/<name>`;
the old file stays as `docker-compose.yml.prev`) and started from the share. Only then the old folder is renamed to
`<name>.moved-<date>`. An app that does not start is stopped again and started from `/opt/apps`; the other apps go on, and the
failed copy stays next to the target as `<name>.failed-<date>`.

Look at your apps. When all is well, remove the old folders (you type `docker` again):

```bash
hs docker move-apps --finish
```

`hs update` never moves apps by itself.

Not tested on hardware yet.

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
