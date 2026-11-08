#!/usr/bin/env bash
# help: the ISO library: install images for virtual machines, added from a local file or a URL, checked with a checksum
# help.de: die ISO-Bibliothek: Installationsabbilder für virtuelle Maschinen, aus einer lokalen Datei oder einer URL, mit Prüfsumme geprüft
# args: [list] | add <file-or-url> [--name <name.iso>] (--checksum <sha256|sha512> | --no-checksum) | remove <name> | --list | --dir
# The images live in one folder (the setting isoDir, default /var/lib/hs/iso); next to each `<name>.iso` is `<name>.iso.meta` with the
# checksum, whether it was checked against a given one, where it came from and when. `add` runs as a background job (a download or a copy of
# some GB): the file is verified before it appears in the library, a wrong checksum deletes it and fails the job with both checksums.
# --list = name TAB bytes TAB algo TAB checksum TAB verified (yes|no) TAB source TAB added TAB used by (instances or -); machine readable.
# --dir = the folder. The work is iso-change.sh's (hs sys iso plan|start); this script is the console side of it.
# Test knobs: HS_ISO_DIR, HS_INCUS, HS_ISO_CHANGE (stand-in for iso-change.sh).
set -uo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/iso.sh"
change=${HS_ISO_CHANGE:-$here/iso-change.sh}

usage() { say "usage: hs iso [list] | add <file-or-url> [--name <name.iso>] (--checksum <sha256|sha512> | --no-checksum) | remove <name>"; exit 1; }

rows() {
  local d n f size
  d=$(iso_dir)
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    f="$d/$n"
    size=$(stat -c %s "$f" 2>/dev/null || echo 0)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$size" "$(iso_meta "$f.meta" algo | sed 's/^$/-/')" "$(iso_meta "$f.meta" hash | sed 's/^$/-/')" \
      "$(iso_meta "$f.meta" verified | sed 's/^$/no/')" "$(iso_meta "$f.meta" source | sed 's/^$/-/')" "$(iso_meta "$f.meta" added | sed 's/^$/-/')" "$(iso_used_by "$n")"
  done < <(iso_names)
}

# a plan or start answer (key TAB value lines) shown for people; returns 0 when it was allowed
show() {
  local key val st=""
  while IFS=$'\t' read -r key val; do
    case "$key" in
      status) st=$val ;;
      reason) warn "$val" ;;
      heading) line "$val" ;;
      step) note "$val" ;;
      note) note "$val" ;;
      warn) warn "$val" ;;
      danger) danger "$val" ;;
      needs) note "$(t 'Missing: %s' "$val")" ;;
    esac
  done <<<"$1"
  [ "$st" = ok ] || [ "$st" = started ] || [ "$st" = done ]
}

cmd=${1:-list}
case "$cmd" in
  --list) rows ;;
  --dir) iso_dir ;;
  list)
    out=$(rows)
    if [ -z "$out" ]; then
      note "The library is empty. Add an image: hs iso add <file-or-url> --checksum <sha256>"
      exit 0
    fi
    {
      thead 'Name' 'Size' 'Checksum' 'Checked' 'Used by'
      while IFS=$'\t' read -r name bytes algo hash ver _src _added used; do
        printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$(numfmt --to=iec --suffix=B "$bytes" 2>/dev/null || echo "$bytes")" "${algo}:${hash:0:16}…" "$(_tr "$ver")" "$used"
      done <<<"$out"
    } | table
    ;;
  add)
    shift
    [ $# -ge 1 ] || usage
    ans=$(HS_PLAIN=1 HS_LANG=en bash "$change" plan add "$@" </dev/null) ; rc=$?
    show "$ans" || { [ "$rc" -ne 2 ] || note "Give the checksum from the download page (--checksum <hex>), or --no-checksum to only see the computed one."; exit 1; }
    ans=$(HS_PLAIN=1 HS_LANG=en bash "$change" start add "$@" </dev/null) || { show "$ans"; exit 1; }
    unit=$(awk -F'\t' '$1 == "unit" { print $2 }' <<<"$ans")
    ok "$(t 'The image is being added as a background job: %s' "$unit")"
    next_step "hs job follow $unit"
    ;;
  remove)
    name=${2:-}; [ -n "$name" ] || usage
    ans=$(HS_PLAIN=1 HS_LANG=en bash "$change" plan remove "$name" </dev/null) || { show "$ans"; exit 1; }
    show "$ans" || exit 1
    confirm_name "$name" "the image" || fail "Not confirmed: nothing was removed."
    ans=$(HS_PLAIN=1 HS_LANG=en bash "$change" start remove "$name" --confirm "$name" </dev/null) || { show "$ans"; exit 1; }
    ok "$(t "'%s' is removed from the library." "$name")"
    ;;
  *) usage ;;
esac
