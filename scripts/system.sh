#!/usr/bin/env bash
# help: the server itself: info, roll back to the previous NixOS generation, clean old generations
# help.de: der Server selbst: Info, zurück zur vorherigen NixOS-Generation, alte Generationen aufräumen
# args: info | rollback | gc [days]
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/setting.sh"

usage() {
  say "usage: hs system info"
  say "       hs system rollback       go back to the previous generation (what hs update/rebuild replaced)"
  say "       hs system gc [days] [--yes]   delete generations older than <days> (default 30) and free the space"
  exit 1
}

# Like `uptime -p`, but read from /proc/uptime: works without root (and without uptime installed).
uptime_text() {
  local up
  up=$(cut -d' ' -f1 "${HS_PROC_UPTIME:-/proc/uptime}" 2>/dev/null) && [ -n "$up" ] || { echo '-'; return 0; }
  awk -v s="${up%.*}" 'BEGIN {
    d = int(s / 86400); h = int(s % 86400 / 3600); m = int(s % 3600 / 60); out = "up "
    if (d) out = out d " day" (d == 1 ? "" : "s") ", "
    if (d || h) out = out h " hour" (h == 1 ? "" : "s") ", "
    print out m " minute" (m == 1 ? "" : "s") }'
}

cmd=${1:-info}
[ $# -eq 0 ] || shift
case "$cmd" in
  info)
    step "This server"
    kv "Host" "$(hostname)"
    kv "NixOS" "$(nixos-version 2>/dev/null || echo '-')"
    kv "Generation" "$(readlink /nix/var/nix/profiles/system 2>/dev/null | sed 's/-link$//; s/^system-//' || echo '-')"
    kv "Uptime" "$(uptime_text)"
    kv "Language" "$(setting_get language 2>/dev/null || echo en)"
    kv "Bulk layout" "$(cat /etc/hs/bulk-type 2>/dev/null || echo zfs)"
    kv "Root disk" "$(df -h --output=used,size,pcent / | tail -n1 | awk '{ printf "%s of %s (%s)", $1, $2, $3 }')"
    kv "Repo" "$(git -C /etc/nixos log -1 --format='%h %s' 2>/dev/null || echo '-')"
    ;;
  rollback)
    step "Rolling back"
    line "Generations:"
    ls -1t /nix/var/nix/profiles/ 2>/dev/null | grep -E '^system-[0-9]+-link$' | head -n 5 | while IFS= read -r g; do note "$g"; done || true
    warn "This switches the running system back to the previous generation (services restart)."
    confirm "Go back to the previous generation?" || fail "cancelled"
    SPIN_TAIL=60 spin "Switching to the previous generation" nixos-rebuild switch --rollback || exit 1
    ok "Rolled back. The newer generation is still there."
    next_step "hs rebuild"
    elapsed_line ;;
  gc)
    days=30; yes=false
    for a in "$@"; do case "$a" in --yes) yes=true ;; *) days=$a ;; esac; done
    [[ "$days" =~ ^[0-9]+$ ]] || usage
    step "Cleaning up old generations"
    if ! $yes; then
      warn "$(t 'Deletes every generation older than %s days. Rolling back further than that is not possible afterwards.' "$days")"
      confirm "Delete them and free the space?" || fail "cancelled"
    fi
    before=$(df -B1 --output=avail / | tail -n1 | tr -d ' ')
    spin "Deleting old generations" nix-collect-garbage --delete-older-than "${days}d" || exit 1
    after=$(df -B1 --output=avail / | tail -n1 | tr -d ' ')
    ok "$(t 'Freed about %s.' "$(numfmt --to=iec "$(( after > before ? after - before : 0 ))")")"
    elapsed_line ;;
  *) usage ;;
esac
