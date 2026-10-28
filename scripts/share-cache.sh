#!/usr/bin/env bash
# help: (snapraid layout) upload cache on the SSD pool: uploads land there first and are moved to the disks before each parity sync
# help.de: (Bauart snapraid) Upload-Cache auf dem SSD-Pool: Uploads landen zuerst dort und gehen vor jeder Paritäts-Synchronisation auf die Platten
# args: [status] | <share> on|off [--restart] [--dry-run] | size <N>G
set -euo pipefail

# Why: on the snapraid layout a new file is unprotected until the next parity
# sync. With the cache on, uploads to that share sit on the mirrored SSD pool
# until `hs cache-mover` moves them to the data disks right before a sync.
# It does not make uploads faster than the network already allows.
#
# Used by the interfaces:
#   --state <share>      on | off | emptying | unsupported, then the bytes waiting (tab separated)
here=$(dirname "$0")
. "$here/lib/ui.sh"
cache=/mnt/bulk/cache      # ZFS dataset fast/hs-cache; its quota is the size of the cache
dataset=fast/hs-cache
default_size=200G

usage() {
  say "usage: hs share <share> cache on|off     switch the upload cache of one share"
  printf '%s\n' "$(t '       hs share <share> cache size <N>G          how much of the SSD pool the cache may use (default %s)' "$default_size")"
  say "       --restart with on/off restarts the containers that have the share mounted"
  say "       --dry-run with on/off only shows what would happen"
  exit 1
}

dry=false
restart=false
args=()
for a in "$@"; do
  case "$a" in
    --dry-run) dry=true ;;
    --restart) restart=true ;;
    *)         args+=("$a") ;;
  esac
done
set -- "${args[@]}"

supported() { [ "$(cat "${HS_BULK_TYPE_FILE:-/etc/hs/bulk-type}" 2>/dev/null || echo zfs)" = snapraid ]; }

# "shares/fotos" for a share name (or for its folder)
rel_of() {
  local path
  case "$1" in
    /bulk/*) path=$1 ;;
    *) path=$(net conf getparm "$1" path 2>/dev/null || true)
       if [ -z "$path" ]; then
         for k in shares sensitive; do
           if [ -d "/bulk/$k/$1" ]; then path="/bulk/$k/$1"; break; fi
         done
       fi ;;
  esac
  [[ "${path:-}" =~ ^/bulk/(shares|sensitive)/[^/]+$ ]] || return 1
  echo "${path#/bulk/}"
}

state_of() {   # state_of <rel>
  if [ -e "$cache/$1.off" ]; then echo emptying
  elif [ -d "$cache/$1" ]; then echo on
  else echo off; fi
}

waiting_bytes() { du -sb "$cache/$1" 2>/dev/null | cut -f1 || echo 0; }

# running instances that have this share mounted: they keep the view they
# started with, so they only see files in the cache after a restart
users_of() {
  incus list -f json 2>/dev/null | jq -r --arg p "/bulk/$1" \
    '.[] | select(.status == "Running")
         | select([.expanded_devices[]? | select(.type == "disk" and .source == $p)] | length > 0) | .name'
}
restart_users() {
  local u
  for u in $users; do
    note "$(t 'restarting %s ...' "$u")"
    incus restart "$u" </dev/null || warn "$(t 'could not restart %s, do it by hand' "$u")"
  done
}

human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1"; }

case "${1:-status}" in
  --state)
    [ $# -eq 2 ] || usage
    if ! supported; then printf 'unsupported\t0\n'; exit 0; fi
    rel=$(rel_of "$2") || { printf 'unsupported\t0\n'; exit 0; }
    s=$(state_of "$rel")
    printf '%s\t%s\n' "$s" "$([ "$s" = off ] && echo 0 || waiting_bytes "$rel")"
    exit 0 ;;

  status)
    supported || { warn 'The upload cache exists only on the snapraid layout (bulkType = "snapraid").'; exit 0; }
    step "Upload cache"
    if mountpoint -q "$cache"; then
      note "$(df -h --output=size,used,pcent "$cache" | tail -n1 | { read -r size used pcent; t 'On the SSD pool: %s used of %s (%s)' "$used" "$size" "$pcent"; })"
    else
      note "$(t "Not created yet (the first 'on' creates it, %s)." "$default_size")"
    fi
    rows=""
    for c in "$cache"/shares/*/ "$cache"/sensitive/*/; do
      [ -d "$c" ] || continue
      rel=${c#"$cache"/}; rel=${rel%/}
      rows+=$(printf '%s	%s	%s' "${rel##*/}" "$(human "$(waiting_bytes "$rel")")" "$(state_of "$rel")")$'
'
    done
    if [ -n "$rows" ]; then { thead 'Share' 'Waiting' 'State'; printf '%s' "$rows"; } | table; else line "No share uses the cache"; fi
    exit 0 ;;

  size)
    [ $# -eq 2 ] && [[ "$2" =~ ^[0-9]+[GT]$ ]] || usage
    supported || fail "Only on the snapraid layout."
    zfs list -H "$dataset" >/dev/null 2>&1 || zfs create -o mountpoint="$cache" -o quota="$2" "$dataset"
    zfs set quota="$2" "$dataset"
    ok "$(t 'The cache may now use %s of the SSD pool.' "$2")"
    exit 0 ;;
esac

[ $# -eq 2 ] || usage
share="$1"; want="$2"
[ "$want" = on ] || [ "$want" = off ] || usage
supported || fail "The upload cache exists only on the snapraid layout. With /bulk on ZFS every file is protected the moment it is written."
rel=$(rel_of "$share") || fail "$(t "No share called '%s' under /bulk/shares or /bulk/sensitive." "$share")"
[ -d "/bulk/$rel" ] || fail "$(t '/bulk/%s does not exist.' "$rel")"
share=${rel##*/}
now=$(state_of "$rel")
users=$(users_of "$rel" | tr '\n' ' ' || true)

if [ "$want" = on ]; then
  [ "$now" != on ] || { ok "$(t "'%s' already uses the cache." "$share")"; exit 0; }
  step "$(t "Switch the upload cache of '%s' on" "$share")"
  zfs list -H "$dataset" >/dev/null 2>&1 || mountpoint -q "$cache" ||
    note "$(t 'create the cache on the SSD pool: zfs create -o quota=%s %s' "$default_size" "$dataset")"
  note "$(t 'new files in /bulk/%s land on the SSDs first' "$rel")"
  note "they are moved to the data disks before each parity sync (and when the cache fills up)"
  note "Windows reconnects to the share on its own"
  if [ -n "$users" ]; then
    if $restart; then note "$(t 'restart, so they see files that are still in the cache: %s' "$users")"
    else warn "$(t 'restart needed, or they will not see files that are still in the cache: %s' "$users")"; fi
  fi
  $dry && exit 0

  if ! mountpoint -q "$cache"; then
    if zfs list -H "$dataset" >/dev/null 2>&1; then zfs mount "$dataset"
    else zfs create -o mountpoint="$cache" -o quota="$default_size" "$dataset"; fi
  fi
  rm -f "$cache/$rel.off"
  mkdir -p "$cache/$rel"
  bash "$here/bulk-mount.sh" >/dev/null
  mountpoint -q "/bulk/$rel" || { rmdir "$cache/$rel" 2>/dev/null || true; fail "$(t 'The cache could not be mounted over /bulk/%s.' "$rel")"; }
  smbcontrol smbd close-share "${rel##*/}" 2>/dev/null || true
  if $restart; then restart_users; fi
  ok "Done."
  $restart || [ -z "$users" ] || warn "$(t 'Now restart: %s (hs ct <ct> restart)' "$users")"
  exit 0
fi

# off
[ "$now" != off ] || { ok "$(t "'%s' does not use the cache." "$share")"; exit 0; }
step "$(t "Switch the upload cache of '%s' off" "$share")"
note "new files go straight to the data disks from now on"
note "$(t 'what is still in the cache (%s) is moved to the disks now; files in use follow later' "$(human "$(waiting_bytes "$rel")")")"
if $restart && [ -n "$users" ]; then note "$(t 'restart: %s' "$users")"; fi
$dry && exit 0

touch "$cache/$rel.off"                  # survives a reboot: stays "emptying" until the cache folder is empty
bash "$here/bulk-mount.sh" >/dev/null    # the cache layer takes no new files from here on
bash "$here/cache-mover.sh" "${rel##*/}" --now --no-sync || true
if $restart; then restart_users; fi
if [ "$(state_of "$rel")" = off ]; then
  ok "Done. The moved files get parity with the next sync (three times a day, or now: hs pool bulk sync)."
else
  warn "Some files are still open and stay in the cache for now. The mover finishes this on its next run."
fi
