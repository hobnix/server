#!/usr/bin/env bash
# help: the names under <siteName>.<domain> in the domain's DNS (list, clean)
# help.de: die Namen unter <siteName>.<Domäne> im DNS der Domäne (anzeigen, aufräumen)
# args: list | raw | clean [--yes] [--dry-run]
# Records under <siteName>.<domain> (siteName in machine.toml, default hostName). hs no longer writes them (the sync was removed
# 2026-10-29); local names come from the gateway. An explicit record beats the gateway wildcard *.<siteName>, so a leftover of the old
# sync shadows the gateway name. `clean` removes those leftovers: the A and CNAME records <instance>.<siteName> (also the arr aliases radarr, sonarr ...),
# <siteName> itself, incus.<siteName> and arcane.<siteName>; other hand-made records stay, never the wildcard (`*`, `*.`), never a name deeper than one label under <siteName>.
# The records live in the DNS of the domain controller (samba-tool dns, as the controller's own machine account, no password).
# raw: the names in the zone as name<TAB>type<TAB>value, no header (hs sys dns list).
# HS_MACHINE_FILE, HS_SITE_NAME_FILE, HS_DC (controller instance, default: found by lib/dc.sh), HS_INCUS point tests at stand-ins.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/machine.sh"
. "$here/lib/dc.sh"
machine=$(machine_file)
site_file=${HS_SITE_NAME_FILE:-/etc/hs/site-name}
inc=${HS_INCUS:-incus}
dc=$(dc_name)

usage() { say "usage: hs dns list"; say "       hs dns clean [--yes] [--dry-run]"; exit 1; }
interactive() { [ -t 0 ] && [ -t 1 ] && [ -z "${HS_CALLER:-}" ] || [ -n "${HS_GUIDED_TTY:-}" ]; }

# adDomain = { realm = "AD.HOME.LAN", workgroup = "HOME" }
realm=$(machine_get adDomain.realm 2>/dev/null | tr 'A-Z' 'a-z' || true)
[ -n "$realm" ] || fail "There is no domain (adDomain) in machine.toml, so there is no DNS to put names into."
site=$(tr -d ' \r\n' <"$site_file" 2>/dev/null | tr 'A-Z' 'a-z' || true)
[[ "$site" =~ ^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$ ]] || fail "$(t "siteName '%s' is not a name for DNS (letters, digits, hyphen). Set siteName in machine.toml." "$site")"

# samba-tool dns <verb> 127.0.0.1 <zone> <args> as the controller's machine account
sam() { local verb=$1; shift; "$inc" exec "$dc" -- samba-tool dns "$verb" 127.0.0.1 "$realm" "$@" -P </dev/null; }

# what the zone holds under <siteName>: name<TAB>type<TAB>value
actual() {
  sam query "$site" ALL 2>/dev/null | awk -v s="$site" '
    /^  Name=/ { n = $0; sub(/^  Name=/, "", n); sub(/,.*/, "", n); node = (n == "") ? s : n "." s; next }
    /^    (A|CNAME): / { t = $1; sub(/:$/, "", t); v = $2; sub(/\.$/, "", v); printf "%s\t%s\t%s\n", node, t, v }' || true
}

sub=${1:-}; [ $# -eq 0 ] || shift
case "$sub" in
  list)
    status_line "DNS names" "$(t 'under %s.%s' "$site" "$realm")" ok
    { thead 'Name' 'Type' 'Value'
      actual | sort | while IFS=$'\t' read -r n t v; do printf '%s.%s\t%s\t%s\n' "$n" "$realm" "$t" "$v"; done; } | table ;;
  raw)
    actual | sort | while IFS=$'\t' read -r n t v; do printf '%s.%s\t%s\t%s\n' "$n" "$realm" "$t" "$v"; done ;;
  clean)
    yes=false; dry=false
    for a in "$@"; do case "$a" in --yes) yes=true ;; --dry-run) dry=true ;; *) usage ;; esac; done
    "$inc" info "$dc" >/dev/null 2>&1 || fail "$(t "The domain controller '%s' does not exist here." "$dc")"
    # only what the old sync made: <instance>.<siteName> (any state), the arr aliases it dropped, incus, arcane and <siteName> itself.
    # Other records, even one label below <siteName>, were made by hand and stay; so does the wildcard.
    mine=" incus arcane radarr sonarr lidarr readarr prowlarr bazarr maintainerr "
    while IFS= read -r i; do [[ $i =~ ^[a-z0-9][a-z0-9-]*$ ]] && mine+="$i "; done < <("$inc" list -c n -f csv 2>/dev/null </dev/null || true)
    plan=()
    while IFS=$'	' read -r n t v; do
      if [ "$n" = "$site" ]; then :
      else
        rel=${n%".$site"}
        [ "$rel" != "$n" ] && [[ $rel != *.* && $rel != \** && $mine == *" $rel "* ]] || continue
      fi
      plan+=("$n|$t|$v")
    done < <(actual | sort)
    if [ ${#plan[@]} -eq 0 ]; then ok "$(t 'No leftover names under %s.%s.' "$site" "$realm")"; exit 0; fi
    step "DNS names"
    { thead 'Action' 'Name' 'Type' 'Value'
      for p in "${plan[@]}"; do IFS='|' read -r n t v <<<"$p"
        printf '%s\t%s.%s\t%s\t%s\n' "$(_tr remove)" "$n" "$realm" "$t" "$v"; done; } | table
    if $dry; then note "Dry run: nothing was changed. Apply with: hs dns clean"; exit 0; fi
    if ! $yes; then
      interactive || fail "Nothing is changed without --yes when there is no terminal."
      confirm "$(t 'Remove these %s names from the DNS?' "${#plan[@]}")" || fail "cancelled"
    fi
    failed=0
    for p in "${plan[@]}"; do IFS='|' read -r n t v <<<"$p"
      sam delete "$n" "$t" "$v" >/dev/null 2>&1 || { warn "$(t 'Could not remove %s.%s (%s)' "$n" "$realm" "$t")"; failed=$((failed + 1)); }
    done
    if [ "$failed" -gt 0 ]; then
      note "Check that the domain controller is running (hs ct list), then run again: hs dns clean"
      fail "$(t '%s of %s removals failed.' "$failed" "${#plan[@]}")"
    fi
    ok "$(t '%s names removed.' "${#plan[@]}")"
    note "Show the result with: hs dns list" ;;
  *) usage ;;
esac
