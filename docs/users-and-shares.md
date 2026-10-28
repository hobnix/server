# Users and shares

Give every person one account and decide per share who may read, who may write and who may not enter. For a household or a small
team, with the server already running ([Install](install.md)).

Two ways to run it:

| Variant | Who can sign in | Rights per share |
| --- | --- | --- |
| **Without a domain** (default) | only `adminuser`, with a Samba password | `adminuser` may do everything |
| **With a domain** (several people) | any number of accounts, one password each, the same for every app that supports it | per share and per person or group: write, read or no access |

The domain is an Active Directory (AD) domain run by a small virtual machine on the server. The PCs of your household do **not** have to
join it: people type a user name and password when they open a share.

## Before you start

- A running server with a pool and the share folders ([Storage and disks](storage-and-disks.md)).
- For the domain variant: a router or DNS server where you can forward one domain name to another address, and about 2 GB of RAM and 20 GB of
  disk for the controller VM.
- Example values on this page: realm `AD.EXAMPLE.LAN`, short name `EXAMPLE`, server `homeserver` at `192.168.1.10`, controller `dc1`
  at `192.168.1.40`. Use your own. The realm cannot be changed later; the short name must differ from every other domain on your network.

## Create a share

A share is one folder with its own Windows/macOS/Linux network name. There are two parent folders:

| Folder | Access over the network | For |
| --- | --- | --- |
| `/bulk/shares/<name>` | read and write | files people keep and edit: media, documents, photos |
| `/bulk/sensitive/<name>` | read only | files a container manages (for example game server backups): you can copy them away, not change them by accident |

```bash
sudo hs share add photos
```

The share is now `\\homeserver\photos`. To make a read-only one:

```bash
sudo hs share add app-backups --sensitive
```

To mount the folder into a container at the same time, add `--ct <container> <path>` (see [Containers and apps](containers-and-apps.md)).
Two catch-all shares, `\\homeserver\shares` and `\\homeserver\sensitive`, show a whole parent folder and are for administrators only.

## Without a domain: set the password once

Without a domain only `adminuser` can open shares. Set its Samba password (separate from its SSH login):

```bash
sudo smbpasswd -a adminuser
```

Then connect as described under [Connect to a share](#connect-to-a-share). Everything below from "Set up the domain" on is optional.

## Set up the domain

One command creates the controller VM, creates the domain, tells you what to enter in your router and joins the server to the domain as its
file server. It asks for the domain name and an administrator password (typed on the terminal, never stored by the recipe):

```bash
sudo hs recipe domain
```

The controller needs a **fixed address** before the domain is created: reserve one for `dc1` in your router (`hs net setup` connects a
UniFi router, `hs net ip dc1 set <address>` reserves it) and the recipe stops with a message if it is missing. The recipe needs a
terminal. It stops once to ask you to add a DNS entry in your router; add it and run the recipe again, it continues from there:

| Field | Value |
| --- | --- |
| Type | forward a domain (conditional forwarder) |
| Domain name | `ad.example.lan` |
| DNS server | the address of the controller, for example `192.168.1.40` |

The controller is a VM, not a container: a container cannot set the file attributes a domain controller needs. `hs recipe domain --dry-run`
shows every step first. A second controller on a second server keeps sign-in working when one server is down: run
`sudo hs recipe domain --join <address of the first controller>` there. Not tested on hardware yet.

What changes for your shares after the join:

- **Sign in with domain accounts**, for example `EXAMPLE\alice`.
- **New shares start locked.** Only "Domain Admins" can open them until you grant access (next section).
- **Shares that existed before the join stay open to everyone** until you close them (see [Close an open share](#close-an-open-share)).
  `hs health` lists each of them as `share <name> is open to everyone`.

Check that the server knows the domain:

```bash
sudo wbinfo -t
```

It prints `succeeded`. `wbinfo -u` lists the domain users and `id 'EXAMPLE\administrator'` shows a user number.

## Create users and groups

Do this in the web interface (**Identity**, pages Users and Groups) or with `hs`. Passwords are never part of a command: the command asks on the
terminal and passes them straight to the controller.

```bash
sudo hs user add --name alice --full "Alice Example"
```

The login name is lower case without spaces. Add `--groups family,media` to put the user into groups at once. Groups save work as soon as
several people need the same rights:

```bash
sudo hs group add family
```

```bash
sudo hs user alice join family
```

`hs user alice leave family` takes the user out again, `hs user list` and `hs group list` show everything. Membership applies at once; a user
is always in "Domain Users".

Other account tasks:

| Task | Command |
| --- | --- |
| New password | `sudo hs user alice passwd` |
| Lock an account (it stays, but opens nothing) | `sudo hs user alice lock` |
| Unlock it | `sudo hs user alice unlock` |
| Delete an account (you type the name) | `sudo hs user alice remove` |
| Delete a group | `sudo hs group family remove` |

**Who administers?** Anyone in the group **Domain Admins** can change share rights and open every share. After setup that is only
`Administrator`. Use it for administration and a normal account for daily use. `Administrator` cannot be locked, deleted or removed from
"Domain Admins" with `hs`, so you cannot lock yourself out.

Deleting an account is final: its files stay in the shares, but its rights become dead entries, and a new user with the same name does not
get them back.

If a new user or a new group membership does not show up, the file server still remembers the old state for a few minutes. Make it forget:

```bash
sudo hs user flush
```

## Give people access to a share

Each share has a list: per group or person one level.

| Level | Meaning |
| --- | --- |
| `none` | no access (the entry is removed) |
| `read` | open and copy |
| `write` | also change and delete |
| `full` | like `write`; at least one entry must have `full`, otherwise nobody can manage the share again. Meant for "Domain Admins" |

Rights add up: someone in a group with `write` who is also listed with `read` may write. Shares under `/bulk/sensitive` stay read-only
whatever the level says.

Show the list:

```bash
sudo hs share photos show
```

Set levels, one or more `<name>=<level>` at once (quote names with a space):

```bash
sudo hs share photos perm alice=write 'Domain Admins=full'
```

Run `hs share photos perm` on a terminal without entries to pick users and levels from a menu; add `--dry-run` to see the change first. The
same is available in the web interface under **Storage > Shares**.

Changed rights apply to **new connections** only. Someone who has the share open keeps the old state until they reconnect. To test with fresh
connections, disconnect everyone:

```bash
sudo systemctl restart samba-smbd
```

### Close an open share

`Everyone` in a share's list means "anyone". If it has a level other than `none`, the share is open to all (typical for shares that
existed before the domain). Close it and keep the administrators in:

```bash
sudo hs share photos perm Everyone=none 'Domain Admins=full'
```

Then give the people who should have access their level. `hs health` checks this every 15 minutes and warns when a share is open.

### Hide a share from the network list

New shares are hidden: they do not show up when someone browses the server, and whoever has access still opens them by typing
`\\server\share`. In the web interface open Storage > Shares, pick the share, tab Permissions, and switch **Visibility** to Visible or
Hidden (`hs sys shares plan <share> visibility --to visible|hidden`). It sets Samba's `browseable` for that share and applies the next time
a computer looks at the server. Shares that existed before keep their current state. Not tested on hardware yet.

### Rights from Windows

The same list can be edited with the Windows program "Shared Folders" (`fsmgmt.msc`). Windows allows one login per server name, so connect to
the server by its **address** for administration and by its **name** for daily use:

```powershell
net use \\192.168.1.10\IPC$ /user:EXAMPLE\Administrator
```

Open `fsmgmt.msc`, choose **Action > Connect to another computer**, enter the address, open the share's **Properties > Share Permissions**
and add users as `EXAMPLE\alice` (the short form; the long form `ad.example.lan\alice` is rejected). "Read", "Change" and "Full Control"
are `read`, `write` and `full`. Keep "Domain Admins" in the list. If Windows says "Access is denied" on saving, allow the administrators to
set rights once:

```bash
sudo net rpc rights grant 'EXAMPLE\Domain Admins' SeDiskOperatorPrivilege -U Administrator
```

## Connect to a share

Windows: open `\\homeserver\photos` in Explorer and sign in as `EXAMPLE\alice`, or map a drive:

```powershell
net use F: \\homeserver\photos /user:EXAMPLE\alice /persistent:yes
```

macOS: in Finder choose **Go > Connect to Server** and enter `smb://homeserver/photos`.

Linux: mount it with CIFS (package `cifs-utils`):

```bash
sudo mount -t cifs //homeserver/photos /mnt/photos -o username=alice,domain=EXAMPLE
```

Without a domain, use `adminuser` and the Samba password from above. If the name `homeserver` is not found, use the server's address,
for example `\\192.168.1.10\photos`.

## Bring back a deleted share

Deleting a share (web interface, **Storage > Shares**) removes it from Samba and from the containers, but its files stay for a week as a
folder named `<name>.deleted-<date>`. Bring it back under the old name; the first command only shows what it would do:

```bash
sudo hs share restore-kept photos.deleted-20261001 --dry-run
```

```bash
sudo hs share restore-kept photos.deleted-20261001
```

The command only renames the folder (on ZFS the dataset, on SnapRAID the folder on every data disk) and publishes it again. It never
overwrites or removes anything: if a share, folder or dataset with the old name exists, it stops. The share comes back **locked**; grant
access again and mount it into containers again if you need to.

To repair file ownership of all shares (everything is written as `adminuser` on disk):

```bash
sudo hs share repair
```

## Share a folder with another server

Two servers can show each other a folder **read-only**, for example so a media server can play the other's films. Nothing is copied, and the
other server's folder is not part of your pool, parity or backup. If the other server is off, the folder is empty. Not tested on hardware yet.

On the **giving** server (the one whose files are shown):

```bash
sudo hs remote offer media --peer cousin
```

`cousin` is the name of the other person (lower case, digits, `-`). The output holds the line for the other side and a one-time password;
pass both on by a safe route, not by mail. On the **receiving** server:

```bash
sudo hs remote add alpha alpha.local media --user remote-cousin --domain EXAMPLE
```

The command asks for the password; the share appears under `/mnt/remote/alpha/media` (check with `hs remote list`). To use it in a media
container:

```bash
sudo hs remote attach alpha jellyfin
```

In the media server add the library folder `/media-alpha/media/...`, switch off "save metadata into media folders" and rescan on a schedule
(live monitoring does not work over SMB). Take it away again:

```bash
sudo hs remote detach alpha jellyfin
```

```bash
sudo hs remote remove alpha
```

On the giving side `hs remote revoke cousin` withdraws access and deletes the login; `hs remote offer ... --new-password` sets a new password.
The login `remote-<name>` is a domain user in "Domain Users": do not give that group to a share it must not see. While the vault is locked
(after a reboot, before `hs unlock`) nothing is mounted.

## Check that it worked

- `hs user list` and `hs group list` show your accounts and memberships.
- `hs share photos show` lists who has which level.
- `hs health` reports `No problems found.` or lists open shares.
- Open the share as a normal user from a PC: the user sees only the shares granted to them.

## If something goes wrong

| Symptom | Cause | Fix |
| --- | --- | --- |
| The domain cannot be created in a container | a container cannot set the needed file attributes | use the VM (`hs recipe domain` does) |
| The controller keeps its old address | the router has two entries for the same name, the fixed address sits on the wrong one | delete the stale entry, then `incus restart dc1` |
| A name under the domain does not resolve (`nslookup` says non-existent) | the forward rule in the router is missing | add it as in [Set up the domain](#set-up-the-domain) |
| `wbinfo -u` says `WBC_ERR_WINBIND_NOT_AVAILABLE` | the service started before the join and gave up | `sudo systemctl restart samba-winbindd samba-smbd` |
| `wbinfo -t` fails but `wbinfo -u` works | `wbinfo -t` needs root | `sudo wbinfo -t` |
| `hs user list` says there is no domain controller | the VM `dc1` does not exist or is stopped | `incus start dc1`; if it has another name: `sudo HS_DC=<name> hs user list` |
| `fsmgmt.msc`: "Access is denied" | Windows is not connected as administrator, or the group may not set rights yet | connect by address as `EXAMPLE\Administrator`; run the `net rpc rights grant` command above |
| "is not a valid name" when adding a user in Windows | the long form `ad.example.lan\name` was typed | type `EXAMPLE\name` |
| Changed rights have no effect for someone | their connection was already open | reconnect, or `sudo systemctl restart samba-smbd` |
| New share is open to everyone instead of locked | it could not be restricted at creation | [Close an open share](#close-an-open-share) |
| Windows says "network path not found" though the server runs | Windows tries an old saved login | `cmdkey /delete:HOMESERVER`, `net use * /delete /y`, connect again |
| Login refused although the password is right | Windows is already connected to the same server name as another user | `net use * /delete /y`, connect again |
| Nobody can sign in any more | the domain controller is not running | `incus list dc1`, `incus start dc1`; a second controller prevents this |

To look closer: `incus exec dc1 -- systemctl status samba-ad-dc --no-pager`, `incus exec dc1 -- samba-tool user list` and `sudo smbstatus`
(who is connected to which share).

## Next

- [Storage and disks](storage-and-disks.md): pools, SnapRAID, disk health.
- [Containers and apps](containers-and-apps.md): mounting shares into containers.
- [Web interface](web-interface.md): the same tasks in the browser.
