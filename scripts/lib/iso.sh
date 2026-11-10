# shellcheck shell=bash
# The ISO library (issue #259, epic #199): install images for virtual machines, one folder, one small
# `<name>.iso.meta` file next to each image. Sourced by iso.sh, iso-change.sh and ct-change.sh.
#
#   iso_dir                 the library folder: HS_ISO_DIR (tests), the runtime setting isoDir, else /var/lib/hs/iso
#   iso_meta <file> <key>   one value of a meta file (algo, hash, verified, source, added), empty when missing
#   iso_names               the names of the images in the library, one per line (only finished `*.iso` files)
#   iso_valid_name <name>   0 when it is a plain file name that ends in .iso
#   iso_used_by <name>      the instances that have the image attached, comma separated, `-` when none (HS_INCUS, needs jq)

iso_dir() {
  local d=${HS_ISO_DIR:-}
  if [ -z "$d" ]; then
    # shellcheck source=scripts/lib/setting.sh
    . "${BASH_SOURCE[0]%/*}/setting.sh"
    d=$(setting_get isoDir 2>/dev/null) || d=
  fi
  printf '%s\n' "${d:-/var/lib/hs/iso}"
}

iso_meta() { [ -r "$1" ] && awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$1" || true; }

iso_valid_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,80}\.[iI][sS][oO]$ ]]; }

iso_names() {
  local d f
  d=$(iso_dir)
  for f in "$d"/*.[iI][sS][oO]; do [ -f "$f" ] && basename "$f"; done
  return 0
}

iso_used_by() {
  local path out
  path="$(iso_dir)/$1"
  command -v jq >/dev/null 2>&1 || { echo "-"; return 0; }
  out=$("${HS_INCUS:-incus}" query '/1.0/instances?recursion=2' 2>/dev/null \
    | jq -r --arg p "$path" '[.[] | select([.devices[]? | select(.type == "disk" and .source == $p)] | length > 0) | .name] | join(",")' 2>/dev/null) || out=
  echo "${out:--}"
}
