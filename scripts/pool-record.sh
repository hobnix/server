#!/usr/bin/env bash
# help: write the `pools` line of machine.toml from the pools this server already has (offered, never automatic)
# help.de: die Zeile `pools` in machine.toml aus den Pools schreiben, die dieser Server schon hat (wird angeboten, nie automatisch)
# args: [--dry-run|--list] [--yes]
# Reads what exists (zpool list, the Incus storage pool "default", the SnapRAID layout) and shows the rows it would write; after the typed word
# `pools` it writes ONE line with machine_set. No disk is touched; the next `hs rebuild` reads the rows. Refuses when machine.toml already has a
# `pools` line, when a detected name breaks the pool name rule, and without a terminal unless --yes.
# --dry-run / --list: only the line `pools = { ... }`, plain, changes nothing (machine readable).
# Test knobs: HS_ZPOOL, HS_INCUS, HS_LSBLK, HS_GUIDED_TTY=1 (there is a terminal; answers on stdin), and those of lib/pools.sh.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/ui.sh
. "$here/lib/ui.sh"
# shellcheck source=scripts/lib/pools.sh
. "$here/lib/pools.sh"
# shellcheck source=scripts/lib/effect.sh
. "$here/lib/effect.sh"

zpool=${HS_ZPOOL:-zpool}
incus=${HS_INCUS:-incus}
lsblk=${HS_LSBLK:-lsblk}
interactive() { [ -t 0 ] && [ -t 1 ] && [ -z "${HS_CALLER:-}" ] || [ -n "${HS_GUIDED_TTY:-}" ]; }

dry=false yes=false
for a in "$@"; do
  case "$a" in
    --dry-run|--list) dry=true ;;
    --yes) yes=true ;;
    *) say "usage: hs pool record [--dry-run|--list] [--yes]"; exit 1 ;;
  esac
done

if machine_has pools; then
  $dry && exit 0
  note "machine.toml already has a pools line. Nothing was changed."
  exit 0
fi

# the SnapRAID row keeps the name of the legacy data row (no pools line here, so pools.sh answers with the legacy rows)
snap_name=$(pool_names data | head -n1)

rows=()      # name<TAB>role<TAB>kind
skipped=()   # name<TAB>reason
apps_src=$("$incus" storage get default source 2>/dev/null || true)
zfs_names=$("$zpool" list -H -o name 2>/dev/null || true)
while IFS= read -r name; do
  name=${name%$'\r'}
  [ -n "$name" ] || continue
  if ! pool_name_ok "$name"; then
    skipped+=("$name"$'\t'"not an allowed pool name (a lower case letter, then up to 11 letters or digits)")
    continue
  fi
  role=data
  case "$apps_src" in "$name"/*) role=apps ;; esac
  rows+=("$name"$'\t'"$role"$'\t'zfs)
done <<<"$zfs_names"

snap=false
f=${HS_BULK_TYPE_FILE:-/etc/hs/bulk-type}
if [ -r "$f" ] && [ "$(head -n1 "$f" | tr -d '[:space:]')" = snapraid ]; then snap=true; fi
$snap || { "$lsblk" -nr -o LABEL 2>/dev/null | grep -q '^bulk-' && snap=true; } || true
if $snap; then
  if grep -qx "$snap_name" <<<"$zfs_names"; then
    skipped+=("$snap_name"$'\t'"a ZFS pool has the name of the SnapRAID pool")
  else
    rows+=("$snap_name"$'\t'data$'\t'snapraid)
  fi
fi

if [ "${#skipped[@]}" -gt 0 ]; then
  $dry && exit 1
  warn "Some pools cannot be recorded:"
  { thead "Pool" "Why"; printf '%s\n' "${skipped[@]}"; } | table
  fail "Nothing was written. Rename the pool, then run hs pool record again."
fi
if [ "${#rows[@]}" -eq 0 ]; then
  $dry && exit 0
  note "No pool found on this server. Nothing was changed."
  exit 0
fi

mapfile -t rows < <(printf '%s\n' "${rows[@]}" | sort)
inner=
for r in "${rows[@]}"; do
  IFS=$'\t' read -r n ro k <<<"$r"
  inner+="${inner:+, }$n = { role = \"$ro\", kind = \"$k\" }"
done
value="{ $inner }"
line="pools = $value"

if $dry; then printf '%s\n' "$line"; exit 0; fi

step "The pools of this server"
{ thead "Pool" "Role" "Kind"; printf '%s\n' "${rows[@]}"; } | table
kv "Line" "$line"
note "Only machine.toml changes: no disk is touched."
effect_say rebuild
note "When they equal the rows a server without a pools line has anyway, the server does not behave differently."

if ! $yes; then
  interactive || fail "This needs a terminal (or --yes). Nothing was changed."
  confirm_name pools "the pools setting" || fail "cancelled"
fi

machine_set pools "$value" pool-record >/dev/null
ok "The pools line is written to machine.toml."
next_step "hs rebuild"
