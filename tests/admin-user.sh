#!/usr/bin/env bash
# admin_user (scripts/lib/admin.sh): the admin account name from /etc/hs/admin-user, "adminuser" without it. No root, no server.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=scripts/lib/admin.sh
. "$SCRIPTS/lib/admin.sh"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

export HS_ADMIN_USER_FILE="$T/none"
check_eq "no file: adminuser" adminuser "$(admin_user)"
: > "$T/empty"
HS_ADMIN_USER_FILE="$T/empty"
check_eq "empty file: adminuser" adminuser "$(admin_user)"
printf 'anna' > "$T/admin-user"
HS_ADMIN_USER_FILE="$T/admin-user"
check_eq "file without newline: anna" anna "$(admin_user)"
printf 'anna\n' > "$T/admin-user"
check_eq "file with newline: anna" anna "$(admin_user)"

finish
