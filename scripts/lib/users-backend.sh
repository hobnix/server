# shellcheck shell=bash
# Which back end holds the users and groups of this server (docs/PLAN-portable-install.md, #575).
#
#   users_backend     prints "ad" when the capability ad is on (adDomain is set: the users live on the domain controller), else "local"
#                     (Unix accounts with a Samba password, scripts/lib/users-local.sh)
#
# Test knob: HS_USERS_BACKEND (ad|local), and the knobs of capability.sh.
. "${BASH_SOURCE[0]%/*}/capability.sh"

users_backend() {
  case "${HS_USERS_BACKEND:-}" in ad|local) echo "$HS_USERS_BACKEND"; return 0 ;; esac
  if capability_on ad; then echo ad; else echo local; fi
}
