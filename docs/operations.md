# Operations

Keep the server healthy without watching it: see its state, get a message on your phone when something is wrong, check disks and
memory, track expiry dates, update with a safety net, survive a power cut, and find out when the whole server is gone.

## Before you start

- A running server ([Install](install.md)).
- A phone with the ntfy app if you want push messages (free, from the app store).
- `hs` commands that change something use `sudo`; the ones that only look do not need it.

## See the state of the server

Three commands, from short to detailed:

```bash
hs status
```

```bash
hs health
```

```bash
hs doctor
```

`hs status` is the overview. `hs health` lists the problems of the health check, each with the command that helps, or says
`No problems found.` `hs doctor` answers "is everything fine?": health problems, failed and running jobs, pending parity work, locked
storage. The same three status lines appear when you sign in over SSH (`hs motd`).

Two more checks that change nothing:

- `hs smoke` runs a quick test that the commands work on this server (needed programs installed, read-only commands run).
- `hs cleanup` finds leftovers (old containers and services, stale mounts, old generations) and prints the command that removes each.

`hs ports` lists the open ports of the server and of each container and warns when an administration page is behind the reverse proxy.
The health check itself runs every 15 minutes by a timer; it is the only thing that raises an alarm.

## Get push messages

The server sends a message when its list of problems **changes**, not every 15 minutes. The route is ntfy: a service that passes messages
to the app on your phone. The last part of the address is the topic; anyone who knows it can read along, so make it long and random.

1. Install the ntfy app and subscribe to a topic, for example `https://ntfy.sh/<long-random-topic>`.
2. Give the address to the server (no rebuild needed):

```bash
sudo hs config set notifyUrl https://ntfy.sh/<long-random-topic>
```

3. Send a test:

```bash
hs health test
```

The phone shows a message titled `<server>: test`. Without `notifyUrl`, all messages only go to the journal (`journalctl -t hs-notify`),
where they are in any case. Do not point `notifyUrl` at a service on this server: while storage is locked everything is down and you would
not hear about it. Send your own message from a script with `hs notify "Title" "Text"`.

What triggers a message:

| Problem | Threshold |
| --- | --- |
| A ZFS pool is not healthy | state other than `ONLINE`, or errors in the pool |
| A SnapRAID data or parity disk is missing or not mounted | state `MISSING` / `UNMOUNTED`; no parity disk at all |
| A disk fails its SMART self-check | health `FAIL` |
| A disk has sectors it cannot read | pending sectors above 0 |
| A disk is too hot | 55 °C or more |
| A pool, `/bulk` or the system disk is nearly full | 90 % or more |
| A scheduled job or an important service failed | each job that has `onFailure` sends its own message at once |
| The domain controller's certificate runs out | 30 days before (only with a domain) |
| A share is open to everyone | only with a domain |
| An expiry date comes close | see [Track expiry dates](#track-expiry-dates) |
| The last scrub is older than 21 days or found errors | scrub checks |

A persistent problem is repeated once a day; when everything is fixed a message titled `all clear` arrives.

**Several channels, quiet hours.** Notifications go through channels (`notifyUrl` is the channel `main`). Add a second one, with its own minimum
priority and its own quiet-hours rule:

```bash
hs notify channel providers
```

```bash
hs notify channel list
```

`hs notify channel add <name> --provider ntfy --secret url [--min-priority P] [--quiet respect|ignore]` creates one, `hs notify channel test
<name>` sends a test to it, `hs notify channel set` changes it.

**A problem you know about.** Silence one problem until it clears, or take the silence back:

```bash
hs health ack
```

`sudo hs health ack <id>` silences the problem with that id, `sudo hs health unack <id>` undoes it. After an automatic pause of the sync, scrub and
cache mover (the optional "notify and pause" reaction), `hs health resume` lifts the pause.

## Check the disks

```bash
hs disk list
```

The list shows every disk with a health verdict. For one disk (use the name `hs disk list` shows; `sda` is an example):

```bash
hs disk sda health
```

It prints the verdict, the age, bad sectors and errors. Start a self-test inside the disk (the disk stays usable) and read its outcome later:

```bash
hs disk sda test short
```

```bash
hs disk sda results
```

`hs disk selftest short` tests every disk. A `long` test takes hours. Disks that spin down to save power are shown by `hs disk spindown`
(`diskSpindownMinutes` in `machine.toml` sets the timer).

**Scrub.** A scrub reads everything and finds silent damage. ZFS pools scrub weekly by themselves; for SnapRAID run one by hand when the
health check says the last one is older than 21 days:

```bash
sudo hs pool bulk sync --scrub
```

Pool and disk changes (add, replace, remove) are in [Storage and disks](storage-and-disks.md).

**Fans.** Blow the dust out of the case: run the fans at full speed for 8 seconds (3 to 30) and then back as they were:

```bash
sudo hs fans clean
```

## Test the memory

The server has no ECC memory, so a RAM error shows up as crashes, random checksum errors or damaged files. Test after an unexplained crash,
after new RAM, and once when you set the server up (at least one full pass, overnight is fine). Memtest86+ is in the boot menu. The menu is
hidden by default, so ask for it once:

```bash
sudo hs reboot --menu
```

Choose **Memtest86** (it needs a monitor and keyboard on the machine; the server is off the network while it runs). Red lines are errors:
test the modules one by one and replace the bad one. Afterwards reboot normally and unlock the storage with `hs unlock`.

## Track expiry dates

Some things run out on a date and nobody remembers: a certificate, an API token, a domain. List them and the health check warns **30 days**
before, **7 days** before (urgent) and after the date, then once a day.

```bash
sudo hs expiry add cloudflare-token 2027-03-01 "create a new tunnel token in the dashboard, then run hs recipe cloudflared"
```

```bash
hs expiry list
```

```bash
sudo hs expiry remove cloudflare-token
```

Adding an existing name sets a new date, which is how you renew. Good candidates:

| What | When | How to renew |
| --- | --- | --- |
| Certificate of the domain controller | its expiry date | the health check also checks it itself; the entry is a second safety net |
| API token of a tunnel or DNS service | the date you chose | create a new token, run the recipe again |
| Domain name | renewal date at the registrar | renew; check auto-renew |
| Keys of the off-site backup (S3/B2) | key expiry | create a new key, update the backup settings |
| Tailscale and other service keys | per service | renew in that service |

## Know that the configuration is in sync

The health check compares `/etc/nixos` with Git (locally, no network):

| Message | Meaning | Fix |
| --- | --- | --- |
| `config:dirty` | uncommitted changes in `/etc/nixos`: the system does not run from Git and `hs update` may stop | commit or undo them |
| `config:diverged` | local and upstream commits at the same time; `hs update` only fast-forwards | merge or rebase by hand |
| `config:ahead` | local commits that are not pushed | push them |
| `config:unbuilt` | the last rebuild used another revision than the checked-out one | `hs rebuild` |

New commits upstream ("behind") are not a problem. A new server that has not been rebuilt yet reports nothing.

## Update with a safety net

See what an update would bring, then run it:

```bash
hs update --preview
```

```bash
sudo hs update
```

`hs update` pulls the latest configuration into `/etc/nixos` and rebuilds. If options are new in `machine.toml.example` it puts them into your
`machine.toml` (commented out, in their place), lists them and asks whether to rebuild now or stop to set them first. If nothing is new it says
so and skips the rebuild; `--force` rebuilds anyway (so does `hs rebuild`, which always builds).

**The safety net:** if the switch fails half way, or `sshd` or Incus are not running afterwards, the previous generation is switched back and a
message says so. A terminal is asked first; without a terminal (timer, job) or with `--yes` it happens at once; `--no-rollback` switches it
off. A failed build changes nothing and needs no rollback. For five minutes after the switch the health check is watched too: a problem that
was not there before also rolls back.

| Option | Effect |
| --- | --- |
| `--yes` | rebuild without asking (also when new options appeared) |
| `--stop-on-new` | stop without asking when new options appeared; `hs rebuild` follows once you set them |
| `--no-rollback` | leave a broken system as it is |
| `--force` | rebuild even if nothing is new |
| `--verbose` | show the details |

To go back by hand to the previous generation:

```bash
sudo nixos-rebuild switch --rollback
```

`hs update` and `hs rebuild` refuse while encrypted storage is locked.

## Survive a power cut: UPS

A UPS bridges short outages and shuts the server down **cleanly** before the battery runs out. Without one, ZFS, SnapRAID and the databases
in your containers risk damage at every power cut. The server reads the UPS through NUT; everything is off while `ups` is missing in
`machine.toml`.

What to buy: a line-interactive UPS **with a USB data port** (APC, Eaton, CyberPower; almost always the driver `usbhid-ups`). One without a
data port cannot shut the server down. Plan about twice the server's wattage (`hs ups` shows the load later); 5 to 10 minutes of runtime
is enough for a clean shutdown. Connect only the server (and router or switch), no heater, printer or monitor, and plug in the USB cable.

Find the driver with the UPS switched on:

```bash
nix-shell -p nut --run "sudo nut-scanner -U"
```

Put it into `machine.toml` (all keys are optional; `ups = "usbhid-ups"` is enough when only the driver is needed):

```toml
ups = { driver = "usbhid-ups", name = "ups", shutdownMinutes = 5 }
```

| Key | Meaning | Default |
| --- | --- | --- |
| `driver` | NUT driver | `usbhid-ups` |
| `name` | name of the UPS | `ups` |
| `port` | connection | `auto` |
| `shutdownMinutes` | shut down after this many minutes without mains power (0 = only when the battery reports empty) | `5` |
| `lowBatteryPercent` | charge the UPS reports as "empty" (not every driver allows it) | the UPS's value |

```bash
sudo hs rebuild
```

```bash
hs ups
```

It shows mains or battery, charge, runtime and load; the raw values are `upsc ups@localhost`. In an outage you get "power failure" on the
phone; if the power returns within `shutdownMinutes` you get "power is back" and nothing happens, otherwise (or when the battery reports empty)
the server shuts down cleanly. `hs health` also reports battery operation, an empty battery, a needed battery replacement and a UPS that cannot
be read. After a shutdown the server stays off unless the BIOS says "Restore on AC power loss: Power On" (usually what you want); and with
encrypted disks it is locked after the start (`hs unlock`).

**Test it, in this order.** First `hs ups` shows mains power and 100 %. Then pull the UPS's mains plug for about 20 seconds: `hs ups` shows
"ON BATTERY" and the phone shows "power failure"; plug it back in. For the shutdown test set `shutdownMinutes = 1`, rebuild, pull the plug and
wait a minute: the server must shut down cleanly. Plug in, start the server, read `journalctl -b -1 | tail`, and set your value again. A full
runtime test stresses the battery: do it once with a new UPS and after a battery replacement. The log of the process:
`journalctl -u upsmon -u upsd -u upsdrv -u hs-ups-deadline`. Not tested on hardware yet: it was written and tested with a fake `upsc`.

If `hs ups` says "not reachable", check the cable and `lsusb`; usually the driver is wrong. If the charge is missing in `upsc`, the driver does
not report it (the timed shutdown still works). Containers cannot read the UPS: NUT listens on the server only.

## Start faster

Measure first (no root needed):

```bash
systemd-analyze
```

```bash
systemd-analyze critical-chain
```

Time spent in the BIOS menu counts as firmware time, so reboot once, leave the BIOS alone and measure after you sign in. What usually decides:

| Part | What helps |
| --- | --- |
| Boot loader | the menu is hidden (`boot.loader.timeout = 0`); hold the space bar while starting to get it, or `sudo hs reboot --menu` |
| Network | DHCP can take several seconds after link-up when the switch port runs Spanning Tree: set the port the server uses as an **edge port** ("PortFast", "fast forwarding") in the switch. Never on a port to another switch or the router, and do not switch Spanning Tree off for the whole switch |
| Firmware | UEFI-only mode, no boot logo, the board's "fast boot", and nothing else you do not need; the options differ per board |
| SATA | a controller that reports many empty ports can make the kernel wait at each one |

Check whether the network wait is yours:

```bash
journalctl -b -u dhcpcd --no-pager
```

The time between "carrier acquired" and "leased" should be about a second. Enter the BIOS from the running server, also without a keyboard:

```bash
sudo hs reboot --firmware
```

**If the screen stays black after changing fast-boot options**, the integrated graphics may have been switched off. Plug the monitor into the
graphics card, run `sudo hs reboot --firmware` over SSH, set the integrated graphics back to enabled and save. If nothing shows even then, clear
the CMOS with the board's jumper (power cable out, bridge it for about ten seconds) and start with the monitor on the card; all BIOS values are
default afterwards. Boot time does not include `hs unlock`: with encrypted storage the server waits for it.

## Reach the server from outside

Do not open ports at home. Use a private network:

- **Tailscale** (capability `tailscale`): the server joins your tailnet, so you reach it from anywhere. After the capability is on, join once
  by hand with `sudo tailscale up`; add `--advertise-routes=192.168.1.0/24` to reach the whole home network. `sshOverIp = false` in
  `machine.toml` then closes SSH on the network cards so it works only over Tailscale. **Set it only after SSH over Tailscale works**, otherwise
  you lock yourself out; the configuration refuses it while no private-access provider is on.
- **The web interface** has its own HTTPS option over Tailscale ([Web interface](web-interface.md)).
- Games and other public services are not tunneled by the server. Use a small public server in front (next section).

## Notice when the server is gone

A server cannot report its own power cut, crash or broken router. So it checks in every 15 minutes with something **outside** ("I am alive"),
and a second machine raises the alarm when the check-in stops. You need a second long random topic, **not** the one you subscribed to:

```bash
sudo hs config set heartbeatUrl https://ntfy.sh/<another-long-random-topic>
```

From the next health check on, the heartbeat arrives (priority "min", so your phone stays quiet). The watcher runs on an edge node (below) or
any small server: it reads that topic every five minutes and also checks that your public addresses answer. You get an **urgent** message
when no heartbeat arrived for 45 minutes or an address does not answer (or answers 5xx), at most one reminder a day, and a message when all is
well again. A 404 counts as "reachable". Put no administration pages into the watched addresses. If ntfy.sh cannot be reached from the watcher,
the heartbeat is not judged, so there is no false alarm. Anyone who knows the heartbeat topic could send a fake heartbeat: keep it secret.
This is a second net next to the health check, not a replacement.

## Run a public edge node

An **edge node** is a small server in a data centre that is the public face of your setup: it receives your mail (and queues it while the home
server is down), forwards game ports, runs the outside watcher and publishes a status document. Nothing at home is opened; the edge node and the
home server talk over Tailscale. It is a node of this repository with `role = "edge"` and the capabilities `edge-mail`, `edge-ports`,
`edge-watcher` and `edge-status`. Not tested on hardware yet: it runs in tests with stand-ins, not on a real VPS.

Plan it first on an **empty** test VPS or VM next to anything real: use a Tailscale auth key with its own tag, a separate empty ntfy topic, and
no MX record. On a machine with the installer stick:

```bash
sudo hs-install --role edge --hostname edge-test
```

The wizard asks for the disk (you type its name), your SSH key and the time zone, erases only that disk and applies the `edge` preset. On a
server that already runs NixOS, apply it yourself:

```bash
sudo hs preset apply edge
```

Put the Tailscale auth key into `/var/lib/hs/tailscale-authkey` (mode 0600, read on first start only), set the two push addresses with
`hs config set notifyUrl ...` and `hs config set heartbeatUrl ...`, and fill the section "Edge node" of `machine.toml`:

| Option | Meaning |
| --- | --- |
| `edgeDomain`, `edgeMxHost`, `edgeAcmeEmail` | the mail domain, the name of the mail host (its A record points at this VPS) and the e-mail for the certificate |
| `edgeStalwartIp`, `edgeWingsIp` | Tailscale addresses of the mail server and of the game host at home |
| `edgeGamePorts`, `edgeGameTcp`, `edgeGameUdp` | the game ports to forward |
| `edgeWatchSites` | the public addresses the watcher checks |

An empty value switches off only its part and warns at the rebuild. The build **refuses** a game port range that contains 22, 25, 80, 2222 or
41641 (never forward "everything"). Then:

```bash
sudo hs config check
```

```bash
sudo hs rebuild
```

Read the node's status document and run its health check (a dry run sends nothing):

```bash
hs sys edge status
```

```bash
hs edge health --dry-run
```

On the **home server** register the edge node and let it read the status over SSH (a key that may only say `status`, never a shell):

```bash
hs node add edge-test <tailscale-name-of-the-edge-node> --kind edge
```

```bash
hs node key edge-test
```

The second command prints a line `nodeKeys = ["ssh-ed25519 ..."]` for the edge node's `machine.toml`; rebuild there, then:

```bash
hs node status edge-test
```

Close public SSH last, and only once SSH over Tailscale works (`sshOverIp = false`, see above). The switch of DNS and MX records is never done by
a command: it is a checklist you work through by hand (`docs/PLAN-nodes.md`, "Cutover checklist"). What a trial run does not prove: real mail
delivery from the internet, outgoing mail, long game sessions through the forwarding, and a reboot of the real VPS.

## What to check, and when

| When | What |
| --- | --- |
| Every day | nothing: the 15-minute health check and your phone watch for you |
| After each update | `hs health`, `hs doctor` |
| Weekly | `hs disk list`; glance at the web interface summary |
| Monthly | `hs expiry list`; `hs cleanup`; a restore test ([Backup and recovery](backup-and-recovery.md)) |
| After a crash or new RAM | the memory test |
| After a new UPS or battery | the UPS tests |
| Yearly | clean the fans; check the UPS battery age |

## Check that it worked

- `hs health test` puts a message on your phone.
- `hs health` says `No problems found.`
- `hs expiry list` shows your dates with the days left.
- `hs ups` shows mains power (when a UPS is set up).
- Stop the heartbeat for 45 minutes on purpose (or the watcher's source) and see that the alarm arrives.

## If something goes wrong

| Symptom | Cause | Fix |
| --- | --- | --- |
| No message arrives | `notifyUrl` unset or the topic differs from the one in the app | `hs config get notifyUrl`; compare; `journalctl -t hs-notify` |
| Too many repeated messages | a problem that stays | fix it, or `hs health ack <id>` |
| `hs update` stops | the checkout is dirty or diverged | see [Know that the configuration is in sync](#know-that-the-configuration-is-in-sync) |
| An update rolled back | a new problem appeared after the switch | read the message, fix the cause in the checkout, `hs rebuild` (`config:unbuilt` stays until then) |
| `hs ups` says "not reachable" | cable or wrong driver | `lsusb`, `nut-scanner -U`, `journalctl -u upsdrv -u upsd` |
| The server does not start after a power cut | BIOS setting | "Restore on AC power loss: Power On" |
| Storage is locked after a start | encrypted disks | `hs unlock` ([Encryption and vault](encryption-and-vault.md)) |
| `hs node status` does not answer | `nodeKeys` is missing on the node, the ACL lacks tcp 2222, or the vault is locked | add the key, fix the ACL, `hs unlock` |
| `mail.stalwart: false` in the edge status | the Tailscale ACL does not allow the edge node to reach port 25 of the mail server | adjust the ACL |

## Next

- [Backup and recovery](backup-and-recovery.md): the other half of keeping data safe.
- [Web interface](web-interface.md): the same health and notification pages in the browser.
- [Storage and disks](storage-and-disks.md): replacing a disk the health check flagged.
