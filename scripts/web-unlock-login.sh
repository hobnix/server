#!/usr/bin/env bash
# help: let the locked-out web sign-in try again at once (restarts hs-web; signed-in sessions stay)
# help.de: die gesperrte Anmeldung im Browser sofort wieder freigeben (startet hs-web neu; angemeldete Sitzungen bleiben)
# args: [--dry-run]
# The sign-in lockout (a client address after five wrong tries) lives in the memory of hs-web, so a restart clears it. Sessions survive the restart
# through /run/hs-web/sessions.json. docs/PLAN-web-auth.md. Test knobs: HS_SYSTEMCTL (the systemctl binary), HS_WEB_UNLOCK_NOROOT=1 (skip the root check).
set -uo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
dry=0
for a in "$@"; do
  case "$a" in
    --dry-run) dry=1 ;;
    *) fail "$(t 'Usage: hs web unlock-login [--dry-run]')" ;;
  esac
done
sc=${HS_SYSTEMCTL:-systemctl}
if [ "$dry" = 1 ]; then
  note "$(t 'Would run: systemctl restart hs-web (clears the sign-in lockout; signed-in sessions stay). Nothing was changed.')"
  exit 0
fi
[ "$(id -u)" = 0 ] || [ -n "${HS_WEB_UNLOCK_NOROOT:-}" ] || fail "$(t 'This needs root: sudo hs web unlock-login')"
step "$(t 'Restarting the web interface to clear the sign-in lockout')"
"$sc" restart hs-web || fail "$(t 'Could not restart hs-web. See: journalctl -u hs-web')"
ok "$(t 'The sign-in is open again. Signed-in sessions stay.')"
