# backup

The nightly `hs-backup` (04:00), the monthly restore drills (files on the 15th, containers on the 22nd) and the report on the 25th. The commands
(`hs backup ...`) and the state files are scripts/backup.sh; this capability is only the timers. Requires `storage`.

- Everything waits for `bulkReady`; without the restic password file (`hs backup init`) the units do nothing.
- An edge node has no backup of its own: its configuration is the repository, its secrets are a few files.
