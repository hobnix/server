#!/usr/bin/env bash
# help: set the error recovery time (ERC/TLER, 7 s) on disks that are members of a ZFS mirror or raidz (runs at boot; needs root)
# help.de: setzt die Fehlerbehebungszeit (ERC/TLER, 7 s) auf Platten, die in einem ZFS-Mirror oder RAIDZ sind (läuft beim Start; braucht root)
# args: apply | list
# A disk that retries a bad sector for minutes makes ZFS wait and can drop out of a redundant vdev; ERC makes it give up after 7 seconds so
# ZFS repairs the sector from the other copy. The setting is lost at a power cycle, so a boot unit sets it again.
# ONLY members of a mirror or raidz vdev get it (docs/PLAN-disk-health.md Part 3, decision 5): single disks, SnapRAID data and parity disks
# keep the default (there the long retry is the only chance to read the sector). A disk without SCT ERC support is skipped with a note.
# list: the member disks, one name per line (plain). Test knobs: HS_ERC_STATUS (file with `zpool status -LP` output).
set -uo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"

usage() { say "usage: hs disk erc [apply|list]"; exit 1; }
mode=${1:-apply}
case "$mode" in apply|list) ;; *) usage ;; esac

[ "$mode" = list ] || [ "$(id -u)" = 0 ] || [ -n "${HS_ERC_NOROOT:-}" ] || fail "$(t 'Setting the error recovery time needs root. Run it as: sudo hs disk erc')"

zstatus() {
  if [ -n "${HS_ERC_STATUS:-}" ]; then cat "$HS_ERC_STATUS"; else zpool status -LP 2>/dev/null || true; fi
}

# the devices under mirror-N / raidzN-N vdevs (indent 4 is a top vdev, indent 6 its disks), as whole-disk names
members() {
  zstatus | awk '
    /^config:/ { cfg = 1; next }
    /^errors:/ { cfg = 0 }
    !cfg { next }
    { sub(/^\t/, "  "); match($0, /^ */); ind = RLENGTH; tok = $1 }
    ind <= 2 { inm = 0; next }
    ind == 4 { inm = (tok ~ /^(mirror|raidz[123]?)-[0-9]+$/); next }
    ind == 6 && inm && tok ~ /^\/dev\// && $2 ~ /^(ONLINE|DEGRADED)$/ { print tok }   # a REMOVED/FAULTED member may be a stale path
  ' | while read -r p; do
    parent=$(lsblk -no PKNAME "$p" 2>/dev/null | awk 'NR == 1' || true)
    if [ -n "$parent" ]; then echo "$parent"; else basename "$p"; fi
  done | sort -u
}

disks=$(members)
if [ "$mode" = list ]; then [ -z "$disks" ] || printf '%s\n' "$disks"; exit 0; fi

if [ -z "$disks" ]; then
  note "$(t 'No disk is in a ZFS mirror or raidz: nothing to set.')"
  exit 0
fi
command -v smartctl >/dev/null || fail "smartctl is not installed (package smartmontools)."
step "$(t 'Error recovery time (ERC) of the mirror and raidz members')"
while read -r d; do
  [ -n "$d" ] || continue
  out=$(smartctl -l scterc,70,70 "/dev/$d" 2>&1 || true)
  if grep -qi 'SCT Error Recovery Control set to' <<<"$out"; then ok "$(t '%s: error recovery time set to 7 seconds' "$d")"
  else note "$(t '%s: no ERC support (SATA SCT), skipped' "$d")"; fi
done <<<"$disks"
