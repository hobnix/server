#!/usr/bin/env bash
# The German catalog covers every text the core scripts print:
#   bash tests/run.sh i18n          (also lists the missing texts: bash tests/i18n.sh --missing)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
CATALOG=$SCRIPTS/lib/i18n/de.tsv
# the scripts whose messages are translated (the machine-readable lists they print are not)
CORE="services state remote fans providers/docker/arcane lib/hs jobs pkg lib/ui machine-sync selftest secrets ct-guided user-guided share-restore config system net-ip health report migrate first-run ct-access users-show share-perm disk-replace doctor recipe rebuild update sync-shares unlock migrate-check temp-disk backup manage-pool status disk-health share-snap share-snap-guided share-cleanup cleanup docs-build bulk-sync motd snapshots-auto smoke manage-ct manage-users ports ct-update-all ssh-key node dns gateway gateway-setup dc-cert power update-preview changes manage-shares create-share mac jobs lib/locked unifi share-cache monitor notify recipes/_lib recipes/_media cache-mover vault lib/vault ext notify-channel docs-verified"

files=$(for n in $CORE; do echo "$SCRIPTS/$n.sh"; done)
keys=$(python3 -I "$SCRIPTS/dev/i18n-keys.py" $files)

if [ "${1:-}" = --missing ]; then
  while IFS= read -r k; do
    grep -qF -- "$(printf '%s\t' "$k")" "$CATALOG" || printf '%s\n' "$k"
  done <<<"$keys"
  exit 0
fi

echo "-- the catalog"
check "the catalog exists and has entries" test -s "$CATALOG"
dups=$(cut -f1 "$CATALOG" | grep -v '^#' | grep -v '^$' | sort | uniq -d | head -3)
if [ -n "$dups" ]; then fail "no text is translated twice ($dups)"; else pass "no text is translated twice"; fi

missing=0; n=0
while IFS= read -r k; do
  [ -n "$k" ] || continue
  n=$((n + 1))
  if ! grep -qF -- "$(printf '%s\t' "$k")" "$CATALOG"; then
    missing=$((missing + 1)); [ "$missing" -le 15 ] && echo "        missing: $k"
  fi
done <<<"$keys"
check_eq "all $n texts of the core scripts are translated ($missing missing)" 0 "$missing"

# the same %s / %d in the translation, in the same number
bad=0
while IFS=$'\t' read -r k v; do
  [ -n "$k" ] && [ "${k:0:1}" != "#" ] || continue
  a=$(grep -o '%[sd]' <<<"$k" | wc -l); b=$(grep -o '%[sd]' <<<"$v" | wc -l)
  [ "$a" = "$b" ] || { bad=$((bad + 1)); echo "        placeholders differ: $k"; }
done < "$CATALOG"
check_eq "every translation keeps its placeholders" 0 "$bad"

# entries nobody uses any more
stale=0
while IFS=$'\t' read -r k v; do
  [ -n "$k" ] && [ "${k:0:1}" != "#" ] || continue
  grep -qxF -- "$k" <<<"$keys" || { stale=$((stale + 1)); [ "$stale" -le 10 ] && echo "        unused: $k"; }
done < "$CATALOG"
check_eq "no translation is left over ($stale unused)" 0 "$stale"

echo "-- descriptions"
nohelp=""; for f in "$SCRIPTS"/*.sh; do grep -q '^# help\.de: ' "$f" || nohelp="$nohelp $(basename "$f")"; done
check_eq "every command has a German description (# help.de:)" "" "$nohelp"
FIX=$ROOT/tests/fixtures/pkgtree/packages   # the real recipes are checked in hobnix/recipes (tests/i18n.sh there)
check_out "hs recipe --list speaks German" "Rezepte" env HS_LANG=de HS_RECIPES_DIR="$FIX" bash "$SCRIPTS/recipe.sh" --list
check_out "hs recipe --list is English by default" "Recipes" env HS_RECIPES_DIR="$FIX" bash "$SCRIPTS/recipe.sh" --list

echo "-- the language switch"
export HS_PLAIN=1
check_out "English by default" "Number:" bash -c ". $SCRIPTS/lib/ui.sh; t 'Number:'"
check_out "HS_LANG=de translates" "Nummer:" env HS_LANG=de bash -c ". $SCRIPTS/lib/ui.sh; t 'Number:'"
check_out "a text without translation stays English" "never translated" env HS_LANG=de bash -c ". $SCRIPTS/lib/ui.sh; warn 'never translated'"
check_out "values are filled in" "Eingabe behält 10G" env HS_LANG=de bash -c ". $SCRIPTS/lib/ui.sh; t 'enter keeps %s' 10G"
check_out "an unknown language falls back to English" "Number:" env HS_LANG=xx bash -c ". $SCRIPTS/lib/ui.sh; t 'Number:'"
mkdir -p "$WORK/etc"
check "the machine setting is read from /etc/hs/language" bash -c "mkdir -p $WORK/etc; echo de > $WORK/etc/language; export HS_ETC_DIR=$WORK/etc; . $SCRIPTS/lib/ui.sh; [ \"\$(t 'Number:')\" = 'Nummer:' ]"

echo "-- machine-readable output stays English"
export HS_LANG=de HS_TEST_LOOP=1
list=$(bash "$SCRIPTS/manage-pool.sh" --list-disks 2>&1 || true)
if grep -qE 'Nummer|Eingabe' <<<"$list"; then fail "the disk list is not translated"; else pass "the disk list is not translated"; fi

finish
