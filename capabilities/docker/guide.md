# Docker on your server

Turn Docker on as part of hobnix: one locked container holds Docker and your apps, and it is in the backup. For anyone who wants Docker apps next to the Incus containers.

## Before you start
- Incus runs on the server (a container can be created: `hs ct list` works).
- Nothing else is called `docker` yet. A container from the old `hs recipe docker` blocks this; taking it over (`hs docker adopt`) comes later.
- This guide is not tested on hardware yet.

## Turn Docker on
Not tested on hardware yet.

```bash
sudo hs docker enable --dry-run
```

The plan shows the container, its size and the manager. The manager is `webui` by default: that page of the web interface is built later, so for now `webui` only records the choice and starts nothing. Choose `--manager arcane`, `--manager portainer` or `--manager none` (Docker only) to change that, and `--size s`, `m` or `l` (2, 4 or 8 GiB of memory) for the size.

```bash
sudo hs docker enable
```

It asks, then creates the container `docker`, installs Docker, makes the share `apps` on the SSD pool and gives it to Docker (see "Where the app data goes"; a share called `apps` on the disks stops this), starts the manager if there is one, locks the container and adds it to the backup (unless the setting `backupNewInstances` is false: then it prints how to do it later, `hs backup ct docker on`). It can run in the background (`--job`).

## Look at the apps
Not tested on hardware yet.

```bash
hs docker list
```

Every compose project in Docker is an app, with its state and the ports it publishes. The manager itself is not listed. `hs docker status` shows the container, the manager, the size and the address.

## Where the app data goes
All files of the apps are in one share, `apps`, on the SSD pool (`/fast/shares/apps` on the server, `/shares/apps` inside Docker). An app made on the Docker page has its folder `stacks/<app>/` (`docker-compose.yml`, `.env`, `data/`), an app made by a recipe `recipes/<app>/`. You can also drop a folder with a `docker-compose.yml` into `stacks/` over Samba. Keep the data of an app in a folder under its own folder and mount it as a bind mount. The share is in the backup and has automatic snapshots. Named Docker volumes are not in the backup. Apps from an earlier version stay in `/opt/apps/<app>` inside the container (and in its backup) until they are moved. Not tested on hardware yet.

## Turn Docker off
**This deletes the container `docker` and its containers.** Snapshots go with it; the backup stays. The share `apps` with the files of your apps stays on the SSD pool; delete it too with `hs share apps delete`. Apps still in `/opt/apps` are deleted with the container. Look at the plan first.

Not tested on hardware yet.

```bash
sudo hs docker disable --dry-run
```

```bash
sudo hs docker disable
```

It offers a backup, then asks you to type `docker`.

## Check that it worked
- `hs docker status` shows `state on` and `owned yes`.
- `hs ct list` shows the container `docker` with a lock.

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| "An instance called 'docker' exists and is not managed by hs" | The container comes from the old docker recipe | Wait for `hs docker adopt`, or use another name for the recipe |
| A step failed during enable | The setting is not written, so Docker stays off | `sudo hs docker disable`, then `sudo hs docker enable` again |
| `hs ct docker delete` is refused | The container is locked | `sudo hs docker disable` |

## In the web interface
Open Settings, Capabilities, Docker. Two questions follow, one screen each: which page manages Docker, and how large the container is. The review shows the plan; nothing is created until you start it, and it runs as a background job. Not tested on hardware yet.

## Next
- [Containers and apps](../../docs/containers-and-apps.md)
- [Backup and recovery](../../docs/backup-and-recovery.md)
