#!/usr/bin/env bash
# help: names for your instances in the domain's DNS: <instance>.<siteName>.<domain> (list, sync)
# help.de: Namen für deine Instanzen im DNS der Domäne: <Instanz>.<siteName>.<Domäne> (anzeigen, abgleichen)
# args: list | raw | sync [--yes] [--dry-run] [--plain]
# Every running instance gets an A record <instance>.<siteName>.<domain> (siteName in machine.toml, default hostName), plus
# <siteName>.<domain> and incus.<siteName>.<domain> for this server and arcane.<siteName>.<domain> as an alias of docker.
# The records live in the DNS of the domain controller (samba-tool dns, as the controller's own machine account, no password).
# The prefix keeps two servers in one domain (a second domain controller replicates the zone) from fighting over `docs` and `zoraxy`.
# sync shows what it would add, change or remove and asks; it only ever touches names under <siteName>.<domain>, never anything else.
# raw: the names in the zone as name<TAB>type<TAB>value, no header (hs sys dns list). sync --plain: the changes it would make as act<TAB>name<TAB>type<TAB>value<TAB>old
# (act = add|change|remove), nothing changed, nothing printed when the names are up to date (hs sys dns plan, scripts/dns-change.sh).
# HS_MACHINE_FILE, HS_SITE_NAME_FILE, HS_DC (controller instance, default: found by lib/dc.sh), HS_INCUS, HS_MANAGE_CT, HS_HOST_IP point tests at stand-ins.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/machine.sh"
. "$here/lib/dc.sh"
machine=$(machine_file)
site_file=${HS_SITE_NAME_FILE:-/etc/hs/site-name}
inc=${HS_INCUS:-incus}
dc=$(dc_name)
manage_ct=${HS_MANAGE_CT:-$here/manage-ct.sh}

usage() { say "usage: hs dns list"; say "       hs dns sync [--yes] [--dry-run]"; exit 1; }
# a hand-made record (the wildcard *.<siteName> of the gateway proxy, capabilities/gateway/NOTES.md) is never planned, changed or removed
is_hand() { [[ $1 == \** ]]; }
interactive() { [ -t 0 ] && [ -t 1 ] && [ -z "${HS_CALLER:-}" ] || [ -n "${HS_GUIDED_TTY:-}" ]; }

# adDomain = { realm = "AD.HOME.LAN", workgroup = "HOME" }
realm=$(machine_get adDomain.realm 2>/dev/null | tr 'A-Z' 'a-z' || true)
[ -n "$realm" ] || fail "There is no domain (adDomain) in machine.toml, so there is no DNS to put names into."
site=$(tr -d ' \r\n' <"$site_file" 2>/dev/null | tr 'A-Z' 'a-z' || true)
[[ "$site" =~ ^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$ ]] || fail "$(t "siteName '%s' is not a name for DNS (letters, digits, hyphen). Set siteName in machine.toml." "$site")"

# samba-tool dns <verb> 127.0.0.1 <zone> <args> as the controller's machine account
sam() { local verb=$1; shift; "$inc" exec "$dc" -- samba-tool dns "$verb" 127.0.0.1 "$realm" "$@" -P </dev/null; }

host_ip=${HS_HOST_IP:-$(ip -4 -o addr show br0 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4; exit }')}

# name<TAB>type<TAB>value, names relative to the zone
desired() {
  local name state ip
  [ -n "$host_ip" ] && { printf '%s\tA\t%s\n' "$site" "$host_ip"; printf 'incus.%s\tA\t%s\n' "$site" "$host_ip"; }
  local have_docker=false
  while IFS=$'\t' read -r name _ state ip _; do
    [ "$state" = Running ] && [ -n "$ip" ] && [ "$ip" != - ] || continue
    [ "$name" != "$dc" ] || continue   # the controller has its own record
    [ "$name" != docker ] || have_docker=true
    printf '%s.%s\tA\t%s\n' "$name" "$site" "$ip"
  done < <(bash "$manage_ct" --list)
  if $have_docker; then printf 'arcane.%s\tCNAME\tdocker.%s.%s\n' "$site" "$site" "$realm"; fi
}

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
  sync)
    yes=false; dry=false; plain=false
    for a in "$@"; do case "$a" in --yes) yes=true ;; --dry-run) dry=true ;; --plain) plain=true ;; *) usage ;; esac; done
    "$inc" info "$dc" >/dev/null 2>&1 || fail "$(t "The domain controller '%s' does not exist here." "$dc")"
    declare -A want=() have=()
    while IFS=$'\t' read -r n t v; do want["$n|$t"]=$v; done < <(desired)
    while IFS=$'\t' read -r n t v; do have["$n|$t"]=$v; done < <(actual)
    plan=()
    for k in $(printf '%s\n' "${!want[@]}" | sort); do
      ! is_hand "$k" || continue
      if [ -z "${have[$k]+x}" ]; then plan+=("add|$k|${want[$k]}|")
      elif [ "${have[$k]}" != "${want[$k]}" ]; then plan+=("change|$k|${want[$k]}|${have[$k]}"); fi
    done
    for k in $(printf '%s\n' "${!have[@]}" | sort); do
      ! is_hand "$k" || continue
      [ -n "${want[$k]+x}" ] || plan+=("remove|$k|${have[$k]}|")
    done
    if $plain; then
      for p in "${plan[@]+"${plan[@]}"}"; do IFS='|' read -r act n t v old <<<"$p"; printf '%s\t%s.%s\t%s\t%s\t%s\n' "$act" "$n" "$realm" "$t" "$v" "$old"; done
      exit 0
    fi
    if [ ${#plan[@]} -eq 0 ]; then ok "$(t 'The names under %s.%s are up to date (%s records).' "$site" "$realm" "${#want[@]}")"; exit 0; fi
    step "DNS names"
    { thead 'Action' 'Name' 'Type' 'Value'
      for p in "${plan[@]}"; do IFS='|' read -r act n t v old <<<"$p"
        printf '%s\t%s.%s\t%s\t%s\n' "$(_tr "$act")" "$n" "$realm" "$t" "${v}${old:+  (was $old)}"; done; } | table
    if $dry; then note "Dry run: nothing was changed. Apply with: hs dns sync"; exit 0; fi
    if ! $yes; then
      interactive || fail "Nothing is changed without --yes when there is no terminal."
      confirm "$(t 'Apply these %s changes to the DNS?' "${#plan[@]}")" || fail "cancelled"
    fi
    failed=0
    for p in "${plan[@]}"; do IFS='|' read -r act n t v old <<<"$p"
      rc=0
      case "$act" in
        add)    sam add "$n" "$t" "$v" >/dev/null 2>&1 || rc=$? ;;
        change) sam update "$n" "$t" "$old" "$v" >/dev/null 2>&1 || rc=$? ;;
        remove) sam delete "$n" "$t" "$v" >/dev/null 2>&1 || rc=$? ;;
      esac
      if [ "$rc" -ne 0 ]; then warn "$(t 'Could not %s %s.%s (%s)' "$act" "$n" "$realm" "$t")"; failed=$((failed + 1)); fi
    done
    if [ "$failed" -gt 0 ]; then
      note "Check that the domain controller is running (hs ct list), then run again: hs dns sync"
      fail "$(t '%s of %s changes failed.' "$failed" "${#plan[@]}")"
    fi
    ok "$(t '%s changes made.' "${#plan[@]}")"
    note "Show the result with: hs dns list" ;;
  *) usage ;;
esac
