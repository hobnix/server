#!/usr/bin/env bash
# help: back up shares, chosen containers, the domain controller and the host config with restic to the disk labelled "backup"
# help.de: sichert Freigaben, ausgewählte Container, den Domänencontroller und die Server-Einstellungen mit restic auf die Platte mit dem Etikett "backup"
# args: [--state | --shares | --snapshots | status | now | list | find <name> | restore <snapshot|latest> <path> | browse [--off] | verify | drill [N] | drill ct [<name>] | report | offsite set <repo>|now|off | init [<device>] | <share> on|off | ct <name> on|off] [--dry-run]
set -euo pipefail
. "$(dirname "$0")/lib/ui.sh"
. "$(dirname "$0")/lib/dc.sh"
. "$(dirname "$0")/lib/bulkpath.sh"   # disks_root: the pool disks are mounted under /var/lib/hs, which is a host path
. "$(dirname "$0")/lib/secret.sh"   # the password and the off-site keys may live in the vault
. "$(dirname "$0")/lib/backup-dump.sh"   # dump_cmds: the commands of a container's dump descriptor

usage() {
  while IFS= read -r _l; do say "$_l"; done <<'EOF'
usage: hs backup [status]                    what is in the backup, last run, space
       hs backup now [--dry-run]             back up right now (also runs every night)
       hs backup <share> on|off              include a share in the backup or leave it out
       hs backup ct <name> on|off            same for a container (needs to be running) or a virtual machine
                                             (the whole machine as one export file every night, needs that much
                                             free space in /var/tmp or HS_VM_EXPORT_DIR)
       hs backup list                        snapshots (id, time, tag, size)
       hs backup find <name>                 which snapshots contain a file name
       hs backup restore <snapshot|latest> <path> [--tag T] [--to DIR]
                                             restore one file or folder, by default
                                             into /bulk/shares/restored (never over the live copy)
       hs backup browse [--off]              show the whole backup read-only as share "backup-browse"
       hs backup verify                      check part of the stored data
       hs backup prune [--dry-run]           give space back now: delete leftovers of a run that ran out of space, apply the
                                             retention (7 daily, 4 weekly, 6 monthly) and prune
       hs backup drill [N]                   restore N random files (default 5) into a temp folder and compare them
       hs backup drill ct [<name>]           restore a container (the one drilled longest ago, smallest first) into a
                                             throwaway instance without a network, boot it, delete it; also checks the
                                             domain controller backup file and the export file of one virtual machine
       hs backup report [--dry-run]          the report of the restore drills as a push message (it goes out
                                             every month by itself, on the 25th)
       hs backup offsite set <repo>          also copy every backup to a second repository (a folder on another
                                             disk, sftp:user@host:/path, b2:bucket:path ...); keys in
                                             /var/lib/hs/backup-offsite.env. offsite now / off
       hs backup init [<device>] [--dry-run] FORMAT a disk as the backup disk (erases it) and create the repository;
                                             without a device the free disks are listed to pick from

  A share is in the backup once you switch it on (new ones start out; machine.toml
  backupNewShares = true; changes that). The domain controller and the
  host files (machine.toml, /var/lib/hs, the domain join, SSH host keys) are always included.
EOF
  exit 1
}

die() { fail "$@" >&2; }   # the same red line as everywhere, on stderr

# Paths and overrides (the HS_* variables exist for tests)
STATE=${HS_STATE_DIR:-/var/lib/hs}
MNT=${HS_BACKUP_MOUNT:-/mnt/backup}
REPO=${HS_BACKUP_REPO:-$MNT/restic}
DEV=${HS_BACKUP_DEV:-/dev/disk/by-label/backup}
BULK=${HS_BULK:-/bulk}
PASSFILE=$STATE/restic-password
VAULT_SECRETS=${HS_VAULT_DIR:-/var/lib/hs-vault}/secrets
OFF=$STATE/backup-off            # shares left out, one per line
ON=$STATE/backup-on              # shares included on purpose, one per line (only used while new shares start off)
# machine.toml `backupNewShares` (written to /etc/hs/backup-new-shares by configuration.nix):
# "off" = a share is in the backup only when it was switched on; "on" = in unless switched off.
# Without the file (a server that was not rebuilt yet) nothing changes: "on".
. "$(dirname "$0")/lib/setting.sh"   # backupNewShares is a runtime setting now (true|false); the old /etc/hs file (on|off) is its fallback
NEW_SHARES=${HS_BACKUP_NEW_SHARES:-$(case "$(setting_get backupNewShares 2>/dev/null)" in false|off) echo off ;; *) echo on ;; esac)}
CTS=$STATE/backup-instances      # containers included, one per line
DUMPS=$STATE/backup-dump         # one file per container: the command that writes its database dump
OFFSITE=$STATE/backup-offsite    # second repository (restic address), optional
OFFSITE_ENV=$STATE/backup-offsite.env
RESULT=$STATE/backup.state       # read by hs health
DC=$(dc_name)
INCUS_ROOT=${HS_INCUS_ROOT:-/var/lib/incus/storage-pools/default/containers}
BROWSE=/mnt/backup-browse
export RESTIC_CACHE_DIR=${HS_BACKUP_CACHE:-/var/cache/restic}

dry=false
args=()
for a in "$@"; do
  case "$a" in
    --dry-run) dry=true ;;
    --yes)     export HS_BACKUP_YES=1 ;;   # init: the typed confirmation was asked before (the interface's review)
    -h|--help) usage ;;
    *) args+=("$a") ;;
  esac
done
set -- "${args[@]+"${args[@]}"}"
cmd=${1:-status}
[ $# -gt 0 ] && shift

R() { restic -r "$REPO" --password-file "$PASSFILE" "$@"; }

# Remove locks a dead run left behind. `restic unlock` only removes a lock whose process is gone, and a reused PID (or a
# reboot) keeps it for days ("already locked by PID ... 85h ago"); when no restic runs on this host any more nothing can
# hold a lock, so the rest goes too. Callers hold the backup flock.
clear_locks() {
  R unlock >/dev/null 2>&1 || true
  if R list locks 2>/dev/null | grep -q . && ! pgrep -x restic >/dev/null 2>&1; then
    R unlock --remove-all >/dev/null 2>&1 || true
  fi
}
# Is the backup set up? ok | locked (the password is in the vault and the vault is closed) | missing.
# A dangling link must never read as "not set up".
pass_state() { secret_state "$PASSFILE"; }
set_up() { [ "$(pass_state)" != missing ]; }

# ── The backup disk: mounted only while something needs it ──
mounted_by_us=false
cleanup() {
  if declare -F drill_cleanup >/dev/null; then drill_cleanup || true; fi   # the throwaway instance of `drill ct`
  if $mounted_by_us; then
    sync
    umount "$MNT" 2>/dev/null || warn "$(t 'Could not unmount %s (still in use)' "$MNT")" >&2
  fi
}
trap cleanup EXIT

mount_disk() {
  [ -z "${HS_BACKUP_NO_MOUNT:-}" ] || return 0
  mountpoint -q "$MNT" && return 0
  [ -b "$DEV" ] || die "Backup disk not found (no disk with the label 'backup'). Plug it in, or set it up with: hs backup init <device>"
  mkdir -p "$MNT"
  mount -o noatime "$DEV" "$MNT"
  mounted_by_us=true
}

need_repo() {
  [ "$(pass_state)" != locked ] || secret_locked_exit
  [ -f "$PASSFILE" ] || die "Not set up yet. Run: hs backup init <device>"
  mount_disk
  [ -f "$REPO/config" ] || die "$(t 'No backup repository in %s. Run: hs backup init <device>' "$REPO")"
}

# ── What is included ──
# Share folders: name per line, for /bulk/shares and /bulk/sensitive
share_names() {
  local kind
  for kind in shares sensitive; do
    [ -d "$BULK/$kind" ] || continue
    find "$BULK/$kind" -mindepth 1 -maxdepth 1 -type d ! -name 'lost+found' -printf "$kind %f\n" | sort -k2
  done
}
# The first time the default is "off", the shares that are in the backup today are written to
# the "on" list, so switching the default does not silently drop anything; shares that appear
# later start off. (Not writable, e.g. without root: the old rule stays in effect.)
migrate_on() {
  [ -z "${migrated:-}" ] || return 0
  migrated=1
  [ ! -f "$ON" ] || return 0
  local kind name tmp="$ON.new"
  { mkdir -p "$STATE" && : > "$tmp"; } 2>/dev/null || return 0
  while read -r kind name; do
    [ -n "$name" ] || continue
    grep -qxF "$name" "$OFF" 2>/dev/null || printf '%s
' "$name" >> "$tmp"
  done < <(share_names)
  sort -u "$tmp" > "$ON" && rm -f "$tmp"
}
is_off() {
  if [ "$NEW_SHARES" = off ]; then
    migrate_on
    if [ -f "$ON" ]; then grep -qxF "$1" "$ON" && return 1; return 0; fi
  fi
  [ -f "$OFF" ] && grep -qxF "$1" "$OFF"
}
is_ct_on() { [ -f "$CTS" ] && grep -qxF "$1" "$CTS"; }

set_line() {  # set_line <file> <line> add|remove
  local f=$1 line=$2 mode=$3 tmp
  mkdir -p "$(dirname "$f")"; touch "$f"
  tmp=$(grep -vxF "$line" "$f" || true)
  if [ "$mode" = add ]; then tmp+=$'\n'"$line"; fi
  printf '%s\n' "$tmp" | sed '/^$/d' | sort -u > "$f"
}

cmd_toggle_share() {
  local name=$1 mode=$2 found
  found=$(share_names | awk -v n="$name" '$2 == n')
  [ -n "$found" ] || die "$(t 'No share called %s under %s or %s' "$name" "$BULK/shares" "$BULK/sensitive")"
  case "$mode" in
    on)  [ "$NEW_SHARES" != off ] || migrate_on
         set_line "$OFF" "$name" remove; [ "$NEW_SHARES" != off ] || set_line "$ON" "$name" add
         ok "$(t '%s: included in the backup' "$name")" ;;
    off) [ "$NEW_SHARES" != off ] || migrate_on
         set_line "$OFF" "$name" add;    [ "$NEW_SHARES" != off ] || set_line "$ON" "$name" remove
         ok "$(t '%s: left out of the backup' "$name")" ;;
    *) usage ;;
  esac
}

cmd_toggle_ct() {
  local name=$1 mode=$2
  incus info "$name" >/dev/null 2>&1 </dev/null || die "$(t 'No instance called %s' "$name")"
  case "$mode" in
    on)  set_line "$CTS" "$name" add
         if [ "$(ct_kind "$name")" = virtual-machine ]; then
           ok "$(t '%s: included in the backup (the whole virtual machine as one export file, every night)' "$name")"
         else
           ok "$(t '%s: included in the backup (its files, while it runs)' "$name")"
         fi ;;
    off) set_line "$CTS" "$name" remove; ok "$(t '%s: left out of the backup' "$name")" ;;
    *) usage ;;
  esac
}

host_files() {
  local f
  if [ -n "${HS_BACKUP_HOST_FILES:-}" ]; then
    for f in $HS_BACKUP_HOST_FILES; do [ -e "$f" ] && echo "$f"; done
    return 0
  fi
  for f in /etc/nixos/machine.toml /etc/nixos/machine.nix /etc/nixos/hardware-configuration.nix "$STATE" \
           /var/lib/samba/private /etc/ssh/ssh_host_* /var/lib/hs-gateway/acme; do   # acme: the gateway's certificate keys (secret, never printed)
    [ -e "$f" ] && echo "$f"
  done
  # The links in $STATE only point into the vault: with the vault open its secrets go along (the restic
  # password is excluded, like before); closed, they are simply not in this snapshot.
  if vault_is_open && [ -d "$VAULT_SECRETS" ]; then echo "$VAULT_SECRETS"; fi
  return 0
}

# The data and parity disks of the array are mounted under /var/lib/hs/disks (bulkpath.sh), which is inside $STATE: restic follows mounts, so without
# this the "host files" snapshot would copy the whole array (all shares, backup on or off) and fill the backup disk. The shares have their own rule.
host_excludes() {
  printf '%s\n' --exclude "$(disks_root)" --exclude "$STATE/disks"
}

note_state() {  # note_state key=value ...
  mkdir -p "$STATE"
  local kv k tmp
  touch "$RESULT"
  for kv in "$@"; do
    k=${kv%%=*}
    tmp=$(grep -v "^$k=" "$RESULT" || true)
    printf '%s\n' "$tmp" | sed '/^$/d' > "$RESULT.new"
    echo "$kv" >> "$RESULT.new"
    mv "$RESULT.new" "$RESULT"
  done
}

# ── The domain controller: samba's own backup, a small file ──
dc_backup() {
  incus info "$DC" >/dev/null 2>&1 </dev/null || return 0     # no domain controller here
  if [ "$(incus list "$DC" -f csv -c s </dev/null)" != RUNNING ]; then
    warn "$(t '%s is not running, its domain backup was skipped' "$DC")"
    return 1
  fi
  local out=$STATE/backup-dc
  rm -rf "$out"; mkdir -p "$out"
  incus exec "$DC" -- bash -c 'rm -rf /root/hs-dc-backup && samba-tool domain backup offline --targetdir=/root/hs-dc-backup >/dev/null' </dev/null
  incus exec "$DC" -- bash -c 'cat /root/hs-dc-backup/*.tar.bz2 && rm -rf /root/hs-dc-backup' </dev/null > "$out/domain-backup.tar.bz2"
  [ -s "$out/domain-backup.tar.bz2" ] || { echo "empty domain backup from $DC" >&2; return 1; }
}

# ── Incus layout and disks as text, so a lost server can be rebuilt: part of the host files ──
inventory() {
  local out=$STATE/backup-inventory n
  rm -rf "$out"; mkdir -p "$out"
  if command -v incus >/dev/null 2>&1; then
    incus list --format json >"$out/incus-instances.json" 2>/dev/null </dev/null || true
    for n in $(incus list -f csv -c n </dev/null 2>/dev/null); do
      incus config show --expanded "$n" >"$out/instance-$n.yaml" 2>/dev/null </dev/null || true
    done
    for n in $(incus profile list -f csv -c n </dev/null 2>/dev/null); do
      incus profile show "$n" >"$out/profile-$n.yaml" 2>/dev/null </dev/null || true
    done
    incus network list --format json >"$out/incus-networks.json" 2>/dev/null </dev/null || true
    incus storage list --format json >"$out/incus-storage.json" 2>/dev/null </dev/null || true
  fi
  lsblk -f >"$out/lsblk.txt" 2>/dev/null || true
  command -v zpool >/dev/null 2>&1 && zpool status >"$out/zpool-status.txt" 2>/dev/null || true
  command -v zfs >/dev/null 2>&1 && zfs list >"$out/zfs-list.txt" 2>/dev/null || true
  return 0
}

# A database in a container can't be saved by copying its files while it runs. The dump descriptor
# /var/lib/hs/backup-dump/<container> (format and helpers: scripts/lib/backup-dump.sh) lists the commands,
# one per line (mostly `hs-dump ...`, which the recipes install); each runs inside the container right
# before its files are backed up. A failing command does not stop the others; the run counts as failed.
dump_hook() {   # dump_hook <container>
  local f=$DUMPS/$1 cmd n=0 bad=0
  [ -s "$f" ] || return 0
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    n=$((n + 1))
    incus exec "$1" -- sh -c "$cmd" </dev/null || bad=$((bad + 1))
  done < <(dump_cmds "$f")
  [ "$n" -gt 0 ] || return 0
  if [ "$bad" -eq 0 ]; then ok "$(t '%s: dump written' "$1")"; else warn "$(t '%s: the dump command failed' "$1")"; return 1; fi
}

# ── Virtual machines (not the domain controller, which has samba's own backup file) ──
# A container's files can be read from its mounted rootfs; a VM's disk is a block image that restic cannot read consistently
# while the VM runs, and the files inside would need the guest to run and to have an agent. So a VM is backed up as ONE file:
# `incus export` (Incus takes a snapshot of a running VM for it, so the image is consistent as of that moment: crash-consistent,
# like a power cut, plus the dump hook below, which flushes the databases inside first), uncompressed, so restic can deduplicate
# it from night to night. The file lives at a fixed path (HS_VM_EXPORT_DIR, default /var/tmp/hs-vm-export/<name>.tar) so restic finds
# the parent snapshot, is backed up with the tags ct:<name> and vm, and is deleted right after. It needs about the used size of the
# VM as free space there. Restore: `hs backup restore latest <that path> --tag ct:<name>`, then `incus import <file>`.
VMX=${HS_VM_EXPORT_DIR:-/var/tmp}/hs-vm-export
ct_kind() {   # ct_kind <instance>: virtual-machine | container (a container when Incus does not say)
  local k
  k=$("${HS_INCUS:-incus}" query "/1.0/instances/$1" </dev/null 2>/dev/null | jq -r '.type // empty' 2>/dev/null || true)
  [ "$k" = virtual-machine ] && echo virtual-machine || echo container
}
vm_backup() {   # vm_backup <name> <restic backup options...>
  local name=$1 file used avail bad=0 status
  shift
  if [ "$name" = "$DC" ]; then
    note "$(t '%s is the domain controller: its backup is the samba backup file, not an export of the machine' "$name")"
    return 0
  fi
  file=$VMX/$name.tar
  status=$("${HS_INCUS:-incus}" query "/1.0/instances/$name" </dev/null | jq -r '.status // empty')
  # the databases inside are dumped first (needs the guest agent, so only while it runs)
  if [ "$status" = Running ]; then dump_hook "$name" || bad=1; fi
  mkdir -p "$VMX"; rm -f "$file"
  used=$("${HS_INCUS:-incus}" query "/1.0/instances/$name?recursion=1" </dev/null | jq -r '.state.disk.root.usage // 0' 2>/dev/null || echo 0)
  avail=$(df -B1 --output=avail "$VMX" | tail -n1 | tr -d ' ')
  if [[ "$used" =~ ^[0-9]+$ ]] && [ "$used" -gt 0 ] && [ "$avail" -lt $((used + used / 10)) ]; then
    warn "$(t '%s: the export needs about %s free in %s, only %s is free (HS_VM_EXPORT_DIR points it to another disk)' "$name" "$(human $((used + used / 10)))" "$VMX" "$(human "$avail")")"
    return 1
  fi
  step "$(t 'Virtual machine %s' "$name")"
  if ! "${HS_INCUS:-incus}" export "$name" "$file" --instance-only --compression none </dev/null; then
    rm -f "$file"; warn "$(t '%s: incus export failed' "$name")"; return 1
  fi
  [ -s "$file" ] || { rm -f "$file"; warn "$(t '%s: incus export wrote nothing' "$name")"; return 1; }
  R backup "$@" --tag "ct:$name" --tag vm "$file" || bad=1
  rm -f "$file"
  return "$bad"
}

ct_excludes() {  # ct_excludes <rootfs>
  local d
  for d in proc sys dev run tmp var/tmp var/cache var/lib/apt/lists var/log/journal \
           var/lib/docker/overlay2 var/lib/docker/image lost+found; do
    printf -- '--exclude\n%s/%s\n' "$1" "$d"
  done
}

cmd_now() {
  local scheduled=false
  [ "${1:-}" = --scheduled ] && scheduled=true
  if [ "$(pass_state)" = locked ] && ! $dry; then
    # the nightly run does not fail because of a closed vault (the storage-locked marker already says it)
    if $scheduled; then vault_locked_note >&2; return 0; fi
    secret_locked_exit
  fi
  if [ ! -f "$PASSFILE" ] && ! $dry; then
    $scheduled && { line "Backup is not set up (hs backup init), nothing to do."; return 0; }
    die "Not set up yet. Run: hs backup init <device>"
  fi

  local paths=() on=() offn=() cts=() kind name
  while read -r kind name; do
    [ -n "$name" ] || continue
    if is_off "$name"; then offn+=("$name"); else on+=("$name"); paths+=("$BULK/$kind/$name"); fi
  done < <(share_names)
  [ -f "$CTS" ] && while read -r name; do [ -n "$name" ] && cts+=("$name"); done < "$CTS"

  if $dry; then
    echo "Shares in the backup:   ${on[*]:-(none)}"
    echo "Shares left out:        ${offn[*]:-(none)}"
    echo "Containers:             ${cts[*]:-(none)}"
    echo "Domain controller:      $DC (samba-tool domain backup)"
    echo "Host files:"; host_files | sed 's/^/  /'
    say "(dry run, nothing changed)"
    return 0
  fi

  local lock=/run/hs-backup.lock
  [ -w /run ] || lock=$STATE/.backup.lock
  exec 9>"$lock"
  flock -n 9 || die "Another backup is running."
  note_state "last_try=$(date +%s)"
  # restic shows its own progress line on a terminal; in a job or a log (no terminal) one line a minute
  [ -t 1 ] || export RESTIC_PROGRESS_FPS=${RESTIC_PROGRESS_FPS:-0.0167}
  local fail=0 b=(--host "$(hostname)" --exclude-caches)
  mount_disk
  [ -f "$REPO/config" ] || die "$(t 'No backup repository in %s. Run: hs backup init <device>' "$REPO")"
  clear_locks

  if [ ${#paths[@]} -gt 0 ]; then
    step "$(t 'Shares: %s' "${on[*]}")"
    R backup "${b[@]}" --tag shares "${paths[@]}" || fail=1
  fi

  step "Domain controller and host files"
  dc_backup || fail=1
  inventory
  mapfile -t hf < <(host_files)
  if [ ${#hf[@]} -gt 0 ]; then
    mapfile -t hx < <(host_excludes)
    R backup "${b[@]}" --tag host "${hx[@]}" --exclude "$PASSFILE" --exclude "$VAULT_SECRETS/restic-password" "${hf[@]}" || fail=1
  fi

  for name in "${cts[@]+"${cts[@]}"}"; do
    if [ "$(ct_kind "$name")" = virtual-machine ]; then
      vm_backup "$name" "${b[@]}" || fail=1
      continue
    fi
    local root=$INCUS_ROOT/$name/rootfs
    if [ ! -d "$root" ]; then
      warn "$(t '%s: not running (its files are not mounted), skipped' "$name")"
      fail=1; continue
    fi
    step "$(t 'Container %s' "$name")"
    dump_hook "$name" || fail=1
    mapfile -t ex < <(ct_excludes "$root")
    R backup "${b[@]}" --tag "ct:$name" "${ex[@]}" "$root" || fail=1
  done

  # Keep 7 daily, 4 weekly, 6 monthly per kind of snapshot. Space is only
  # given back by prune, which is slow, so that runs on Sundays.
  local forget=(--group-by tags --keep-daily 7 --keep-weekly 4 --keep-monthly 6)
  [ "$(date +%u)" = 7 ] && forget+=(--prune)
  R forget --quiet "${forget[@]}" || fail=1
  if [ "$(date +%u)" = 7 ]; then
    R check --read-data-subset=5% >/dev/null || { warn "restic check found a problem"; fail=1; }
  fi

  if [ -s "$OFFSITE" ]; then
    step "Off-site copy"
    if offsite_copy; then note_state "offsite_ok=$(date +%s)"; else warn "The off-site copy failed (the backup itself is fine)"; fi
  fi

  local used
  used=$(df --output=pcent "$MNT" | tail -n1 | tr -dc 0-9)
  note_state "used_pct=${used:-0}"
  # bytes too, for the forecast of the backup disk (lib/capacity.sh)
  local ub sb
  read -r ub sb < <(df -B1 --output=used,size "$MNT" | tail -n1) || true
  if [[ "${ub:-}" =~ ^[0-9]+$ ]] && [[ "${sb:-}" =~ ^[0-9]+$ ]]; then note_state "used_bytes=$ub" "size_bytes=$sb"; fi
  # for the interface (--state reads them without mounting the disk)
  note_state "snapshots=$(R snapshots --json 2>/dev/null | jq length 2>/dev/null || echo '?')" \
             "repo_size=$(du -sh "$REPO" 2>/dev/null | cut -f1 || echo '?')"
  if [ "$fail" = 0 ]; then
    note_state "last_ok=$(date +%s)" "status=ok"
    grep -q '^first_ok=' "$RESULT" 2>/dev/null || note_state "first_ok=$(date +%s)"
    ok "Backup finished."
    note "See what is in it: hs backup status"
  else
    note_state "status=failed"
    note "Details: journalctl -u hs-backup. Try again: hs backup now"
    die "Backup finished with errors (see above)."
  fi
}

human() { numfmt --to=iec "$1"; }
ago() {
  local t=$1 d
  [ -n "$t" ] || { t 'never'; echo; return; }
  d=$(( $(date +%s) - t ))
  if [ "$d" -lt 3600 ]; then t '%s min ago' "$((d / 60))"; echo
  elif [ "$d" -lt 172800 ]; then t '%s h ago' "$((d / 3600))"; echo
  else t '%s days ago' "$((d / 86400))"; echo; fi
}

cmd_status() {
  local kind name last_ok last_try st drill inc unk dsize
  last_ok=$(sed -n 's/^last_ok=//p' "$RESULT" 2>/dev/null || true)
  last_try=$(sed -n 's/^last_try=//p' "$RESULT" 2>/dev/null || true)
  st=$(sed -n 's/^status=//p' "$RESULT" 2>/dev/null || true)
  if [ "$(pass_state)" = locked ]; then status_line "Backup" "vault closed (hs unlock)" warn
  elif [ ! -f "$PASSFILE" ]; then status_line "Backup" "not set up" warn
  elif [ -z "$last_ok" ]; then status_line "Last backup" "never" warn
  elif [ "$st" = failed ]; then status_line "Last backup" "$(ago "$last_ok"), $(t 'the last try failed')" bad
  else status_line "Last backup" "$(ago "$last_ok")" ok; fi

  step "Shares"
  { thead 'Share' 'Backup'
    while read -r kind name; do
      [ -n "$name" ] || continue
      printf '%s\t%s\n' "$name" "$(is_off "$name" && t 'left out' || t 'in the backup')"
    done < <(share_names); } | table
  step "Containers (opt in with: hs backup ct <name> on)"
  if [ -f "$CTS" ] && [ -s "$CTS" ]; then while read -r name; do [ -z "$name" ] || line "$name"; done < "$CTS"; else line "$(t '(none)')"; fi
  line "$(t 'Always: domain controller %s, host files' "$DC")"
  if [ "$(pass_state)" = locked ]; then vault_locked_note; return 0; fi
  if [ ! -f "$PASSFILE" ]; then line "Not set up yet: hs backup init <device>"; return 0; fi

  step "Backup"
  kv "Last try" "$(ago "$last_try"), $st"
  kv "Disk used" "$(sed -n 's/^used_pct=//p' "$RESULT" 2>/dev/null || echo '?')% $(t '(as of the last run)')"
  drill=$(sed -n 's/^last_drill=//p' "$RESULT" 2>/dev/null || true)
  kv "Restore drill" "$(ago "$drill")$([ -n "$drill" ] || echo "   $(t '(try: hs backup drill)')")"
  drill=$(sed -n 's/^drill_ct_ok=//p' "$RESULT" 2>/dev/null || true)
  if [ -n "$drill" ] || [ -s "$CTS" ]; then
    kv "Container drill" "$(ago "$drill")$([ -n "$drill" ] || echo "   $(t '(try: hs backup drill ct)')")"
  fi
  read -r inc unk <<<"$(included_bytes)"
  if [ "$inc" -gt 0 ] || [ "$unk" -gt 0 ]; then
    kv "Shares size" "$(t 'about %s' "$(human "$inc")")$([ "$unk" -eq 0 ] || echo " $(t 'plus %s share(s) of unknown size (measured overnight)' "$unk")")"
    if mountpoint -q "$MNT" || [ -n "${HS_BACKUP_NO_MOUNT:-}" ] || [ -b "$DEV" ]; then
      mount_disk
      dsize=$(df -B1 --output=size "$MNT" | tail -n1 | tr -d ' ')
      if [ $((inc + inc / 5)) -gt "$dsize" ]; then
        warn "$(t 'That is more than fits on the backup disk (%s): leave shares out (hs backup <share> off) or use a bigger disk' "$(human "$dsize")")"
      else
        kv "Backup disk" "$(t '%s in total, the backup needs about 1.2x the data' "$(human "$dsize")")"
      fi
    fi
  fi
  if [ -s "$OFFSITE" ]; then
    kv "Off-site copy" "$(t '%s, last copied %s' "$(cat "$OFFSITE")" "$(ago "$(sed -n 's/^offsite_ok=//p' "$RESULT" 2>/dev/null || true)")")"
  fi
  if [ -n "${HS_BACKUP_NO_MOUNT:-}" ] || [ -b "$DEV" ] || mountpoint -q "$MNT"; then
    mount_disk
    kv "Snapshots" "$(R snapshots --json | jq length)"
    kv "Repository" "$(human "$(R stats --mode raw-data --json | jq .total_size)")"
  else
    warn "The backup disk is not plugged in."
  fi
}

# ── Second copy: another restic repository, same password ──
R_off() {   # restic on the off-site repository (credentials from the env file)
  [ "$(secret_state "$OFFSITE_ENV")" != locked ] || { vault_locked_note >&2; return 1; }
  ( set -a; [ ! -f "$OFFSITE_ENV" ] || . "$OFFSITE_ENV"; set +a
    restic -r "$(cat "$OFFSITE")" --password-file "$PASSFILE" "$@" )
}
offsite_copy() {
  R_off copy --from-repo "$REPO" --from-password-file "$PASSFILE" >/dev/null
}
cmd_offsite() {
  local sub=${1:-} repo
  case "$sub" in
    set)
      repo=${2:-}; [ -n "$repo" ] || usage
      need_repo
      printf '%s\n' "$repo" > "$OFFSITE"
      if ! R_off cat config >/dev/null 2>&1; then
        R_off init --from-repo "$REPO" --from-password-file "$PASSFILE" --copy-chunker-params >/dev/null ||
          { rm -f "$OFFSITE"; die "$(t 'Could not create the repository %s (credentials in %s?)' "$repo" "$OFFSITE_ENV")"; }
        ok "$(t 'Created the repository %s (same password as the backup disk)' "$repo")"
      else
        ok "$(t 'Using the existing repository %s' "$repo")"
      fi
      note_state "offsite=1"
      note "Every nightly run copies new backups there. Now: hs backup offsite now" ;;
    now)
      [ -s "$OFFSITE" ] || die "No off-site repository. Set one: hs backup offsite set <repo>"
      need_repo
      step "$(t 'Off-site copy to %s' "$(cat "$OFFSITE")")"
      offsite_copy || die "The off-site copy failed."
      note_state "offsite_ok=$(date +%s)"
      ok "Copied." ;;
    off)
      rm -f "$OFFSITE"; note_state "offsite=0"; ok "Off-site copy switched off (what is there stays there)." ;;
    *) usage ;;
  esac
}

# ── Does a restore really work? Random files out of the newest backup, compared with the originals ──
cmd_drill() {
  [ "${1:-}" != ct ] || { shift; cmd_drill_ct "$@"; return; }
  local n=${1:-5} tmp picked f live size ok_n=0 bad=0 args=()
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] || usage
  need_repo
  mapfile -t picked < <(R ls --json latest --tag shares 2>/dev/null | jq -r 'select(.type == "file" and .size > 0) | .path' | shuf -n "$n")
  [ ${#picked[@]} -gt 0 ] || die "No file in the newest shares backup to try."
  tmp=$(mktemp -d)
  for f in "${picked[@]}"; do args+=(--include "$f"); done
  R restore latest --tag shares --target "$tmp" "${args[@]}" >/dev/null || { rm -rf "$tmp"; die "The restore itself failed."; }
  step "$(t 'Restore drill: %s file(s)' "${#picked[@]}")"
  for f in "${picked[@]}"; do
    live=$f; size=$(stat -c %s "$tmp$f" 2>/dev/null || echo missing)
    if [ "$size" = missing ]; then warn "$(t '%s: not restored' "$f")"; bad=$((bad + 1)); continue; fi
    if [ -f "$live" ] && cmp -s "$tmp$f" "$live"; then ok "$(t '%s: identical to the original' "$f")"; ok_n=$((ok_n + 1))
    elif [ -f "$live" ]; then note "$(t '%s: restored, the original has changed since (not compared)' "$f")"; ok_n=$((ok_n + 1))
    else note "$(t '%s: restored (%s bytes), the original is gone' "$f" "$size")"; ok_n=$((ok_n + 1)); fi
  done
  rm -rf "$tmp"
  note_state "last_drill=$(date +%s)"
  [ "$bad" -ne 0 ] || note_state "drill_ok=$(date +%s)"
  [ "$bad" -eq 0 ] || die "$(t '%s file(s) could not be restored.' "$bad")"
  ok "$(t '%s of %s restored.' "$ok_n" "${#picked[@]}")"
}

# ── Does a CONTAINER come back? Its newest snapshot becomes a throwaway Incus instance that boots without a network ──
# restic holds the files of the running container (the shifted ids of the host, under $INCUS_ROOT/<name>/rootfs).
# They are restored into a temp folder, packed as an Incus image with the ids brought back (lib/ct-image.py), imported,
# and started from `incus init --no-profiles` with only a root disk: no NIC, so no MAC or address can clash with the
# real container. Then everything is deleted, also on an error and on Ctrl-C (drill_cleanup, called from cleanup()).
CTDRILL=$STATE/backup-drill-ct        # one line per try: <container> <epoch> ok|failed (the rotation)
CTIMG=$(dirname "$0")/lib/ct-image.py
drill_tmp=""; drill_inst=""; drill_img=""; dc_checked=false
inc() { "${HS_INCUS:-incus}" "$@"; }
drill_cleanup() {
  [ -z "$drill_inst" ] || inc delete -f "$drill_inst" >/dev/null 2>&1 </dev/null || true
  [ -z "$drill_img" ] || inc image delete "$drill_img" >/dev/null 2>&1 </dev/null || true
  [ -z "$drill_tmp" ] || rm -rf "$drill_tmp"
  drill_inst=""; drill_img=""; drill_tmp=""
}

# The container drilled longest ago (never drilled first, the smaller one first), or the one asked for.
# Prints "<name> <snapshot id> <bytes>", nothing when there is none.
drill_pick() {   # drill_pick [<name>] [ct|vm]
  local want=${1:-} kind=${2:-ct} name id size last rows=""
  while IFS=$'\t' read -r name id; do
    [ -n "$name" ] || continue
    if [ -n "$want" ] && [ "$name" != "$want" ]; then continue; fi
    size=$(R stats --mode restore-size --json "$id" 2>/dev/null | python3 "$CTIMG" field total_size 2>/dev/null | tr -d '\r' || true)
    last=$(awk -v n="$name" '$1 == n { t = $2 } END { print t + 0 }' "$CTDRILL" 2>/dev/null || true)
    rows+="${last:-0}"$'\t'"${size:-0}"$'\t'"$name"$'\t'"$id"$'\n'
  done < <(R snapshots --json 2>/dev/null | python3 "$CTIMG" newest "$kind" | tr -d '\r')
  [ -n "$rows" ] || return 0
  printf '%s' "$rows" | sort -t$'\t' -k1,1n -k2,2n | awk -F'\t' 'NR == 1 { print $3, $4, $2 }'
}

# One container. Returns 1 with a warning (never exits), so the domain controller check still runs.
drill_ct_one() {   # drill_ct_one <name> <snapshot id> <bytes>
  local name=$1 id=$2 size=$3 root avail i st="" wait=${HS_DRILL_WAIT:-90}
  local inst="hs-drill-$name" img="hs-drill-img-$name"
  inst=${inst:0:63}
  drill_cleanup
  # leftovers of a run that was killed
  inc list -f csv -c n </dev/null 2>/dev/null | grep -E '^hs-drill-' | while read -r i; do inc delete -f "$i" >/dev/null 2>&1 </dev/null || true; done
  inc image delete "$img" >/dev/null 2>&1 </dev/null || true
  mkdir -p "${HS_DRILL_TMP:-/var/tmp}"
  drill_tmp=$(mktemp -d "${HS_DRILL_TMP:-/var/tmp}/hs-drill.XXXXXX") || { warn "Could not make a temporary folder"; return 1; }
  avail=$(df -B1 --output=avail "$drill_tmp" | tail -n1 | tr -d ' ')
  if [ "${size:-0}" -gt 0 ] && [ "$avail" -lt $((size * 2)) ]; then
    warn "$(t '%s: needs about %s free in %s, only %s is free (HS_DRILL_TMP points the drill to another folder)' "$name" "$(human $((size * 2)))" "$(dirname "$drill_tmp")" "$(human "$avail")")"
    drill_cleanup; return 1
  fi
  step "$(t 'Container restore drill: %s' "$name")"
  R restore "$id" --target "$drill_tmp/restore" >/dev/null || { warn "$(t '%s: the restore itself failed' "$name")"; drill_cleanup; return 1; }
  root=$drill_tmp/restore$INCUS_ROOT/$name/rootfs
  if [ ! -d "$root/etc" ]; then warn "$(t '%s: the snapshot holds no root file system (no etc folder)' "$name")"; drill_cleanup; return 1; fi
  ok "$(t '%s: files restored' "$name")"
  python3 "$CTIMG" build "$root" "$drill_tmp/image.tar.gz" "$name" || { warn "$(t '%s: could not pack the image' "$name")"; drill_cleanup; return 1; }
  rm -rf "$drill_tmp/restore"
  drill_img=$img
  inc image import "$drill_tmp/image.tar.gz" --alias "$img" >/dev/null </dev/null || { warn "$(t '%s: could not import the image' "$name")"; drill_img=""; drill_cleanup; return 1; }
  rm -f "$drill_tmp/image.tar.gz"
  drill_inst=$inst
  # no profiles = no network card, no GPU, no shares, no autostart; only a root disk
  if ! { inc init "$img" "$inst" --no-profiles -c user.hs-drill=1 -c boot.autostart=false </dev/null >/dev/null &&
         inc config device add "$inst" root disk path=/ pool="${HS_DRILL_POOL:-default}" </dev/null >/dev/null; }; then
    warn "$(t '%s: could not create the throwaway instance' "$name")"; drill_cleanup; return 1
  fi
  inc start "$inst" </dev/null >/dev/null || { warn "$(t '%s: the throwaway instance did not start' "$name")"; drill_cleanup; return 1; }
  for ((i = 0; i < wait; i += 2)); do
    inc exec "$inst" -- true </dev/null >/dev/null 2>&1 && break
    sleep 2
  done
  if ! inc exec "$inst" -- true </dev/null >/dev/null 2>&1; then
    warn "$(t '%s: the restored container did not come up within %s s' "$name" "$wait")"; drill_cleanup; return 1
  fi
  ok "$(t '%s: booted, commands run inside it' "$name")"
  # systemd's own verdict (running, or degraded because a service failed without its network); only reported
  for ((i = 0; i < 20; i += 2)); do
    st=$(inc exec "$inst" -- systemctl is-system-running </dev/null 2>/dev/null || true)
    case "$st" in starting|initializing) sleep 2 ;; *) break ;; esac
  done
  [ -z "$st" ] || note "$(t 'systemd says: %s' "$st")"
  drill_cleanup
  ok "$(t '%s: throwaway instance deleted' "$name")"
  return 0
}

# The domain controller is a VM: what restic holds of it is samba's offline backup file. Restore it, list it, unpack it,
# look for sam.ldb. Putting it into a new domain controller stays manual.
drill_dc() {
  inc info "$DC" >/dev/null 2>&1 </dev/null || { note "$(t 'No domain controller %s here, nothing to check' "$DC")"; return 0; }
  local dcfile
  drill_tmp=$(mktemp -d "${HS_DRILL_TMP:-/var/tmp}/hs-drill.XXXXXX") || { warn "Could not make a temporary folder"; return 1; }
  step "$(t 'Domain controller backup file (%s)' "$DC")"
  R restore latest --tag host --target "$drill_tmp/restore" --include "$STATE/backup-dc" >/dev/null 2>&1 || { warn "The restore of the domain backup failed"; drill_cleanup; return 1; }
  dcfile=$drill_tmp/restore$STATE/backup-dc/domain-backup.tar.bz2
  [ -s "$dcfile" ] || { warn "The host backup holds no domain backup file (run hs backup now while the domain controller runs)"; drill_cleanup; return 1; }
  mkdir -p "$drill_tmp/x"
  tar -tjf "$dcfile" 2>/dev/null | grep -q 'sam\.ldb' || { warn "The domain backup does not list a sam.ldb"; drill_cleanup; return 1; }
  tar -xjf "$dcfile" -C "$drill_tmp/x" 2>/dev/null || { warn "The domain backup could not be unpacked"; drill_cleanup; return 1; }
  if [ -z "$(find "$drill_tmp/x" -name 'sam.ldb*' -size +0 -print -quit)" ]; then warn "The unpacked domain backup has no sam.ldb"; drill_cleanup; return 1; fi
  drill_cleanup
  dc_checked=true
  ok "Domain backup: it unpacks and holds sam.ldb"
}

# A virtual machine is in the backup as the file `incus export` wrote (vm_backup). The drill streams it out of restic (no free space needed)
# and lists the tar: it must hold Incus's backup/index.yaml and a disk image. Booting it needs the machine's whole size again, so that stays manual.
drill_vm_one() {   # drill_vm_one <name> <snapshot id> <bytes>
  local name=$1 id=$2 listing
  step "$(t 'Virtual machine restore drill: %s' "$name")"
  listing=$(R dump "$id" "$VMX/$name.tar" 2>/dev/null | tar -t 2>/dev/null) || { warn "$(t '%s: the export file could not be read from the backup' "$name")"; return 1; }
  if ! grep -q 'backup/index.yaml' <<<"$listing"; then warn "$(t '%s: the export file has no index.yaml' "$name")"; return 1; fi
  if ! grep -Eq '\.img$|\.qcow2$' <<<"$listing"; then warn "$(t '%s: the export file holds no disk image' "$name")"; return 1; fi
  ok "$(t '%s: the export file comes out of the backup and lists as an Incus export' "$name")"
}

cmd_drill_ct() {   # hs backup drill ct [<name>]
  local want=${1:-} pick name id size rc=0 vmpick
  [ $# -le 1 ] || usage
  need_repo
  trap 'exit 130' INT TERM
  if [ -n "$want" ] && [ "$want" != "$DC" ]; then vmpick=$(drill_pick "$want" vm); fi
  if [ -z "$want" ]; then
    # the virtual machine drilled longest ago goes along with the container drill (one of each kind per run)
    vmpick=$(drill_pick "" vm)
  fi
  if [ -n "${vmpick:-}" ]; then
    read -r name id size <<<"$vmpick"
    if drill_vm_one "$name" "$id" "$size"; then
      printf '%s %s ok\n' "$name" "$(date +%s)" >> "$CTDRILL"
      note_state "drill_vm_ok=$(date +%s)" "drill_vm_name=$name"
    else
      printf '%s %s failed\n' "$name" "$(date +%s)" >> "$CTDRILL"
      rc=1
    fi
    [ -z "$want" ] || { [ "$rc" -eq 0 ] || die "The virtual machine drill failed (see above)."; ok "Virtual machine restore drill done."; return 0; }
  fi
  if [ "$want" != "$DC" ]; then
    pick=$(drill_pick "$want")
    if [ -z "$pick" ]; then
      [ -z "$want" ] || die "$(t 'No backup of a container called %s (see: hs backup list)' "$want")"
      [ -n "${vmpick:-}" ] || note "No container is in the backup, nothing to restore (hs backup ct <name> on)"
    else
      read -r name id size <<<"$pick"
      if drill_ct_one "$name" "$id" "$size"; then
        printf '%s %s ok\n' "$name" "$(date +%s)" >> "$CTDRILL"
        note_state "drill_ct_ok=$(date +%s)" "drill_ct_name=$name"
      else
        printf '%s %s failed\n' "$name" "$(date +%s)" >> "$CTDRILL"
        rc=1
      fi
    fi
  fi
  drill_dc || rc=1
  ! $dc_checked || note_state "drill_dc_ok=$(date +%s)"
  [ "$rc" -eq 0 ] || die "The container drill failed (see above)."
  ok "Container restore drill done."
}

# ── The monthly report: what the restore drills found, as one push message ──
# The drills (hs backup drill, drill ct) run on the 15th and the 22nd (timers in configuration.nix) and write their results to backup.state;
# on the 25th hs-backup-report sends the picture: when each kind of check last worked, which tries failed in the last 35 days, the age of the
# off-site copy, and how many guides were checked against the server (hs docs verified). It reads the state files only: no restic, no disk.
# Priority "high" and category problem when something is overdue or failed, otherwise a quiet "info". --dry-run prints instead of sending.
# HS_BACKUP_NOTIFY: another program for sending (tests); gets the same arguments as notify.sh.
cmd_report() {
  local scheduled=false now d lines="" problems=0 k v when limit title prio cat msg
  [ "${1:-}" = --scheduled ] && scheduled=true
  if [ ! -f "$PASSFILE" ] && [ "$(pass_state)" != locked ]; then
    $scheduled && return 0
    die "Not set up yet. Run: hs backup init <device>"
  fi
  now=$(date +%s)
  get() { sed -n "s/^$1=//p" "$RESULT" 2>/dev/null | tail -n1 || true; }
  add() { lines+="$1"$'\n'; }
  check_age() {   # check_age <label> <state key> <days allowed> [extra text]
    local label=$1 key=$2 allow=$3 extra=${4:-} stamp days
    stamp=$(get "$key")
    if [[ "$stamp" =~ ^[0-9]+$ ]]; then
      days=$(( (now - stamp) / 86400 ))
      if [ "$days" -gt "$allow" ]; then add "$(t '! %s: %s days ago (more than %s)' "$label" "$days" "$allow")${extra:+ $extra}"; problems=$((problems + 1))
      else add "$(t '%s: %s days ago' "$label" "$days")${extra:+ $extra}"; fi
    else
      add "$(t '! %s: never' "$label")"; problems=$((problems + 1))
    fi
  }
  if [ "$(get status)" = failed ]; then add "$(t '! The last backup failed')"; problems=$((problems + 1)); fi
  check_age "$(t 'Backup')" last_ok 2
  check_age "$(t 'File restore drill')" drill_ok 45
  # the container drill is only expected when containers are in the backup
  if [ -s "$CTS" ] || [ -n "$(get drill_ct_ok)" ]; then
    check_age "$(t 'Container restore drill')" drill_ct_ok 90 "$([ -z "$(get drill_ct_name)" ] || echo "($(get drill_ct_name))")"
  fi
  if [ -n "$(get drill_vm_ok)" ]; then check_age "$(t 'Virtual machine drill')" drill_vm_ok 90 "($(get drill_vm_name))"; fi
  if incus info "$DC" >/dev/null 2>&1 </dev/null || [ -n "$(get drill_dc_ok)" ]; then check_age "$(t 'Domain controller backup file')" drill_dc_ok 90; fi
  if [ -s "$OFFSITE" ]; then check_age "$(t 'Off-site copy')" offsite_ok 3; fi
  # tries that failed lately (the container drills keep a list)
  if [ -s "$CTDRILL" ]; then
    k=$(awk -v lim=$((now - 35 * 86400)) '$3 == "failed" && $2 >= lim { n[$1]++ } END { for (c in n) printf "%s%s", (s++ ? ", " : ""), c }' "$CTDRILL")
    if [ -n "$k" ]; then add "$(t '! Drills that failed in the last 35 days: %s' "$k")"; problems=$((problems + 1)); fi
  fi
  v=$(get used_pct)
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    if [ "$v" -ge 90 ]; then add "$(t '! Backup disk: %s%% full' "$v")"; problems=$((problems + 1)); else add "$(t 'Backup disk: %s%% full' "$v")"; fi
  fi
  # the guides: how many were worked through on the server (no problem: it is information)
  if [ -f "$(dirname "$0")/docs-verified.sh" ]; then
    d=$(bash "$(dirname "$0")/docs-verified.sh" --summary 2>/dev/null || true)
    if [ -n "$d" ]; then
      add "$(t 'Guides checked on the server: %s of %s%s' "$(sed -n 's/^verified=//p' <<<"$d")" "$(sed -n 's/^total=//p' <<<"$d")" \
        "$(w=$(sed -n 's/^oldest=//p' <<<"$d"); [ -z "$w" ] || t ' (the oldest check: %s)' "$w")")"
    fi
  fi
  if [ "$problems" -eq 0 ]; then
    title="$(hostname): $(t 'restore drills are fine')"; prio=low; cat=info
  else
    title="$(hostname): $(t 'restore drills: %s thing(s) to look at' "$problems")"; prio=high; cat=problem
  fi
  msg=${lines%$'\n'}
  if $dry; then
    say "$title ($prio)"
    printf '%s\n' "$msg"
    say "(dry run, nothing sent)"
    return 0
  fi
  line "$title"
  printf '%s\n' "$msg"
  if [ -n "${HS_BACKUP_NOTIFY:-}" ]; then
    "$HS_BACKUP_NOTIFY" --category "$cat" "$title" "$msg" "$prio"
  else
    bash "$(dirname "$0")/notify.sh" --category "$cat" "$title" "$msg" "$prio"
  fi
}

# ── How big is what goes into the backup? (sizes measured overnight, or ZFS) ──
share_bytes() {   # share_bytes <path>
  local path=$1 b
  b=$(awk -F'\t' -v p="$path" '$1 == p { print $2; exit }' "$STATE/share-sizes" 2>/dev/null || true)
  if [[ "$b" =~ ^[0-9]+$ ]]; then echo "$b"; return; fi
  if command -v zfs >/dev/null 2>&1 && [ "$(cat /etc/hs/bulk-type 2>/dev/null || echo zfs)" = zfs ]; then
    b=$(zfs list -Hp -o used "bulk/${path#"$BULK"/}" 2>/dev/null || true)
    if [[ "$b" =~ ^[0-9]+$ ]]; then echo "$b"; return; fi
  fi
  echo "-"
}
included_bytes() {   # prints "bytes unknown-count"
  local kind name total=0 unknown=0 b
  while read -r kind name; do
    [ -n "$name" ] || continue
    is_off "$name" && continue
    b=$(share_bytes "$BULK/$kind/$name")
    if [ "$b" = "-" ]; then unknown=$((unknown + 1)); else total=$((total + b)); fi
  done < <(share_names)
  echo "$total $unknown"
}

cmd_list() {
  need_repo
  step "Snapshots"
  R snapshots --group-by tags --compact | sed 's/^/  /'
}

cmd_find() {
  [ $# -eq 1 ] || usage
  need_repo
  step "$(t "Snapshots that contain '%s'" "$1")"
  R find "*$1*" | sed 's/^/  /'
}

cmd_restore() {
  local snap="" path="" tag=shares to=$BULK/shares/restored
  while [ $# -gt 0 ]; do
    case "$1" in
      --tag) [ $# -ge 2 ] || usage; tag=$2; shift 2 ;;
      --to)  [ $# -ge 2 ] || usage; to=$2; shift 2 ;;
      -*)    usage ;;
      *)     if [ -z "$snap" ]; then snap=$1; elif [ -z "$path" ]; then path=$1; else usage; fi; shift ;;
    esac
  done
  [ -n "$snap" ] && [ -n "$path" ] || usage
  [ -d "$to" ] || die "$(t '%s does not exist. For the default: hs share add restored' "$to")"
  need_repo
  # "latest" means the newest snapshot with that tag (shares, host, ct:<name>)
  R restore "$snap" --tag "$tag" --target "$to" --include "$path"
  # restic is happy to restore nothing when the path is not in the snapshot
  [ -e "$to/${path#/}" ] || die "$(t "Nothing restored: '%s' is not in that snapshot. Use the full original path (for example %s/shares/<share>/<file>); look it up with: hs backup find <name>" "$path" "$BULK")"
  # only what was restored: with --to / (restore in place after a disaster) the target is the whole system
  chown -R adminuser:users "$to/${path#/}" 2>/dev/null || true
  ok "$(t 'Restored into %s (the full original path is recreated below it).' "$to")"
}

cmd_browse() {
  need_repo
  if [ "${1:-}" = --off ]; then
    systemctl stop hs-backup-browse 2>/dev/null || true
    net conf delshare backup-browse 2>/dev/null || true
    mountpoint -q "$BROWSE" && umount "$BROWSE" 2>/dev/null || true
    mounted_by_us=true       # the disk goes back to being unmounted when this call ends
    mountpoint -q "$MNT" || mounted_by_us=false
    ok "Browsing is off."
    return 0
  fi
  mounted_by_us=false      # stays mounted until: hs backup browse --off
  local admins="" admins_sid=""
  if [ "$(testparm -s --parameter-name=security 2>/dev/null)" = "ADS" ]; then
    admins="$(testparm -s --parameter-name=workgroup 2>/dev/null)\Domain Admins"
    admins_sid=$(wbinfo -n "$admins" 2>/dev/null | cut -d" " -f1 || true)
    [ -n "$admins_sid" ] || die "$(t "Can't look up %s (is winbind running?)." "$admins")"
  fi
  mkdir -p "$BROWSE"
  systemctl stop hs-backup-browse 2>/dev/null || true
  # restic looks for "fusermount"; NixOS only has fusermount3, and the service has a bare PATH
  local fuse_bin=/run/hs/fuse-bin fm
  fm=$(command -v fusermount3 || true)
  [ -n "$fm" ] || fm=/run/wrappers/bin/fusermount3
  mkdir -p "$fuse_bin"
  ln -sf "$fm" "$fuse_bin/fusermount"
  ln -sf "$fm" "$fuse_bin/fusermount3"
  systemd-run --quiet --unit=hs-backup-browse --collect \
    --setenv=RESTIC_CACHE_DIR="$RESTIC_CACHE_DIR" \
    --setenv=PATH="$fuse_bin:/run/current-system/sw/bin:/run/wrappers/bin" \
    restic -r "$REPO" --password-file "$PASSFILE" mount "$BROWSE"
  local i
  for i in $(seq 1 30); do mountpoint -q "$BROWSE" && break; sleep 1; done
  mountpoint -q "$BROWSE" || die "Could not mount the backup (journalctl -u hs-backup-browse)."
  if ! net conf listshares | grep -qix backup-browse; then
    net conf addshare backup-browse "$BROWSE" writeable=n guest_ok=n
    net conf setparm backup-browse "force user" root
    [ -z "$admins" ] || sharesec backup-browse --replace "$admins_sid:ALLOWED/0x0/FULL" || true
  fi
  ok "$(t 'Open %s: snapshots/<time>/ ... (read-only, only %s)' "\\\\$(hostname)\\backup-browse" "$admins")"
  note "When you are done: hs backup browse --off"
}

cmd_verify() {
  need_repo
  R check --read-data-subset=10%
}

# Give space back now (the nightly run only does it on Sundays, and a full backup disk cannot even get that far): remove the temporary files a run that
# died of "no space left" leaves in the repository, remove stale locks, apply the retention and prune what no snapshot uses any more.
cmd_prune() {
  need_repo
  local lock=/run/hs-backup.lock
  [ -w /run ] || lock=$STATE/.backup.lock
  exec 9>"$lock"
  flock -n 9 || die "Another backup is running."     # nothing else writes to the repository while this runs
  local free_before tmpn
  free_before=$(df -B1 --output=avail "$MNT" | tail -n1 | tr -d ' ')
  step "$(t 'Space on the backup disk')"
  kv "Free" "$(human "$free_before")"
  tmpn=$(find "$REPO/data" -type f -name '*-tmp-*' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$tmpn" -gt 0 ]; then
    if $dry; then note "$(t '%s leftover temporary file(s) from a run that ran out of space would be deleted' "$tmpn")"
    else
      find "$REPO/data" -type f -name '*-tmp-*' -delete 2>/dev/null || true
      ok "$(t '%s leftover temporary file(s) from a run that ran out of space deleted' "$tmpn")"
    fi
  fi
  # a lock of a process that is gone (restic only removes those); a running backup holds the flock above, so none is
  $dry || clear_locks
  local forget=(--group-by tags --keep-daily 7 --keep-weekly 4 --keep-monthly 6)
  step "$(t 'Retention: 7 daily, 4 weekly, 6 monthly per kind, then prune')"
  [ -t 1 ] || export RESTIC_PROGRESS_FPS=${RESTIC_PROGRESS_FPS:-0.0167}
  if $dry; then
    R forget --dry-run "${forget[@]}" || die "$(t 'Could not work out what to forget.')"
    say "(dry run, nothing changed)"
    return 0
  fi
  R forget "${forget[@]}" --prune || die "$(t 'Pruning failed. Is the disk too full even to prune? Delete a large snapshot with: restic forget <id> (hs backup list shows them), then run this again.')"
  local free_after
  free_after=$(df -B1 --output=avail "$MNT" | tail -n1 | tr -d ' ')
  ok "$(t 'Free space on the backup disk: %s (was %s)' "$(human "$free_after")" "$(human "$free_before")")"
  note_state "pruned=$(date +%s)"
}

# ── Setting up a disk ──
cmd_init() {
  local dev bad pass
  # the password is created inside the vault: with a closed vault nothing is asked and nothing is erased
  if vault_configured && ! vault_is_open && [ ! -e "$PASSFILE" ]; then secret_locked_exit; fi
  [ "$(pass_state)" != locked ] || secret_locked_exit
  if [ $# -eq 0 ]; then
    # no device given: offer the free disks (the same list hs pool bulk uses), nothing is erased yet
    local list line id size kind rest options=() picked
    list=$(bash "${HS_MANAGE_POOL:-$(dirname "$0")/manage-pool.sh}" --list-disks 2>/dev/null || true)
    while IFS=$'\t' read -r id size kind rest; do
      [ -n "$id" ] || continue
      options+=("$id  $(numfmt --to=si "$size")B  $kind  $rest")
    done <<<"$list"
    [ ${#options[@]} -gt 0 ] || die "No free disk found. Plug it in, or give the device: hs backup init /dev/sdX"
    picked=$(choose "Which disk becomes the backup disk? (it is erased in the next step)" "${options[@]}") || die "cancelled"
    dev="/dev/disk/by-id/${picked%% *}"
  elif [ $# -eq 1 ]; then
    dev=$1
  else
    usage
  fi
  [ -b "$dev" ] || die "$(t '%s is not a block device' "$dev")"
  # Never touch a disk that is in use or belongs to a pool
  bad=$(lsblk -J -o PATH,FSTYPE,LABEL,MOUNTPOINTS "$dev" | jq -r '
    [.blockdevices[] | recurse(.children[]?)]
    | map(select(((.mountpoints // [] | map(select(. != null)) | length) > 0)
                 or ((.fstype // "") | test("^(zfs_member|linux_raid_member|swap|LVM2_member)$"))
                 or ((.label // "") | test("^bulk-(data|parity)-"))))
    | map(.path) | join(" ")')
  [ -z "$bad" ] || die "$(t 'Refusing: %s is mounted, swap, or part of a pool.' "$bad")"
  step "Backup disk"
  kv "Disk" "$dev ($(lsblk -dno SIZE,MODEL "$dev"))"
  lsblk -no PATH,FSTYPE,LABEL "$dev" | sed 's/^/      /'
  danger "$(t "This ERASES everything on %s and makes it the backup disk (ext4, label 'backup')." "$dev")"
  if $dry; then note "(dry run, nothing changed)"; return 0; fi
  if [ -z "${HS_BACKUP_YES:-}" ]; then
    confirm_name "$(basename "$(readlink -f "$dev")")" "the disk" || die "cancelled"
  fi
  wipefs -a "$dev" >/dev/null
  mkfs.ext4 -q -m 1 -L backup "$dev"
  udevadm settle 2>/dev/null || true
  DEV=$dev
  mount_disk
  mkdir -p "$STATE"
  if [ ! -f "$PASSFILE" ]; then
    secret_prepare restic-password "$STATE" || exit 1   # with a vault: created inside it, linked at the old path
    ( umask 077; head -c 24 /dev/urandom | base64 > "$PASSFILE" )
    if [ "${HS_CALLER:-}" = job ]; then
      # a job's output goes to the journal: the password is not printed there, only where to read it
      warn "$(t 'The backup password is in %s (root only). Read it once with: sudo cat %s, and SAVE IT in your password manager: without it a backup cannot be opened.' "$PASSFILE" "$PASSFILE")"
    else
      pass=$(cat "$PASSFILE")
      box <<TEXT
Backup password (also in $PASSFILE, root only):

    $pass

SAVE IT IN YOUR PASSWORD MANAGER NOW. Without it a backup can't be opened,
also not after the OS disk dies.
TEXT
    fi
  else
    note "$(t 'Using the existing backup password (%s).' "$PASSFILE")"
  fi
  R init >/dev/null
  # Game server backups are backups already; "restored" is where restores land
  if [ ! -f "$OFF" ]; then printf '%s\n' pelican-backups restored > "$OFF"; fi
  note_state "status=new"
  ok "Backup disk ready. First run: hs backup now   (then nightly at 04:00)"
}

# ── Machine-readable modes for the web interface (Backup page) ──
# --state: key<TAB>value, never mounts the disk and never fails (before init: configured=no).
# Everything comes from the last run (backup.state); snapshots/repo_size are shown once cmd_now records them.
cmd_state_kv() {
  local v
  get() { sed -n "s/^$1=//p" "$RESULT" 2>/dev/null | tail -n1 || true; }
  printf 'configured\t%s\n' "$(set_up && echo yes || echo no)"
  if [ "$(pass_state)" = locked ]; then printf 'vault\tclosed\n'; fi   # an unknown key: the interface ignores it
  printf 'last_ok\t%s\n' "$(get last_ok)"
  printf 'last_try\t%s\n' "$(get last_try)"
  v=$(get status); printf 'status\t%s\n' "${v:-empty}"
  printf 'used_pct\t%s\n' "$(get used_pct)"
  printf 'snapshots\t%s\n' "$(get snapshots)"
  printf 'repo_size\t%s\n' "$(get repo_size)"
  if [ -n "${HS_BACKUP_NO_MOUNT:-}" ] || [ -b "$DEV" ] || mountpoint -q "$MNT" 2>/dev/null; then
    printf 'disk\tpresent\n'
  else
    printf 'disk\tabsent\n'
  fi
  if mountpoint -q "$BROWSE" 2>/dev/null; then printf 'browse\ton\n'; else printf 'browse\toff\n'; fi
  printf 'offsite\t%s\n' "$(cat "$OFFSITE" 2>/dev/null || true)"
  printf 'offsite_ok\t%s\n' "$(get offsite_ok)"
  printf 'last_drill\t%s\n' "$(get last_drill)"
  printf 'drill_ok\t%s\n' "$(get drill_ok)"
  printf 'drill_ct_ok\t%s\n' "$(get drill_ct_ok)"
  printf 'drill_ct_name\t%s\n' "$(get drill_ct_name)"
  v=$(systemctl show hs-backup.timer -p NextElapseUSecRealtime --value 2>/dev/null || true)
  printf 'next\t%s\n' "$([ -n "$v" ] && date -d "$v" +%s 2>/dev/null || true)"
  # appended last: readers go by key and ignore keys they do not know
  printf 'used_bytes\t%s\n' "$(get used_bytes)"
  printf 'size_bytes\t%s\n' "$(get size_bytes)"
}

# --overview: kind<TAB>name<TAB>on|off<TAB>bytes or -  (kind = shares | sensitive | ct | always)
cmd_overview_kv() {
  local kind name state b
  while read -r kind name; do
    [ -n "$name" ] || continue
    if is_off "$name"; then state=off; else state=on; fi
    printf '%s\t%s\t%s\t%s\n' "$kind" "$name" "$state" "$(share_bytes "$BULK/$kind/$name")"
  done < <(share_names)
  if [ -f "$CTS" ]; then
    while read -r name; do
      if [ -n "$name" ]; then printf 'ct\t%s\ton\t-\n' "$name"; fi
    done < "$CTS"
  fi
  printf 'always\tdomain controller\ton\t-\nalways\thost files\ton\t-\n'
}

# --shares: kind<TAB>name<TAB>on|off  (kind = share | ct | always)
cmd_shares_kv() {
  local kind name
  while read -r kind name; do
    [ -n "$name" ] || continue
    if is_off "$name"; then printf 'share\t%s\toff\n' "$name"; else printf 'share\t%s\ton\n' "$name"; fi
  done < <(share_names)
  if [ -f "$CTS" ]; then
    while read -r name; do
      if [ -n "$name" ]; then printf 'ct\t%s\ton\n' "$name"; fi
    done < "$CTS"
  fi
  printf 'always\tdomain controller %s\ton\n' "$DC"
  printf 'always\thost files\ton\n'
}

# The snapshots of the shares, oldest first, for the interface: id, time (UTC), tags. Mounts the backup disk while it reads.
cmd_snapshots_kv() {
  local tag=${1:-shares}
  [[ "$tag" =~ ^(shares|host|ct:[A-Za-z0-9._-]+)$ ]] || die "unknown tag (shares, host or ct:<name>)"
  need_repo
  R snapshots --tag "$tag" --json | jq -r 'sort_by(.time) | .[] | [.short_id, (.time[0:16] | sub("T"; " ")), (.tags | join(","))] | @tsv'
}

# Files whose name contains a word, in every snapshot, for the interface: snapshot id, time (UTC), path, type, bytes. At most 200 rows.
# Mounts the backup disk while it reads; can take a while on a big repository.
cmd_find_kv() {
  [ $# -eq 1 ] && [ -n "$1" ] || die "usage: hs sys backup find <word>"
  [[ "$1" != *[[:cntrl:]]* ]] || die "the word has a control character"
  need_repo
  local snaps
  snaps=$(R snapshots --json)
  R find --json "*$1*" | jq -r --argjson s "$snaps" '($s | map({(.id): .time[0:16]}) | add // {}) as $t
    | .[] | .snapshot as $id | .matches[] | [$id[0:8], (($t[$id] // "") | sub("T"; " ")), .path, .type, (.size // 0)] | @tsv' | awk 'NR <= 200'
}

case "$cmd" in
  --find)  cmd_find_kv "$@" ;;
  --snapshots) cmd_snapshots_kv "$@" ;;
  --overview)  cmd_overview_kv ;;
  --state)  cmd_state_kv ;;
  --shares) cmd_shares_kv ;;
  status)  cmd_status ;;
  now)     cmd_now "$@" ;;
  list)    cmd_list ;;
  find)    cmd_find "$@" ;;
  restore) cmd_restore "$@" ;;
  browse)  cmd_browse "$@" ;;
  verify)  cmd_verify ;;
  prune)   cmd_prune ;;
  report)  cmd_report "$@" ;;
  drill)  cmd_drill "$@" ;;
  offsite) cmd_offsite "$@" ;;
  init)    cmd_init "$@" ;;
  ct)      [ $# -eq 2 ] || usage; cmd_toggle_ct "$@" ;;
  *)
    # hs backup <share> on|off
    if [ $# -eq 1 ] && { [ "$1" = on ] || [ "$1" = off ]; }; then
      cmd_toggle_share "$cmd" "$1"
    else
      usage
    fi ;;
esac
