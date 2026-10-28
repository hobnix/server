#!/usr/bin/env bash
# help: publish every folder directly under /bulk/shares and /bulk/sensitive as its own Samba share (adds missing ones)
# help.de: veröffentlicht jeden Ordner direkt unter /bulk/shares und /bulk/sensitive als eigene Samba-Freigabe (ergänzt fehlende)
# args: [--check] [--fix-owner]
set -euo pipefail
. "$(dirname "$0")/lib/ui.sh"

check=false
fix_all=false
for a in "$@"; do
  case "$a" in
    --check)     check=true ;;
    --fix-owner) fix_all=true ;;
    *) say "usage: hs share repair [--check] [--fix-owner]"
       say "  --check      only list what is missing or wrong, change nothing"
       say "  --fix-owner  also hand over every file of every share to adminuser (slow on big shares);"
       say "               without it, files are only handed over in folders that do not belong to adminuser yet"
       exit 1 ;;
  esac
done

# Shares created here live in Samba's registry (`include = registry`), next
# to the two config-defined shares that span each parent directory.
mapfile -t existing < <(net conf listshares)
has() {
  local s
  for s in "${existing[@]}"; do [ "${s,,}" = "${1,,}" ] && return 0; done
  return 1
}

# In a domain, new shares start closed: only Domain Admins get in until
# access is granted in fsmgmt.msc. Without a domain there is no admin group,
# so they start open to every Samba user.
admins=""
admins_sid=""
if [ "$(testparm -s --parameter-name=security 2>/dev/null)" = "ADS" ]; then
  admins="$(testparm -s --parameter-name=workgroup 2>/dev/null)\Domain Admins"
  # sharesec splits its argument at spaces, so pass the group as a SID
  admins_sid=$(wbinfo -n "$admins" 2>/dev/null | cut -d" " -f1 || true)
  if [ -z "$admins_sid" ]; then
    fail "$(t "Cannot look up %s (is winbind running?), new shares would start open." "$admins")"
  fi
fi

# The shares are ZFS datasets, or plain folders on the snapraid layout
bulk_type=$(cat /etc/hs/bulk-type 2>/dev/null || echo zfs)
children() {
  if [ "$bulk_type" = snapraid ]; then
    find "/bulk/$1" -mindepth 1 -maxdepth 1 -type d ! -name 'lost+found' -printf '%f\n' 2>/dev/null | sort
  else
    zfs list -H -o name -d 1 "bulk/$1" 2>/dev/null | tail -n +2 | sed 's|.*/||'
  fi
}

missing=0
rows=()
row() { rows+=("$1"$'	'"$2"); }   # row <share> <state>: collected, printed as one table at the end
for parent in shares sensitive; do
  while read -r name; do
    path="/bulk/$parent/$name"

    # a share deleted from the interface keeps its folder as <name>.deleted-<date> (not published, kept until someone removes it)
    case "$name" in
      *.deleted-*)
        row "$name" "$(t 'deleted share, kept (not published; remove the folder by hand when you are sure)')"
        continue ;;
    esac

    case "${name,,}" in
      shares|sensitive|global|homes|printers)
        row "$name" "$(t 'name is reserved, skipped')"
        continue ;;
    esac

    # Everything in a share is written as adminuser. A folder made by hand with
    # sudo belongs to root, one adopted from Unraid to nobody: the share shows up,
    # but nobody can add files. Then the whole folder is handed over: the files
    # first and the folder itself last, so an interrupted run starts again.
    if [ "$parent" = shares ] && { $fix_all || [ "$(stat -c %U "$path")" != adminuser ]; }; then
      owner=$(stat -c %U "$path")
      if $check; then
        if [ "$owner" != adminuser ]; then
          row "$name" "$(t 'belongs to %s, nobody can write (hs share repair hands the files over)' "$owner")"
        fi
      else
        # the count and the current path trail under the spinner (every 500th file)
        spin "Handing over '$name' to adminuser (all its files, can take a while)" \
          bash -c 'stdbuf -oL find "$1" -mindepth 1 \( ! -user adminuser -o ! -group users \) -print -exec chown -h adminuser:users {} + |
                   awk "NR % 500 == 1 { print NR \" files so far, now: \" \$0; fflush() }"' _ "$path"
        chown adminuser:users "$path"
        chmod 2775 "$path"
        if [ "$owner" != adminuser ]; then
          row "$name" "$(t "belonged to %s, now adminuser's: writable for the share" "$owner")"
        fi
      fi
    fi

    if has "$name"; then
      current=$(net conf getparm "$name" path)
      if [ "$current" = "$path" ]; then
        row "$name" ok
      else
        row "$name" "$(t 'name already used for %s, skipped' "$current")"
      fi
      continue
    fi

    missing=$((missing + 1))
    if $check; then
      row "$name" "$(t 'missing (%s)' "$path")"
      continue
    fi

    # Same rules as the parent shares: /bulk/shares is written as adminuser,
    # /bulk/sensitive is read as root and never writable.
    if [ "$parent" = shares ]; then
      net conf addshare "$name" "$path" writeable=y guest_ok=n
      net conf setparm "$name" "force user" adminuser
    else
      net conf addshare "$name" "$path" writeable=n guest_ok=n
      net conf setparm "$name" "force user" root
    fi
    net conf setparm "$name" browseable no    # new shares are hidden when browsing; set visible in hs share <share> perm
    if [ -n "$admins" ]; then
      sharesec "$name" --replace "$admins_sid:ALLOWED/0x0/FULL" ||
        warn "$(t 'Could not restrict %s, it is open to every domain user' "$name")"
    fi
    existing+=("$name")
    row "$name" "$(t 'added (%s)' "$path")"
  done < <(children "$parent")
done

# Registry shares whose folder is gone (dataset destroyed or renamed)
for name in "${existing[@]}"; do
  path=$(net conf getparm "$name" path 2>/dev/null || true)
  if [ -n "$path" ] && [ ! -d "$path" ]; then
    row "$name" "$(t 'folder %s is gone; remove with: hs share cleanup' "$path")"
  fi
done

if [ ${#rows[@]} -gt 0 ]; then { thead SHARE STATE; printf '%s\n' "${rows[@]}"; } | table; fi
if $check && [ "$missing" -gt 0 ]; then
  warn "$(t '%s share(s) missing. Add them with: hs share repair' "$missing")"
elif [ "$missing" -gt 0 ]; then
  if [ -n "$admins" ]; then
    ok "$(t 'New shares are closed (only %s) until you set who may read or write' "$admins")"
  else
    warn "New shares are open to every Samba user until you set who may read or write"
  fi
  note "Set it in: hs share <share> perm (tab Shares, e)"
fi
