#!/usr/bin/env bash
# help: who may read or write which share (users and groups), in a full-screen interface
# help.de: wer welche Freigabe lesen oder schreiben darf (Benutzer und Gruppen), in einer Vollbild-Oberfläche
# args: [--plain]
set -euo pipefail

# Used by the web interface (Shares):
#   --list                              shares: name, kind, path, upload cache (on | off | emptying | -),
#                                       size in bytes (or -), when the sizes were measured (empty: live)
#   --measure [share]                   snapraid layout: measure the size of every share now, or of one
#   --principals                        everyone who can be given access: sid, name, user|group
#   <share> --acl                       current entries: sid, name, user|group, level
#   <share> --set <sid>=<level> ...     level: none | read | write | full
#   <share> --cache on|off              upload cache on the SSD pool (hs share <share> cache); restarts the
#                                       containers that have the share mounted
#   <share> --rename <new>              new name: the folder on every disk, the Samba share with its
#                                       permissions, the backup switch; containers that mount it restart
#   <share> --visible                   visible | hidden (is the share listed when browsing the server)
#   <share> --visibility visible|hidden list the share when browsing the server, or hide it (Samba `browseable`)
# Add --dry-run to --set, --cache, --visibility or --rename to see the result without changing anything.

here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/bulkpath.sh"

usage() { say "usage: hs share <share> perm [--plain]"; exit 1; }

dry=false
plain=false
args=()
for a in "$@"; do
  case "$a" in
    --dry-run) dry=true ;;
    --plain)   plain=true ;;
    *)         args+=("$a") ;;
  esac
done
set -- "${args[@]}"

level_of() {
  case "$1" in
    FULL|0x001f01ff)   echo full ;;
    CHANGE|0x001301bf) echo write ;;
    READ|0x001200a9)   echo read ;;
    *)                 echo custom ;;
  esac
}
mask_of() {
  case "$1" in
    full)  echo FULL ;;
    write) echo CHANGE ;;
    read)  echo READ ;;
    *)     fail "$(t "unknown level '%s' (none, read, write, full)" "$1")" >&2 ;;
  esac
}

# "name<TAB>user|group" for a SID
describe() {
  case "$1" in
    S-1-1-0)  printf 'Everyone\tgroup\n'; return ;;
    S-1-5-11) printf 'Authenticated Users\tgroup\n'; return ;;
  esac
  local out
  if out=$(wbinfo -s "$1" 2>/dev/null); then
    # "HOME\simon 1": the number is the kind (1 = user, everything else a group)
    printf '%s\t%s\n' "${out% *}" "$([ "${out##* }" = 1 ] && echo user || echo group)"
  else
    printf '%s\t%s\n' "$1" "unknown"
  fi
}

# the raw entries of a share: SID:ALLOWED/0x0/MASK
entries() { sharesec "$1" --view 2>/dev/null | sed -n 's/^ACL://p'; }

# Sizes. On ZFS every share is a dataset and knows its size. On the snapraid
# layout a share is a folder and has to be counted file by file, which takes
# minutes on big shares: that is done once a night (and with --measure) and
# kept in a file.
sizes=${HS_STATE_DIR:-/var/lib/hs}/share-sizes
bulk_type=$(cat "${HS_BULK_TYPE_FILE:-/etc/hs/bulk-type}" 2>/dev/null || echo zfs)
size_of() {   # size_of <path>
  if [ "$bulk_type" = snapraid ]; then
    awk -F'\t' -v p="$1" '$1 == p { print $2; found = 1 } END { if (!found) print "-" }' "$sizes" 2>/dev/null || echo -
  else
    zfs list -Hp -o used "${1#/}" 2>/dev/null || echo -
  fi
}
measure() {   # measure [share]: every share, or only one (its line in the sizes file is replaced)
  local s path tmp only=${1:-}
  tmp=$(mktemp)
  [ -z "$only" ] || [ ! -e "$sizes" ] || cp "$sizes" "$tmp"
  for s in $(net conf listshares 2>/dev/null); do
    [ -z "$only" ] || [ "$s" = "$only" ] || continue
    path=$(net conf getparm "$s" path 2>/dev/null || true)
    case "$path" in
      /bulk/shares/*|/bulk/sensitive/*)
        if [ -n "$only" ]; then { grep -vF "$path"$'\t' "$tmp" || true; } > "$tmp.n"; mv "$tmp.n" "$tmp"; fi
        if [ -t 1 ]; then
          # a person at a terminal sees a spinner per share; the timer and the interface get no extra lines
          spin "$(t 'Measuring %s' "$s")" bash -c 'du -sb "$1" 2>/dev/null | cut -f1' _ "$path" || true
          printf '%s\t%s\n' "$path" "$spin_out" >> "$tmp"
        else
          printf '%s\t%s\n' "$path" "$(du -sb "$path" 2>/dev/null | cut -f1)" >> "$tmp"
        fi ;;
    esac
  done
  mkdir -p "$(dirname "$sizes")"
  mv "$tmp" "$sizes"
  chmod 644 "$sizes"
}

shares() {
  local s path kind cache size measured=""
  if [ "$bulk_type" = snapraid ]; then
    measured=never
    [ ! -e "$sizes" ] || measured=$(date -r "$sizes" '+%d.%m. %H:%M')
  fi
  for s in $(net conf listshares 2>/dev/null); do
    path=$(net conf getparm "$s" path 2>/dev/null || true)
    case "$path" in
      /bulk/shares/*)    kind=shares ;;
      /bulk/sensitive/*) kind=sensitive ;;
      *)                 kind=other ;;
    esac
    cache=-
    if [ "$kind" != other ]; then
      cache=$(bash "$here/share-cache.sh" --state "$path" 2>/dev/null | cut -f1 || true)
      [ "${cache:-unsupported}" != unsupported ] || cache=-
    fi
    size=-
    [ "$kind" = other ] || size=$(size_of "$path")
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$s" "$kind" "$path" "$cache" "${size:--}" "$measured"
  done
}

principals() {
  printf 'S-1-1-0\tEveryone\tgroup\n'
  local n sid
  # built-in groups nobody assigns share rights to
  local noise='rodc|read-only domain|cert publishers|ras and ias|dnsadmins|dnsupdateproxy|schema admins|enterprise|group policy|domain controllers|domain computers|domain guests|protected users'
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    grep -qiE "$noise" <<<"$n" && continue
    sid=$(wbinfo -n "$n" 2>/dev/null | cut -d' ' -f1) || continue
    [ -n "$sid" ] && printf '%s\t%s\tgroup\n' "$sid" "$n"
  done < <(wbinfo -g 2>/dev/null | sort -f)
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    grep -qiE '(^|\\)(guest|krbtgt|nobody)$' <<<"$n" && continue
    sid=$(wbinfo -n "$n" 2>/dev/null | cut -d' ' -f1) || continue
    [ -n "$sid" ] && printf '%s\t%s\tuser\n' "$sid" "$n"
  done < <(wbinfo -u 2>/dev/null | sort -f)
}

acl() {
  local e sid rest
  while IFS= read -r e; do
    sid=${e%%:*}; rest=${e#*:}
    if [[ "$rest" == ALLOWED/* ]]; then
      printf '%s\t%s\t%s\n' "$sid" "$(describe "$sid")" "$(level_of "${rest##*/}")"
    else
      printf '%s\t%s\t%s\n' "$sid" "$(describe "$sid")" "denied"
    fi
  done < <(entries "$1")
}

case "${1:-}" in
  ""|--list)
    if [ $# -eq 0 ]; then
      # plain overview
      while IFS=$'\t' read -r s kind path cache _; do
        step "$s  ($path)$([ "$cache" = on ] && echo "  $(t 'upload cache on')" || true)"
        rows=$(acl "$s" | awk -F'\t' '{ printf "%s\t%s\t%s\n", $4, $3, $2 }')
        if [ -n "$rows" ]; then { thead Level Type Name; printf '%s\n' "$rows"; } | table; else note "Nobody has access to this share."; fi
      done < <(shares)
    else
      shares
    fi
    exit 0 ;;
  --principals)
    principals
    exit 0 ;;
  --measure)
    if [ "$bulk_type" = snapraid ]; then measure "${2:-}"; else note "Nothing to measure: on ZFS the sizes are always current."; fi
    exit 0 ;;
esac

# ── Renaming ──
# A share's name is its folder name, so a rename changes the folder on every
# disk that holds it, then moves the Samba share (settings and permissions),
# the backup switch and the mounts of containers over to the new name.
BULK=${HS_BULK:-/bulk}
DATA_ROOT=${HS_DATA_ROOT:-$(disks_root)}
STATE=${HS_STATE_DIR:-/var/lib/hs}

rename_share() {   # rename_share <old> <new>
  local old=$1 new=$2 path kind newpath cache d dirs=() done_dirs=() ct dev line k v acl=() e params=() users=()
  path=$(net conf getparm "$old" path)
  case "$path" in
    "$BULK"/shares/*)    kind=shares ;;
    "$BULK"/sensitive/*) kind=sensitive ;;
    *) fail "$(t "'%s' is not a folder under %s/shares or %s/sensitive: it can't be renamed here." "$old" "$BULK" "$BULK")" ;;
  esac
  newpath=$(dirname "$path")/$new

  [[ "$new" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "$(t "'%s' is not a usable name (letters, digits, . _ - only; at most one word)." "$new")"
  [ "${#new}" -le 80 ] || fail "The name is too long."
  case "${new,,}" in shares|sensitive|global|homes|printers) fail "$(t "'%s' is a reserved name." "$new")" ;; esac
  [ "$new" != "$old" ] || fail "That is the name it has already."
  if net conf listshares 2>/dev/null | grep -qix "$new"; then fail "$(t "A share called '%s' exists already." "$new")"; fi

  if [ "$bulk_type" = snapraid ]; then
    for d in "$DATA_ROOT"/data-*/"$kind"/"$old"; do [ -d "$d" ] && dirs+=("$d"); done
    [ ${#dirs[@]} -gt 0 ] || fail "$(t "No disk holds a folder '%s' (is the pool mounted?)." "$old")"
    for d in "${dirs[@]}"; do
      [ ! -e "$(dirname "$d")/$new" ] || fail "$(t "%s has a '%s' already (a share of that name would merge with it)." "$(dirname "$d")" "$new")"
    done
    cache=$(bash "$here/share-cache.sh" --state "$path" 2>/dev/null | cut -f1 || true)
    case "${cache:-unsupported}" in on|emptying)
      fail "$(t "The upload cache of '%s' is %s. Switch it off first and wait until it is empty:  hs share %s cache off" "$old" "$cache" "$old")" ;;
    esac
  else
    zfs list -H -o name "bulk/$kind/$old" >/dev/null 2>&1 || fail "$(t 'No dataset bulk/%s/%s.' "$kind" "$old")"
    ! zfs list -H -o name "bulk/$kind/$new" >/dev/null 2>&1 || fail "$(t 'bulk/%s/%s exists already.' "$kind" "$new")"
  fi

  # containers that have this folder mounted: "<instance> <device>"
  while read -r ct dev; do
    [ -n "$ct" ] && users+=("$ct $dev")
  done < <(incus list -c n -f csv 2>/dev/null </dev/null | while read -r n; do
             incus query "/1.0/instances/$n" </dev/null 2>/dev/null |
               jq -r --arg n "$n" --arg p "$path" '.devices // {} | to_entries[] | select(.value.type == "disk" and .value.source == $p) | "\($n) \(.key)"'
           done)

  echo "Rename '$old' to '$new':"
  if [ "$bulk_type" = snapraid ]; then
    for d in "${dirs[@]}"; do echo "  folder   $d -> $(dirname "$d")/$new"; done
  else
    echo "  dataset  bulk/$kind/$old -> bulk/$kind/$new"
  fi
  echo "  Samba    share '$old' is replaced by '$new' (same settings and permissions)"
  [ ${#users[@]} -eq 0 ] || echo "  restart  mounted in: $(printf '%s ' "${users[@]%% *}")(the mount points at the new folder)"
  echo "  note     old backup snapshots keep the old path; the backup switch moves to the new name"
  if $dry; then echo "(dry run, nothing changed)"; exit 0; fi

  # nothing may write while the folders move: same lock as parity sync and cache mover
  exec 9>"${HS_LOCK:-/run/hs-bulk.lock}"
  flock -w 600 9 || fail "Parity sync or cache mover is running, try again later."
  smbcontrol smbd close-share "$old" >/dev/null 2>&1 || true     # disconnect people who have it open

  if [ "$bulk_type" = snapraid ]; then
    for d in "${dirs[@]}"; do
      if mv "$d" "$(dirname "$d")/$new"; then done_dirs+=("$d")
      else
        warn "$(t 'Could not rename %s; undoing the renames already made.' "$d")"
        for d in "${done_dirs[@]}"; do mv "$(dirname "$d")/$new" "$d" || warn "$(t 'could not undo %s: rename it back by hand' "$d")"; done
        fail "The rename was not completed."
      fi
    done
  else
    zfs rename "bulk/$kind/$old" "bulk/$kind/$new"
  fi

  # Samba: new share with the same parameters and permissions, then drop the old one
  while IFS= read -r e; do acl+=("$e"); done < <(entries "$old")
  while IFS= read -r line; do
    case "$line" in $'\t'*=*) k=${line#$'\t'}; v=${k#*= }; k=${k%% = *}; [ "$k" = path ] || params+=("$k=$v") ;; esac
  done < <(net conf showshare "$old")
  net conf addshare "$new" "$newpath"
  for line in "${params[@]}"; do net conf setparm "$new" "${line%%=*}" "${line#*=}"; done
  [ ${#acl[@]} -eq 0 ] || sharesec "$new" --replace "$(IFS=,; echo "${acl[*]}")"
  net conf delshare "$old"

  # the other places a share's name is kept
  if [ -f "$STATE/backup-off" ] && grep -qxF "$old" "$STATE/backup-off"; then
    sed -i "s|^$(printf '%s' "$old" | sed 's/[.[\*^$|]/\\&/g')\$|$new|" "$STATE/backup-off"
  fi
  if [ -f "$sizes" ]; then
    awk -F'\t' -v OFS='\t' -v o="$path" -v n="$newpath" '$1 == o { $1 = n } { print }' "$sizes" > "$sizes.new" && mv "$sizes.new" "$sizes" || true
  fi

  for line in "${users[@]}"; do
    ct=${line%% *}; dev=${line#* }
    incus config device set "$ct" "$dev" source="$newpath" </dev/null
    note "$(t '%s: mount now points at %s' "$ct" "$newpath")"
    spin "$(t 'Restarting %s' "$ct")" incus restart "$ct" || warn "$(t 'could not restart %s, do it by hand' "$ct")"
  done
  ok "$(t "Done: '%s' is now '%s'. Share paths and shortcuts that used the old name must be updated on the PCs." "$old" "$new")"
}

share="$1"; shift
[ $# -ge 1 ] || usage
net conf showshare "$share" >/dev/null 2>&1 || fail "$(t "No share called '%s' (hs share repair lists and creates them)." "$share")"

case "$1" in
  --acl)
    acl "$share" ;;

  --set)
    shift
    [ $# -ge 1 ] || usage
    declare -A want=()
    for kv in "$@"; do
      [[ "$kv" == S-*=* ]] || fail "$(t "expected <sid>=<level>, got '%s'" "$kv")"
      want[${kv%%=*}]=${kv#*=}
    done

    new=()
    while IFS= read -r e; do
      sid=${e%%:*}
      [ -n "${want[$sid]+x}" ] || new+=("$e")       # untouched entries stay as they are
    done < <(entries "$share")
    for sid in "${!want[@]}"; do
      [ "${want[$sid]}" = none ] || new+=("$sid:ALLOWED/0x0/$(mask_of "${want[$sid]}")")
    done

    # no "someone must keep full" check: the web interface and hs change the share as root and
    # write files as adminuser (force user), so these rights only decide who may use it over Samba

    echo "Access to '$share' afterwards:"
    for e in "${new[@]}"; do
      sid=${e%%:*}
      printf '  %-6s %s\n' "$(level_of "${e##*/}")" "$(describe "$sid" | cut -f1)"
    done
    if $dry; then exit 0; fi
    sharesec "$share" --replace "$(IFS=,; echo "${new[*]}")"
    ok "Saved. It applies to new connections; someone already connected keeps the old rights until they reconnect."
    ;;

  --visible)
    # one word: visible | hidden (Samba's `browseable`; a hidden share can still be opened by typing its path)
    case "$(net conf getparm "$share" browseable 2>/dev/null || true)" in no|No|NO|false|0) echo hidden ;; *) echo visible ;; esac ;;

  --visibility)
    [ $# -ge 2 ] || usage
    case "$2" in
      visible) yn=yes ;;
      hidden)  yn=no ;;
      *) fail "$(t "unknown visibility '%s' (visible, hidden)" "$2")" ;;
    esac
    echo "'$share' is $2 in the network list afterwards:"
    if [ "$2" = hidden ]; then
      echo "  nobody sees it when browsing the server; whoever has access can still open it by typing \\\\server\\$share"
    else
      echo "  everyone who browses the server sees it (only people with access can open it)"
    fi
    if $dry; then exit 0; fi
    net conf setparm "$share" browseable "$yn"
    ok "Saved. The network list updates when a computer looks at the server again."
    ;;

  --cache)
    [ $# -ge 2 ] || usage
    cache_args=("$(net conf getparm "$share" path)" "$2" --restart)
    if $dry; then cache_args+=(--dry-run); fi
    bash "$here/share-cache.sh" "${cache_args[@]}"
    ;;

  --rename)
    [ $# -ge 2 ] || usage
    new=$2
    rename_share "$share" "$new" ;;

  *) usage ;;
esac
