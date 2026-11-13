#!/usr/bin/env bash
# The two checks of rebuild.sh before a build: bulkType in machine.toml must match the installed layout (/etc/hs/bulk-type), and the
# pool fast must exist. The functions are cut out of rebuild.sh and run with fake zpool and knobs; nothing is built.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en
. "$SCRIPTS/lib/ui.sh"
. "$SCRIPTS/lib/machine.sh"
. "$SCRIPTS/lib/capability.sh"
for fn in bulk_type_check fast_check; do
  eval "$(sed -n "/^$fn() {/,/^}/p" "$SCRIPTS/rebuild.sh")"
done
export HS_MACHINE_FILE=$WORK/machine.toml HS_BULK_TYPE_FILE=$WORK/bulk-type HS_CAPABILITIES_FILE=$WORK/capabilities HS_STATE_DIR=$WORK/state
run() { rc=0; out=$( ( "$@" ) 2>&1 ) || rc=$?; }

echo "-- bulkType"
printf 'role = "homeserver"\nbulkType = "snapraid"\n' > "$HS_MACHINE_FILE"
echo snapraid > "$HS_BULK_TYPE_FILE"
run bulk_type_check; check_eq "same type: fine" 0 "$rc"
echo zfs > "$HS_BULK_TYPE_FILE"
run bulk_type_check; check_eq "switched to snapraid: refused" 1 "$rc"
grep -q 'installed with "zfs"' <<<"$out" && grep -q "reinstall" <<<"$out" && pass "says what and what to do" || fail "message: $out"
printf 'role = "homeserver"\n' > "$HS_MACHINE_FILE"
run bulk_type_check; check_eq "no bulkType line means zfs: fine" 0 "$rc"
rm -f "$HS_BULK_TYPE_FILE"
run bulk_type_check; check_eq "no installed type yet: fine" 0 "$rc"

echo "-- the pool fast"
mkdir -p "$WORK/bin"; export PATH=$WORK/bin:$PATH
printf 'storage\n' > "$HS_CAPABILITIES_FILE"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/bin/zpool"; /usr/bin/chmod +x "$WORK/bin/zpool"
run fast_check; check_eq "no pool fast: only a warning" 0 "$rc"
grep -q "hs pool fast add" <<<"$out" && grep -q "zfs-import-fast" <<<"$out" && pass "says what may fail and how to create it" || fail "message: $out"
printf '#!/usr/bin/env bash
[ "$1" = import ] && printf "   pool: fast\n     id: 1\n" && exit 0
exit 1
' > "$WORK/bin/zpool"
run fast_check; check_eq "fast offered by zpool import (Case A): fine" 0 "$rc"
[ -z "$out" ] && pass "and no message" || fail "message: $out"
printf '#!/usr/bin/env bash
exit 1
' > "$WORK/bin/zpool"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/zpool"
run fast_check; check_eq "pool fast exists: fine" 0 "$rc"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/bin/zpool"
: > "$HS_CAPABILITIES_FILE"
run fast_check; check_eq "storage is off: not checked" 0 "$rc"
[ -z "$out" ] && pass "storage off: no message" || fail "message: $out"
finish
