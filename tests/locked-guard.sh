#!/usr/bin/env bash
# hs update / hs rebuild refuse while the encrypted storage is locked (marker), before any
# git or nixos-rebuild call. No root: marker via HS_LOCKED_MARKER, stand-ins for git, sudo, nixos-rebuild.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test
BIN=$WORK/bin; mkdir -p "$BIN"
export HS_LOCKED_MARKER=$WORK/locked HS_FAKE_LOG=$WORK/fake.log
for c in nixos-rebuild git sudo; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$HS_FAKE_LOG"\n' "$c" > "$BIN/$c"; chmod +x "$BIN/$c"
done
export PATH="$BIN:$PATH"
: > "$HS_FAKE_LOG"

echo "-- locked"
touch "$HS_LOCKED_MARKER"
for cmd in update rebuild; do
  out=$(bash "$SCRIPTS/$cmd.sh" 2>&1) && rc=0 || rc=$?
  check_eq "$cmd exits 1" 1 "$rc"
  check "$cmd names hs unlock" grep -q "hs unlock" <<<"$out"
done
out=$(bash "$SCRIPTS/rebuild.sh" --verbose 2>&1) && rc=0 || rc=$?
check_eq "rebuild --verbose exits 1" 1 "$rc"
out=$(HS_LANG=de bash "$SCRIPTS/rebuild.sh" 2>&1) || true
check "German message" grep -q "gesperrt" <<<"$out"
check_eq "nothing was called" 0 "$(wc -l < "$HS_FAKE_LOG" | tr -d ' ')"

echo "-- unlocked"
rm -f "$HS_LOCKED_MARKER"
bash "$SCRIPTS/rebuild.sh" --verbose >/dev/null 2>&1 || true
check "rebuild --verbose reaches nixos-rebuild" grep -q "^nixos-rebuild switch" "$HS_FAKE_LOG"

finish
