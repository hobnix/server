#!/usr/bin/env bash
# help: pin the current MAC of containers (all, or the ones given)
# help.de: nagelt die aktuelle MAC-Adresse von Containern fest (alle, oder die angegebenen)
# args: [name...]
set -euo pipefail
. "$(dirname "$0")/lib/ui.sh"

if [ $# -eq 0 ]; then
  mapfile -t targets < <(incus list -c n -f csv)
else
  targets=("$@")
fi

[ ${#targets[@]} -gt 0 ] && [ -n "${targets[0]}" ] || { note "There are no instances yet. Make one with: hs ct add <name>"; exit 0; }
new=0
for c in "${targets[@]}"; do
  # Once pinned, Incus drops the volatile key and keeps the MAC on the device
  pinned=$(incus config device get "$c" eth0 hwaddr 2>/dev/null || true)
  if [ -n "$pinned" ]; then
    note "$(t '%s: %s (already pinned)' "$c" "$pinned")"
    continue
  fi
  mac=$(incus config get "$c" volatile.eth0.hwaddr)
  if [ -z "$mac" ]; then
    warn "$(t '%s: no MAC yet (never started?), skipped' "$c")"
    continue
  fi
  # eth0 from a profile needs `override`, a local eth0 needs `set`
  if ! incus config device override "$c" eth0 hwaddr="$mac" >/dev/null 2>&1 &&
     ! incus config device set "$c" eth0 hwaddr="$mac" >/dev/null 2>&1; then
    # the network card of a running VM can't be changed
    warn "$(t '%s: could not pin the MAC while it runs. Stop it (incus stop %s), run hs mac %s, start it again.' "$c" "$c" "$c")"
    continue
  fi
  ok "$(t '%s: %s pinned' "$c" "$mac")"
  new=$((new + 1))
done

if [ "$new" -gt 0 ]; then
  note "Give each new one a fixed IP: hs net ip <name> set, or in UniFi under Client Devices."
fi
