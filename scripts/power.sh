#!/usr/bin/env bash
# help: shut the server down or reboot it (asks first; waits while a backup, sync, scrub or pool change is running)
# help.de: den Server herunterfahren oder neu starten (fragt vorher; wartet, solange Backup, Sync, Scrub oder eine Pooländerung läuft)
# args: shutdown [--yes] [--force] [--dry-run] | reboot [--menu | --firmware | --entry <id>] [--yes] [--force] [--dry-run]
# Both ask for a yes on a terminal (--yes skips it; no terminal and no --yes = refuses). They refuse while something that must
# not be cut off is running: the bulk lock (parity sync, scrub, cache mover, share rename, pool change), a background job
# (hs job running), or a backup / self-test / system cleanup; the answer says what. --force goes ahead anyway (still asks).
#   reboot --menu       the boot menu of systemd-boot shows once on the next boot (60 s, then the default entry starts)
#   reboot --firmware   the next boot goes into the BIOS setup (works without a keyboard at the start; needs EFI)
#   reboot --entry <id> boot the entry <id> (see: bootctl list) once; the next boot is the normal one again
#   --dry-run           only say what would run
# The push messages ("rebooting", "shutting down") come from hs-shutdown-notice and stay as they are.
# Test knobs: HS_SYSTEMCTL, HS_BOOTCTL, HS_LOCK, HS_LOCK_ADMIN (lib/bulklock.sh), HS_EFI_DIR (default /sys/firmware/efi).
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/bulklock.sh"
systemctl_bin=${HS_SYSTEMCTL:-systemctl}
bootctl_bin=${HS_BOOTCTL:-bootctl}
efi_dir=${HS_EFI_DIR:-/sys/firmware/efi}
menu_seconds=60

usage() {
  say "usage: hs shutdown [--yes] [--force] [--dry-run]"
  say "       hs reboot [--menu | --firmware | --entry <id>] [--yes] [--force] [--dry-run]"
  exit 1
}
interactive() { [ -t 0 ] && [ -t 1 ] && [ -z "${HS_CALLER:-}" ] || [ -n "${HS_GUIDED_TTY:-}" ]; }

verb=${1:-}
[ "$verb" = shutdown ] || [ "$verb" = reboot ] || usage
shift
yes=false force=false dry=false mode=normal entry=
while [ $# -gt 0 ]; do
  case $1 in
    --yes|-y) yes=true ;;
    --force) force=true ;;
    --dry-run) dry=true ;;
    --menu|--firmware)
      [ "$verb" = reboot ] || fail "$(t '%s only works with hs reboot.' "$1")"
      [ "$mode" = normal ] || fail "Choose one of --menu, --firmware and --entry."
      mode=${1#--} ;;
    --entry)
      [ "$verb" = reboot ] || fail "$(t '%s only works with hs reboot.' "$1")"
      [ "$mode" = normal ] || fail "Choose one of --menu, --firmware and --entry."
      [ $# -ge 2 ] && [ -n "$2" ] || fail "--entry needs an entry id (see: bootctl list)."
      mode=entry entry=$2; shift ;;
    *) usage ;;
  esac
  shift
done

# what must not be cut off: one line per reason
busy() {
  local unit
  if [ -e "$bulk_admin" ]; then
    echo "$(t 'a pool change (hs manage-pool) holds the bulk lock')"
  elif [ -e "$bulk_lock" ] && [ -w "$bulk_lock" ]; then
    ( flock -n 8 ) 8>"$bulk_lock" 2>/dev/null || echo "$(t 'a parity sync, scrub, cache mover or share rename holds the bulk lock')"
  fi
  while read -r unit; do
    [ -n "$unit" ] && echo "$(t 'background job %s (hs job running)' "$unit")"
  done < <("$systemctl_bin" list-units 'hs-job-*.service' --state=active,activating --no-legend --no-pager 2>/dev/null | awk '{ print $1 }' || true)
  for unit in hs-backup hs-backup-drill hs-selftest-short hs-selftest-long hs-system-gc hs-bulk-sync hs-bulk-scrub hs-cache-mover; do
    case $("$systemctl_bin" is-active "$unit.service" 2>/dev/null || true) in
      active|activating) echo "$(t '%s is running' "$unit.service")" ;;
    esac
  done
}

# the command, checked before anything is asked
cmd=("$systemctl_bin")
case $mode in
  normal)   [ "$verb" = shutdown ] && cmd+=(poweroff) || cmd+=(reboot) ;;
  menu)     cmd+=(reboot "--boot-loader-menu=$menu_seconds") ;;
  firmware)
    [ -d "$efi_dir" ] || fail "This server did not start in EFI mode: there is no firmware setup to reboot into."
    cmd+=(reboot --firmware-setup) ;;
  entry)
    if command -v "$bootctl_bin" >/dev/null 2>&1; then
      "$bootctl_bin" list 2>/dev/null | grep -Eq "^[[:space:]]*id:[[:space:]]+${entry}[[:space:]]*$" \
        || fail "$(t 'No boot entry %s. The entries: bootctl list' "$entry")"
    fi
    cmd+=(reboot "--boot-loader-entry=$entry") ;;
esac

if [ "$verb" = shutdown ]; then what='Shut the server down now?'
else
  case $mode in
    menu) what='Reboot the server into the boot menu now?' ;;
    firmware) what='Reboot the server into the BIOS setup now?' ;;
    entry) what="$(t 'Reboot the server once into the boot entry %s now?' "$entry")" ;;
    *) what='Reboot the server now?' ;;
  esac
fi

reasons=$(busy)
if [ -n "$reasons" ]; then
  warn "This is still running:"
  while IFS= read -r line; do note "  $line"; done <<<"$reasons"
  $force || $dry || fail_fix "Not now. Wait until it is done, or go ahead anyway." "hs $verb --force"
fi

if $dry; then
  step "Dry run"
  kv Command "${cmd[*]}"
  exit 0
fi

if ! $yes; then
  interactive || fail "Nothing is changed without --yes when there is no terminal."
  [ -z "$reasons" ] || danger "Whatever is running will be cut off."
  confirm "$what" || fail "cancelled"
fi

note "$(t 'Running: %s' "${cmd[*]}")"
exec "${cmd[@]}"
