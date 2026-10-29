# Web interface

A page in your browser to look at the server and make the common changes: disks and pools, shares, containers, users, backup, tasks and
settings. It does not replace `hs`, it sits on top of it: every change runs the same command you would type, and shows you first what it
would do.

## Before you start

- A running server ([Install](install.md)) with its storage unlocked (`hs unlock`).
- An account that may sign in: a member of **Domain Admins** (sign in with the plain user name, without the domain prefix) or the local
  `adminuser`. Other domain users cannot sign in, even with the right password. While storage is locked only `adminuser` can.
- Not tested on hardware yet: the flows were checked against stand-ins. Try harmless things first (run a task, change a share's rights, run a
  short disk self-test); reboot, delete and add-disk last.

## Switch it on

```bash
sudo hs config set webUi true
```

```bash
sudo hs rebuild
```

The first build downloads the page's libraries and takes a few minutes. The page then listens on `http://<server address>:8480`. Other
options, all set the same way with `hs config set <key> <value>` (never edit `machine.toml` with `sed`):

| Option | Default | Meaning | Needs `hs rebuild` |
| --- | --- | --- | --- |
| `webPort` | `8480` | port of the page, the direct address `http://<server address>:8480`. With the gateway proxy on (`capabilities = ["gateway"]`) port 80 belongs to Traefik, so `webPort` must not be 80; the page is then also at `http://<siteName>.<realm>/` | yes |
| `webTailscale` | `false` | HTTPS through Tailscale, see below | yes |
| `webLan` | `true` | keep the plain-HTTP address on the home network | yes |
| `webDocs` | `true` | the Docs page | yes |
| `webAccent` | `#9184d9` | main colour as `#rrggbb` | no |
| `webTerminal` | `false` | the browser terminal, see below | no |

## Use HTTPS over Tailscale

Without it the page is plain HTTP on your home network: passwords cross it unencrypted. With `webTailscale` the page listens on the server
only, and Tailscale turns it into HTTPS with a real certificate for members of your tailnet.

```bash
sudo hs config set webTailscale true
```

Then do two things once by hand: join the tailnet on the server and switch on **HTTPS certificates** (and MagicDNS) in the Tailscale
admin console.

```bash
sudo tailscale up
```

```bash
sudo hs rebuild
```

The address is `https://<server>.<your-tailnet>.ts.net`. Check it with `tailscale serve status` and `systemctl status hs-web hs-web-tailscale`.
To remove the plain-HTTP address on the home network, set `webLan` to `false` and rebuild. The page is **never** reachable from the internet
and never gets a reverse-proxy route: it is an administration interface.

## Sign in

Choose **Domain account** or **Local admin** on the sign-in page. With storage locked, the domain controller is down too: sign in as
`adminuser`, and the summary shows a box to unlock the storage (type the passphrase; after five wrong tries the page makes you wait).
Sessions end after 8 hours without activity, after 12 hours at most, and when the page restarts.

## Find your way around

The tree on the left, the task panel at the bottom (Tasks, Jobs, Logs, disk events, reports) and search on top (press `/`). The top bar
shows the server name, a node switcher, how old the data on screen is (with a refresh button), the storage state, the theme toggle and the
buttons **Update**, **Reboot** and **Shut down**.

| Page | What you do there |
| --- | --- |
| Summary | CPU, memory, disks per pool, UPS, important states; **Run health check** |
| Storage | pools `bulk` and `fast`, disks (SMART, self-tests, unassigned and foreign disks), shares, encryption, vault (values are never shown) |
| Instances | containers and VMs (start, stop, snapshot, update, settings, fixed address, mounts, create, delete), **Apps** (the recipes), **Services** (what the reverse proxy publishes) |
| Marketplace | the packages of the repositories (apps and extensions): install, update, remove; the repositories themselves, signed only |
| Network | addresses of the instances, router networks, DNS names, open ports |
| Identity | users, groups, certificates (only with a domain) |
| Monitoring | hardware (temperatures, fans), diagnostics |
| Protection | backup (back up now, verify, restore test, browse, restore files), expiry dates |
| Operations | health (each problem with the command that helps, and a button where a safe fix exists), notifications |
| Docs | the guides and the command reference, rendered in the page, with search |
| Nodes, Setup, Settings | other servers, the first-run checklist, the common `machine.toml` settings |

Installed extensions add pages under **Extensions**. The first start shows the **Setup** checklist until you mark it done.

The numbers on a page are read from a cache that is kept fresh while someone is signed in; the top bar says how old they are. The refresh
button reads them again at once.

## The dashboard

A page with one tile for each app of the server, on a big screen or a phone. Not tested on hardware yet.

```bash
sudo hs config set dashboard web
```

Not tested on hardware yet. The page is **Services** with the dashboard card when you are signed in. For a wall screen open
`http://<server address>:8480/dashboard` (use your `webPort`): full screen, no sign-in. That address answers only while
`sudo hs config set dashboardOpen true` is set, and only to computers in your home network and over Tailscale. Everyone there sees the
titles, descriptions, links and state of every tile. Not tested on hardware yet.

A container gets a tile when its service says so:

```bash
sudo hs services declare jellyfin --container jellyfin --port 8096 --want dashboard
```

Not tested on hardware yet. The recipes do this for you. For a container set up before its recipe did it, `sudo hs services declare-known`
describes it. Not tested on hardware yet.

If you used the Homepage app before: `sudo hs update` sets `dashboard` to `web` and leaves the old container alone. Remove it when you like
(`sudo hs ct homepage remove` asks you to type the name). Not tested on hardware yet.

## Make a change

Every change shows a **plan** first: what would happen, in which order, and the exact command. Nothing runs before you press **Start**.
Red plans (not reversible: erase a disk, delete a user, reboot) make you type a word, usually the name of the thing that changes. A plan can
also say "needs one more value" or "refused", with the reason. Long work runs as a task in the background and goes on when you close the
page; open **Tasks** to see its log. Passwords and passphrases never go into a command or a log, they are passed on standard input.

A create dialog shows its form and a placeholder at once and asks for the plan when it opens, then 300 ms after your last edit. An older
question is cancelled, and the server stops the check it was running. **Start** is enabled only for the plan of what the form shows now.
The server answers the same plan again for 5 seconds without running it again; any change you start clears that. Not tested on hardware yet.

To see how long plans and changes take, read the log. One line per plan and start, with no values and no passwords:

```bash
journalctl -u hs-web | grep 'web timing'
```

A line reads `web timing: plan pool bulk add --disks * 1834 ms run rc=0 status=ok`: the command with values as `*`, the time, then
`run` (it ran), `cached` (answered again), `timeout` (took over 60 s) or `gone` (you changed the form, the check was stopped), the exit code and
the result. Not tested on hardware yet.

## Use a terminal in the browser

Off by default. It adds a **Terminal** button next to Update (a shell as `adminuser`, like an SSH login; `sudo` asks for that user's
password) and on a container's page (a shell inside the container, like `incus exec <name> -- bash`).

```bash
sudo hs config set webTerminal true
```

The server shell also works while storage is locked, so you can run `hs unlock` there. The connection ends after 30 minutes without typing,
after 8 hours, on sign-out and when you close the window; at most 4 at a time. The shell itself keeps running in tmux, so a long job survives:
the next terminal reattaches to the same shell, and only `exit` or a reboot ends it. Change the limits:

```bash
sudo hs config set webTerminalIdleMinutes 240
```

```bash
sudo hs config set webTerminalMaxHours 48
```

The journal records only "opened" and "closed" with user and target, never the input.

## Change the colour

```bash
sudo hs config set webAccent '#4fb286'
```

The logo, buttons and highlights follow the accent; light colours read better on the dark theme. The theme toggle in the top bar switches
dark and light (it follows your system by default). No rebuild is needed.

## Read the guides in the page

The **Docs** page shows these guides and the generated command reference without fetching anything. `hs docs build` writes them (`hs update`
runs it); if they are not built yet the page says so. Without the web interface, `hs help` lists the commands and the guides are the files in
the `docs/` folder of the repository.

## What only works in the terminal

Some things stay in the terminal on purpose: setting up the backup disk (`hs backup init`, it erases a disk) and the off-site copy, restoring
the whole system, the recipe `domain`, creating the vault (`hs vault init`), offering a share to another server (`hs remote offer`, it shows a
password once), the sign-in to the reverse proxy, anything that asks questions, and the `machine.toml` keys the Settings page does not offer
(for example `sshKeys`, `hostName`, addresses).

## Live state

With `liveState = "redis"` in `machine.toml` (default `off`) the Summary page updates within about a second after a change, without polling.
The server keeps the status in a Redis service on a local socket (no network port) and tells the browser through `/api/events` when it changes.
If the service is down, the status read answers "state service down" and the page retries every 15 seconds; "Live updates paused" shows when an already open live stream is lost. `sudo hs sys live status` shows the state.
With `liveState = "off"` nothing changes. Not tested on hardware yet.

## Check that it worked

- Open the page and sign in; the summary shows your server and its disks.
- `systemctl status hs-web` says `active (running)`.
- `curl -s http://127.0.0.1:8480/api/hello` answers on the server itself (use your `webPort`; with `webTailscale` the page listens on the
  server only).

## If something goes wrong

| Symptom | Cause | Fix |
| --- | --- | --- |
| "Domain sign-in is not available" | storage is locked or the controller VM is not running | sign in as `adminuser`, unlock, start `dc1` |
| A page stays empty or says "could not be read" | the command behind it does not answer, for example storage is locked | run it in a terminal: `sudo hs sys <area> <command>` |
| A list looks old right after a change | the page re-reads every few seconds | wait, or press the refresh button |
| The build stops with `hash mismatch ... got: sha256-...` | the frontend's dependencies changed | put the shown value into `npmDepsHash` in `pkgs/hs-web.nix`, rebuild |
| The page is not reachable from another PC | wrong port or `webLan` is `false` | check `webPort`, use the Tailscale address |

`journalctl -u hs-web -e` shows what the page logs (sign-ins and changes, never passwords).

## Next

- [Users and shares](users-and-shares.md) and [Storage and disks](storage-and-disks.md): the tasks behind the pages.
- [Operations](operations.md): health, notifications and updates.
