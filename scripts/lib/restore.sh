# shellcheck shell=bash
# Helpers of the disaster-recovery installer (scripts/install-restore.sh, scripts/install-wizard.sh --restore-from).
# UNVERIFIED: not tested on hardware. Tests (tests/install-restore.sh) use a fake restic and a temporary folder, no disk.
#
# The restored files come from the "host" snapshot of the backup, one folder per original path (like `hs backup config restore`).

# What of /var/lib/hs a fresh machine does NOT get back. restic-password: a secret that belongs into the new vault by hand; disks/: describes
# the old disk mounts; the temp and safety-copy leftovers. vault-uuid and luks-uuids are kept (docs/backup-and-recovery.md Case A step 4:
# the data disks are the same ones). Differs from scripts/backup.sh state_skip, which protects a RUNNING server.
restore_skip() {   # restore_skip <path relative to the state folder>
  case "$1" in
    restic-password|disks|disks/*|.config-restore.*|*.before-restore-*) return 0 ;;
  esac
  return 1
}

restore_snapshots() {   # restore_snapshots <repo> <passfile>: id<TAB>time of the host snapshots, newest last
  restic -r "$1" --password-file "$2" snapshots --tag host --json 2>/dev/null |
    python3 -I -c 'import json,sys
for s in sorted(json.load(sys.stdin), key=lambda s: s["time"]):
    print(s["id"][:8] + "\t" + s["time"][:16].replace("T", " "))'
}

restore_fetch() {   # restore_fetch <repo> <passfile> <snapshot|latest> <dir>: the settings of the host snapshot below <dir>
  restic -r "$1" --password-file "$2" restore "$3" --tag host --target "$4" \
    --include /etc/nixos/machine.toml --include /etc/nixos/machine.nix \
    --include /var/lib/hs --include '/etc/ssh/ssh_host_*' >/dev/null 2>&1
}

restore_files() {   # restore_files <dir>: the files restore_apply would put in place, one per line (path as on the new system)
  local d=$1 f rel
  for f in /etc/nixos/machine.toml /etc/nixos/machine.nix; do [ -f "$d$f" ] && echo "$f"; done
  if [ -d "$d/var/lib/hs" ]; then
    while IFS= read -r -d '' f; do   # files only: a link into the vault must not be copied
      rel=${f#"$d/var/lib/hs/"}
      restore_skip "$rel" || echo "/var/lib/hs/$rel"
    done < <(find "$d/var/lib/hs" -type f -print0 | sort -z)
  fi
  for f in "$d"/etc/ssh/ssh_host_*; do [ -f "$f" ] && echo "/etc/ssh/${f##*/}"; done
  return 0
}

restore_apply() {   # restore_apply <dir> <target root>: copy the files of restore_files into the new system, keeping modes
  local d=$1 t=$2 f
  while IFS= read -r f; do
    mkdir -p "$t$(dirname "$f")"
    cp -a "$d$f" "$t$f"
  done < <(restore_files "$d")
}
