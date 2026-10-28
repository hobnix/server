#!/usr/bin/env bash
# help: create a folder under /bulk/shares (read/write) or /bulk/sensitive (read-only), published as its own Samba share
# help.de: legt einen Ordner unter /bulk/shares (lesen/schreiben) oder /bulk/sensitive (nur lesen) an, als eigene Samba-Freigabe veröffentlicht
# args: <name> [--sensitive] [--ct <container> <path>] [--as <uid>:<gid>]
set -euo pipefail
. "$(dirname "$0")/lib/ui.sh"

usage() {
  say "usage: hs share add <name> [--sensitive] [--ct <container> <path>]"
  say "  --sensitive  put it under /bulk/sensitive (Samba: read-only)"
  say "  --ct         also mount it into a container at <path>"
  say "  --as         with --ct: the user and group inside the container that should be able"
  say "               to write (numbers; hs ct list shows them). Default: user 1000, group 100"
  exit 1
}

# a container can have one 1:1 mapped user only: say which one is in the way
idmap_conflict() {   # idmap_conflict <current raw.idmap>
  warn "$(t "'%s' already maps a different user to the share owner:" "$ct")"
  local l
  while IFS= read -r l; do note "$l"; done <<<"$1"
  note "Only one user per container can write to shares. Use that one, or remove the mapping:"
  note "  incus config unset $ct raw.idmap"
  exit 1
}

[ $# -ge 1 ] || usage
name="$1"; shift
parent="shares"
ct=""; ctpath=""
as_uid=""; as_gid=""

while [ $# -gt 0 ]; do
  case "$1" in
    --sensitive) parent="sensitive"; shift ;;
    --ct)        [ $# -ge 3 ] || usage; ct="$2"; ctpath="$3"; shift 3 ;;
    --as)        [ $# -ge 2 ] || usage
                 [[ "$2" =~ ^[0-9]+:[0-9]+$ ]] || usage
                 as_uid="${2%%:*}"; as_gid="${2##*:}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "$(t "invalid name '%s'" "$name")"

# "zfs": one dataset per share. "snapraid": a plain folder on the merged disks.
bulk_type=$(cat "${HS_BULK_TYPE_FILE:-/etc/hs/bulk-type}" 2>/dev/null || echo zfs)
dir="/bulk/$parent/$name"

# Check everything that can refuse the mount before creating anything, so a
# refused request leaves no empty share behind.
if [ -n "$ct" ]; then
  incus info "$ct" >/dev/null 2>&1 || fail "$(t "'%s' does not exist." "$ct")"
  if incus config device get "$ct" "$name" type >/dev/null 2>&1; then
    fail "$(t "'%s' already has a device called '%s'." "$ct" "$name")"
  fi
  # shares are written through a 1:1 user mapping (see map_user below); a
  # container can have only one such user
  if [ "$parent" = shares ] && { [ -n "$as_uid" ] || [ "$bulk_type" = snapraid ]; }; then
    want=$(printf 'uid 1000 %s\ngid 100 %s' "${as_uid:-1000}" "${as_gid:-100}")
    have=$(incus config get "$ct" raw.idmap)
    if [ -n "$have" ] && [ "$have" != "$want" ]; then
      idmap_conflict "$have"
    fi
  fi
fi

if [ "$bulk_type" = snapraid ]; then
  mountpoint -q /bulk || fail "/bulk is not mounted. Add disks first: hs pool bulk add"
  mkdir -p "$dir"
else
  # -p also creates bulk/sensitive the first time it's needed
  zfs create -p "bulk/$parent/$name"
fi

# Samba acts as adminuser on /bulk/shares; setgid keeps the group on new files.
# Sensitive folders stay root-owned, the container sets its own permissions.
if [ "$parent" = shares ]; then
  chown adminuser:users "$dir"
  chmod 2775 "$dir"
fi

# The host id a user of the container has: where its files end up owned on disk.
host_id() {   # host_id <uid|gid> <number>
  incus config get "$ct" volatile.idmap.current | jq -r --argjson n "$2" --arg kind "$1" '
    [ .[] | select((if $kind == "uid" then .Isuid else .Isgid end) and .Nsid <= $n and $n < .Nsid + .Maprange) ][0]
    | if . == null then empty else .Hostid + ($n - .Nsid) end'
}

# Make one user of the container the same as the share owner on the server
# (adminuser:users), so what the app writes stays editable from Windows.
# Works on every filesystem, unlike id-shifted mounts.
map_user() {   # map_user <uid> <gid>
  local want
  want=$(printf 'uid 1000 %s\ngid 100 %s' "$1" "$2")
  local have
  have=$(incus config get "$ct" raw.idmap)
  if [ "$have" = "$want" ]; then return; fi
  if [ -n "$have" ]; then
    idmap_conflict "$have"
  fi
  printf '%s\n' "$want" | incus config set "$ct" raw.idmap -
  after=$(t "Restart the container (incus restart %s). Inside it, user %s / group %s can write to %s." "$ct" "$1" "$2" "$ctpath")
}

after=""
if [ -n "$ct" ]; then
  if [ "$parent" = shares ]; then
    if [ -n "$as_uid" ]; then
      map_user "$as_uid" "$as_gid"
      incus config device add "$ct" "$name" disk source="$dir" path="$ctpath"
    elif [ "$bulk_type" = snapraid ]; then
      # The merged filesystem can't shift ids: default to user 1000 / group 100
      map_user 1000 100
      incus config device add "$ct" "$name" disk source="$dir" path="$ctpath"
    else
      # ZFS supports id-shifted mounts: root in the container is root on disk
      incus config device add "$ct" "$name" disk source="$dir" path="$ctpath" shift=true
    fi
  else
    # Container-managed data: hand the folder to the user that writes it
    uid=${as_uid:-0}; gid=${as_gid:-0}
    if [ "$bulk_type" = snapraid ]; then
      huid=$(host_id uid "$uid"); hgid=$(host_id gid "$gid")
      [ -n "$huid" ] && [ -n "$hgid" ] || fail "$(t "Can't read the id mapping of '%s' (start it once first)." "$ct")"
      chown "$huid:$hgid" "$dir"
      incus config device add "$ct" "$name" disk source="$dir" path="$ctpath"
    else
      chown "$uid:$gid" "$dir"
      incus config device add "$ct" "$name" disk source="$dir" path="$ctpath" shift=true
    fi
  fi
fi

ok "$(t "%s created" "$dir")${ct:+$(t ", mounted in %s at %s" "$ct" "$ctpath")}"
[ -z "$after" ] || note "$after"

# Publish it as its own Samba share, so access can be set per user
bash "$(dirname "$0")/sync-shares.sh"
