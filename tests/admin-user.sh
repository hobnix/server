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

# no script spells the name out: they ask admin_user (comments, the lib itself and the files of other work are left out)
left=$(cd "$ROOT" && git grep -n adminuser -- scripts/ ':!scripts/lib/admin.sh' ':!scripts/dev' ':!scripts/web-serve.py' ':!scripts/lib/registry.tsv' \
  ':!scripts/manage-pool.sh' ':!scripts/create-share.sh' |
  grep -Ev '^[^:]+:[0-9]+:[[:space:]]*#' || true)
check_eq "no literal adminuser in the scripts" "" "$left"

# sync-shares hands the files over to the configured admin (fakes as in tests/sync-shares.sh)
BIN=$T/bin; mkdir -p "$BIN" "$T/fast/shares/notes"
export CALLS=$T/calls; : > "$CALLS"
printf '#!/usr/bin/env bash\ncase "$*" in "conf listshares"|"conf getparm "*) ;; *) echo "net $*" >> "$CALLS" ;; esac\n' > "$BIN/net"
printf '#!/usr/bin/env bash\ncase "$*" in *security*) echo USER ;; esac\n' > "$BIN/testparm"
printf '#!/usr/bin/env bash\ncase "$*" in\n  *"-d 1 fast/shares") printf "fast/shares\nfast/shares/notes\n" ;;\n  "list -H -o name fast") echo fast ;;\n  *) exit 1 ;;\nesac\n' > "$BIN/zfs"
printf '#!/usr/bin/env bash\necho root\n' > "$BIN/stat"
for c in chown chmod find; do printf '#!/usr/bin/env bash\necho "%s $*" >> "$CALLS"\n' "$c" > "$BIN/$c"; done
chmod +x "$BIN"/*
printf 'anna\n' > "$T/admin-user"
PATH=$BIN:$PATH HS_LANG=en HS_PLAIN=1 HS_FAST=$T/fast HS_ADMIN_USER_FILE="$T/admin-user" bash "$SCRIPTS/sync-shares.sh" --fix-owner >/dev/null 2>&1 || true
check_eq "sync-shares: chown to anna" "1" "$(grep -c '^chown anna:users ' "$CALLS" || true)"
check_eq "sync-shares: nothing to adminuser" "0" "$(grep -c 'adminuser' "$CALLS" || true)"
