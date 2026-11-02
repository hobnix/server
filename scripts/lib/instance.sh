# shellcheck shell=bash
# Locked instances (docs/PLAN-docker-instances.md §1): the Incus key user.hs.managed_by names the capability that owns an instance.
# Only that capability may delete it or change its devices; it says so with HS_OWNER=<capability> in the environment of the call.
declare -F fail >/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/ui.sh"
instance_owner() {     # instance_owner <ct>: the owning capability, or nothing (also when Incus can't be asked)
  "${HS_INCUS:-incus}" query "/1.0/instances/$1" </dev/null 2>/dev/null | jq -r '.config["user.hs.managed_by"] // empty' 2>/dev/null || true
}
refuse_if_locked() {   # refuse_if_locked <ct> <action, already translated>: returns when allowed, else the reason on stderr and exit 1
  local owner; owner=$(instance_owner "$1")
  if [ -z "$owner" ] || [ "${HS_OWNER:-}" = "$owner" ]; then return 0; fi
  fail "$(t "%s owns '%s': %s is refused. Turn %s off under Settings, Capabilities, %s." "${owner^}" "$1" "$2" "${owner^}" "${owner^}")" >&2
}
