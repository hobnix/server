#!/usr/bin/env bash
# help: is everything fine? problems of the health check, failed jobs, running jobs, pending parity work, locked storage
# help.de: ist alles in Ordnung? Probleme der Gesundheitsprüfung, fehlgeschlagene und laufende Aufträge, ausstehende Paritätsarbeit, gesperrter Speicher
# args: (none)
set -uo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/machine.sh"
. "$here/lib/vault.sh"

bad=0
# A section collects its lines, then prints its summary (status_line) first and the details underneath.
det=()
d() { det+=("$1|$2"); }   # d ok|warn|note <text>
flush() {   # prints the collected lines
  local l k
  for l in ${det[@]+"${det[@]}"}; do
    k=${l%%|*}
    case "$k" in ok) ok "${l#*|}" ;; warn) warn "${l#*|}" ;; *) note "${l#*|}" ;; esac
  done
  det=()
}

step "Health check"
out=$(bash "$here/health-check.sh" --dry-run 2>&1 | sed -n '1,/^$/p' | sed '/^$/d' || true)
n=0
if grep -q '^No problems found' <<<"$out"; then :; else
  while IFS= read -r l; do [ -z "$l" ] || { d warn "$l"; n=$((n + 1)); }; done <<<"$out"
fi
[ "$n" -eq 0 ] || bad=1
if [ "$n" -eq 0 ]; then status_line "Problems" "None" ok; else status_line "Problems" "$n" warn; fi
flush

step "Jobs"
n=0
failed=$(bash "$here/jobs.sh" --list 2>/dev/null | awk -F'	' '$5 == "failed" { print $1 }' || true)
if [ -z "$failed" ]; then :; else
  while IFS= read -r u; do d warn "$(t 'Failed: %s (see: hs job log %s)' "$u" "$u")"; n=$((n + 1)); done <<<"$failed"
fi
running=$(bash "$here/jobs.sh" --running 2>/dev/null || true)
if [ -n "$running" ]; then
  while IFS=$'	' read -r u desc since; do d note "$(t 'Running: %s since %s (hs job follow %s)' "$desc" "$since" "$u")"; done <<<"$running"
fi
[ "$n" -eq 0 ] || bad=1
if [ "$n" -eq 0 ]; then status_line "Failed jobs" "None" ok; else status_line "Failed jobs" "$n" warn; fi
flush

step "Storage"
n=0
if [ -e /run/hs/storage-locked ]; then n=1; d warn "The encrypted storage is locked: hs unlock"; fi
if [ -s /var/lib/hs/removals ]; then
  d note "$(t 'Parity work is waiting for the next sync (removed or converted disks: %s). Now: hs pool bulk sync' "$(paste -sd' ' /var/lib/hs/removals)")"
fi
[ "$n" -eq 0 ] || bad=1
if [ "$n" -eq 0 ]; then status_line "Storage" "Unlocked" ok; else status_line "Storage" "Locked" bad; fi
# the vault (secrets of this server) only where there is one; closed is already a "Locked" above when the marker says so
if vault_configured; then
  if vault_is_open; then status_line "Vault" "open" ok; else status_line "Vault" "closed" warn; fi
fi
flush

step "System"
n=0
# the root disk: a full one stops the server in ways that are hard to repair
root_pct=$(df --output=pcent / | tail -n1 | tr -dc '0-9')
if [ -n "$root_pct" ] && [ "$root_pct" -ge 85 ]; then n=$((n + 1)); d warn "$(t 'The system disk is %s %% full. Free space: hs system gc' "$root_pct")"; else d ok "$(t 'The system disk is %s %% full.' "${root_pct:-?}")"; fi
# a new kernel is installed but the server still runs the old one
if [ -e /run/booted-system/kernel ] && [ -e /run/current-system/kernel ] &&
   [ "$(readlink -f /run/booted-system/kernel)" != "$(readlink -f /run/current-system/kernel)" ]; then
  d note "A newer kernel is installed: it is used after the next reboot."
fi
# time: certificates, Kerberos and backups all depend on it
if command -v timedatectl >/dev/null 2>&1; then
  if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ]; then d ok "The clock is synchronised."; else n=$((n + 1)); d warn "The clock is not synchronised (check the network and the time server)."; fi
fi
# names resolve
if command -v getent >/dev/null 2>&1; then
  if getent hosts cloudflare.com >/dev/null 2>&1; then d ok "Names resolve (DNS works)."; else n=$((n + 1)); d warn "Names do not resolve: DNS or the network is down."; fi
fi
# the Samba domain join, when a domain is configured
if machine_has adDomain && command -v wbinfo >/dev/null 2>&1; then
  if [ "${HS_DOCTOR_UID:-$(id -u)}" -ne 0 ]; then d note "The domain join cannot be checked without root (run: sudo hs doctor)."   # wbinfo -t needs the privileged pipe
  elif wbinfo -t >/dev/null 2>&1; then d ok "The domain join is healthy."; else n=$((n + 1)); d warn "The trust to the domain is broken: restart samba-winbindd, or re-join (net ads join)."; fi
fi
[ "$n" -eq 0 ] || bad=1
if [ "$n" -eq 0 ]; then status_line "System" "Fine" ok; else status_line "System" "$(t '%s thing(s) need a look' "$n")" warn; fi
flush

step "Result"
if [ "$bad" = 0 ]; then status_line "Overall" "All good" ok; else status_line "Overall" "Something needs a look (see above)" warn; fi
exit "$bad"
