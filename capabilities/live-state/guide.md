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

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| The page says "state service down" | Redis or the collector is not running | `systemctl status redis-hobnix hs-live`, then `sudo systemctl restart redis-hobnix hs-live` |
| The page says "refreshing" for a few seconds | The first value is not collected yet | Wait; the page retries by itself |
| `hs sys live status` shows a growing age | The collector is stuck or the read fails | `journalctl -u hs-live` |

## Next
- [Web interface](../../docs/web-interface.md)
