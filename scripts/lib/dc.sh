# shellcheck shell=bash
# Which instance of this server is the domain controller. Scripts call dc_name instead of writing dc1:
# the first server of a domain has "dc1", a second server that joins it has "dc2" (hs recipe domain --join).
#
#   dc_name     prints the instance name. In this order:
#                 1. HS_DC (environment, for a single call or a test)
#                 2. dcName in machine.toml (only needed when the instance has some other name)
#                 3. an instance named dc1, else dc2, else the first one named dc<number>
#                 4. dc1 (nothing found: the scripts say that the controller does not exist here)
# Test knobs: HS_DC, HS_INCUS, HS_MACHINE_FILE.
type machine_get >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/machine.sh"
dc_name() {
  local inc=${HS_INCUS:-incus} n names
  if [ -n "${HS_DC:-}" ]; then echo "$HS_DC"; return 0; fi
  n=$(machine_get dcName 2>/dev/null || true)
  if [ -n "$n" ]; then echo "$n"; return 0; fi
  names=$("$inc" list -c n -f csv 2>/dev/null </dev/null | grep -E '^dc[0-9]*$' | sort || true)
  for n in dc1 dc2; do
    if grep -qx "$n" <<<"$names"; then echo "$n"; return 0; fi
  done
  n=$(sed -n '1p' <<<"$names")
  echo "${n:-dc1}"
}
