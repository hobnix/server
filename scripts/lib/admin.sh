# shellcheck shell=bash
# The name of the admin account (machine.toml: adminUser, default adminuser; docs/PLAN-local-users). Nix writes it to /etc/hs/admin-user.
#
#   admin_user     prints the name: the first line of the file, or "adminuser" when the file is missing or empty
#
# Scripts call this, never `machine_get adminUser` in a hot path and never the literal name. Test knob: HS_ADMIN_USER_FILE.

admin_user() {
  local f="${HS_ADMIN_USER_FILE:-/etc/hs/admin-user}" n=""
  [ ! -r "$f" ] || IFS= read -r n < "$f" || true
  echo "${n:-adminuser}"
}
