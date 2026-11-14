#!/usr/bin/env bash
# Staged apply: `hs sys rebuild pending` (scripts/pending-rebuild.sh) lists the machine.toml changes that wait for one rebuild; rebuild.sh keeps the
# copy it is measured against; the web banner's pure helpers (web/src/shell/pending.js).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en
T=$'\t'
export HS_STATE_DIR=$WORK/state HS_MACHINE_FILE=$WORK/machine.toml
mkdir -p "$HS_STATE_DIR"
P="bash $SCRIPTS/pending-rebuild.sh --list"

echo "-- the list"
printf 'hostName = "hs"\nsyncEveryHours = 12\ngpu = "nvidia"\n' > "$HS_MACHINE_FILE"
check_eq "no copy kept yet: nothing is listed" "" "$($P)"
cp "$HS_MACHINE_FILE" "$HS_STATE_DIR/machine.toml.built"
check_eq "same file: nothing waits" "" "$($P)"
printf 'hostName = "hs"\nsyncEveryHours = 6\nsmbAllow = ["10.0.0.0/24"]\n' > "$HS_MACHINE_FILE"
out=$($P)
check_eq "a changed value: key, built, now" "syncEveryHours${T}12${T}6" "$(grep '^syncEveryHours' <<<"$out")"
check_eq "a new option: built is -" "smbAllow${T}-${T}[\"10.0.0.0/24\"]" "$(grep '^smbAllow' <<<"$out")"
check_eq "a removed option: now is -" "gpu${T}\"nvidia\"${T}-" "$(grep '^gpu' <<<"$out")"
check_eq "an unchanged option is not listed" 0 "$(grep -c '^hostName' <<<"$out" || true)"
check_eq "three changes, sorted, no empty field" "3" "$(awk -F'\t' 'NF == 3 && $1 != "" && $2 != "" && $3 != "" { n++ } END { print n }' <<<"$out")"
printf 'not toml [[[\n' > "$HS_MACHINE_FILE"
check_eq "a file that does not parse: nothing is listed (the check says so elsewhere)" "" "$($P)"
rm -f "$HS_MACHINE_FILE"; check_eq "no machine.toml: nothing" "" "$($P)"

echo "-- one rebuild applies them all: rebuild.sh keeps the copy"
check "rebuild.sh copies machine.toml after a good switch" grep -q 'machine.toml.built' "$SCRIPTS/rebuild.sh"
check "registry row" grep -q "^sys${T}sys rebuild pending${T}pending-rebuild.sh${T}--list${T}" "$SCRIPTS/lib/registry.tsv"
check "READS has rebuild/pending" grep -qF -- '("rebuild", "pending")' "$SCRIPTS/web-serve.py"
check "smoke probes it" grep -q 'sys rebuild pending' "$SCRIPTS/smoke.sh"

echo "-- the banner"
if command -v node >/dev/null 2>&1; then
  node "$ROOT/tests/pending-rebuild.mjs" && pass "banner helpers and wiring" || fail "banner tests"
else skip "node is not installed: banner tests"; fi
finish
