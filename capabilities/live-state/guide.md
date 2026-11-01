# Live state for the web interface

The web interface shows the Summary facts from a small Redis cache that a collector fills, and updates the page when they change, without polling.
It is for servers that run the web interface.

## Before you start
- The web interface is on: `webUi = true` in `machine.toml` (see [Web interface](../../docs/web-interface.md)).
- This guide is not tested on hardware yet.

## Switch it on
Not tested on hardware yet.

```bash
sudo hs config set liveState '"redis"'
```

```bash
sudo hs rebuild
```

Redis starts on a unix socket (no network port) and the collector `hs-live` starts. The Summary page then updates by itself.

## Switch it off
Set `liveState = "off"` in `machine.toml`, then rebuild. The web interface reads directly again.

```bash
sudo hs rebuild
```

## Check that it worked
Not tested on hardware yet.

```bash
hs sys live status
```

Every topic shows an age of a few seconds (the age is `-1` when nothing has been collected yet) and an empty error (`-`).

When live state is on, the Diagnostics page shows the live topics instead of the old collected-reads table. It follows the live stream
(`/api/events`) and falls back to polling every 5 seconds when the stream is lost. If Redis or the collector is down, the page shows a
"state service down" banner and keeps the last table data; it never runs the read directly. With live state off, Diagnostics keeps the
collected-reads view it had before. Not tested on hardware yet.

### Storage pages
With live state on, the fixed reads of the Storage pages (Pools, Disks, Shares, Encryption, Vault and the file locations) come from Redis and
update when the data changes. A quick change from the terminal (`hs share`, `hs disk`, `hs pool`, `hs vault`, `hs unlock`) asks for a focused
refresh, and a finished background job refreshes everything. What you select for a single disk, share or file (SMART history, access lists,
snapshots, folder contents) is still read directly. The two pools `bulk` and `fast` have their own topics; any other pool name is read
directly. With live state off nothing changes. Not tested on hardware yet.

### Dashboard, Instances, Apps and Network pages
With live state on, the Summary and top bar, Health, Settings, Instances and Services, the Marketplace and Apps, and the Network pages (gateway,
DNS, router, open ports, remote shares) also come from Redis and update when the data changes. A change from the terminal or the web interface
refreshes only the pages it can affect, and a finished background job refreshes everything. Reads for one named item (an instance's logs, one
service, one user) stay direct. Parts that are switched off, such as the gateway without its capability, are skipped without an error.
With live state off nothing changes. Not tested on hardware yet.

### Users and Backup pages
With live state on, the user and group lists, the domain controller certificate state and the Backup page (state, shares and containers with their
backup switch) also come from Redis. They update after a user, share, instance or backup change, and the backup state also when the backup disk is
plugged in or removed. Users and groups appear only when Active Directory is set up. What you look up for one user or group, and the snapshots and
file search of the backup, are still read directly. With live state off nothing changes. Not tested on hardware yet.

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| The page says "state service down" | Redis or the collector is not running | `systemctl status redis-hobnix hs-live`, then `sudo systemctl restart redis-hobnix hs-live` |
| The page says "refreshing" for a few seconds | The first value is not collected yet | Wait; the page retries by itself |
| `hs sys live status` shows a growing age | The collector is stuck or the read fails | `journalctl -u hs-live` |

## Next
- [Web interface](../../docs/web-interface.md)
