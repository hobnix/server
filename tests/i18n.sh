#!/usr/bin/env bash
# The German catalog covers every text the core scripts print:
#   bash tests/run.sh i18n          (also lists the missing texts: bash tests/i18n.sh --missing)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
CATALOG=$SCRIPTS/lib/i18n/de.tsv
# the scripts whose messages are translated (the machine-readable lists they print are not)
CORE="services state remote fans providers/docker/arcane lib/hs jobs pkg lib/ui machine-sync selftest secrets ct-guided user-guided share-restore config system net-ip health report migrate first-run ct-access users-show share-perm disk-replace doctor recipe rebuild update sync-shares unlock migrate-check temp-disk backup manage-pool status disk-health share-snap share-snap-guided share-cleanup cleanup docs-build bulk-sync motd snapshots-auto smoke manage-ct manage-users ports ct-update-all ssh-key node dns gateway dc-cert power update-preview manage-shares create-share mac jobs lib/locked unifi share-cache monitor notify recipes/_lib recipes/cloudflared recipes/docker recipes/domain recipes/immich recipes/tdarr recipes/arr recipes/sabnzbd recipes/qbittorrent recipes/seerr recipes/uchiyomi recipes/_media recipes/authentik recipes/jellyfin recipes/monitoring recipes/ntfy recipes/pelican recipes/catalyst-panel recipes/catalyst-node recipes/uptime-kuma recipes/paperclip recipes/homeassistant recipes/zoraxy recipes/bulwark recipes/stalwart recipes/synapse recipes/livekit recipes/matrix-hook recipes/sunshine recipes/steamos recipes/upload-storage ../capabilities/games/pc ../capabilities/posters/generate-poster-guided cache-mover vault lib/vault ext notify-channel docs-verified"

keys=$(python3 - "$SCRIPTS" $CORE <<'PY'
import re,sys
sys.stdout.reconfigure(newline='\n')   # Windows Python would write CRLF and every key would miss
scripts=sys.argv[1]
call=r'(?:ok|note|warn|fail|step|say|die|ask|ask_secret|confirm|spin|choose|plt|kv|line|status_line|in_ct|_tr|setting [A-Z]+)'
pat_static=re.compile(r'(?<![A-Za-z0-9_])'+call+r' "([^"$`\\]+)"')
pat_static1=re.compile(r"(?<![A-Za-z0-9_])"+call+r" '([^'$`\\]+)'")
pat_t=re.compile(r"(?<![A-Za-z0-9_.-])t '([^']+)'")
pat_t2=re.compile(r'(?<![A-Za-z0-9_.-])t "([^"$`\\]+)"')
keys=set()
for name in sys.argv[2:]:
    path=f'{scripts}/{name}.sh'
    if name.startswith('recipes/'):   # the recipes live in packages/<name>/run.sh
        import os
        pk=f'{scripts}/../packages/{name[8:]}/run.sh'
        if os.path.exists(pk):   # the shared helpers (_lib, _media) stay in scripts/recipes/
            path=pk
    raw=open(path).read()
    for m in re.finditer(r'^[ \t]*# i18n: (.+)$', raw, re.M):   # texts looked up at render time (table cells): listed by the script
        keys.update(k.strip() for k in m.group(1).split('|') if k.strip())
    s='\n'.join(l for l in raw.split('\n') if not l.lstrip().startswith('#'))
    for blk in re.finditer(r"say \"\$_l\"; done <<'EOF'\n(.*?)\nEOF\n", s, re.S):
        keys.update(l for l in blk.group(1).split('\n') if l.strip())
    for blk in re.finditer(r"(?<![A-Za-z0-9_])thead((?: '[^'$`\\]+')+)", s):
        keys.update(re.findall(r"'([^']+)'", blk.group(1)))
    for m in re.finditer(r'(?<![A-Za-z0-9_])ask_yes "[^"]*" "([^"$`\\]+)"', s):   # ask_yes <yes-flag> "question"
        keys.add(m.group(1))
    for m in re.finditer(r'(?<![A-Za-z0-9_])status_line "[^"]+" "([^"$`\\]+)"', s):   # the value of status_line is translated too
        keys.add(m.group(1))
    for pat in (pat_static,pat_static1,pat_t,pat_t2):
        keys.update(m.group(1) for m in pat.finditer(s))
# lines the interface reads or machine output: never translated
skip=('Plan','Command','Note:','ALL DATA','Dry run','Current array','layout:','state:','not created yet')
for k in sorted(keys):
    if k.strip() and not k.lstrip().startswith(skip) and k.strip() != '-':
        print(k)
PY
)

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
norec=""; for f in "$ROOT"/packages/*/run.sh; do grep -q '^# recipe\.de: ' "$f" || norec="$norec $(basename "$(dirname "$f")")"; done
check_eq "every recipe has a German description (# recipe.de:)" "" "$norec"
check_out "hs recipe --list speaks German" "Rezepte" env HS_LANG=de bash "$SCRIPTS/recipe.sh" --list
check_out "hs recipe --list is English by default" "Recipes" bash "$SCRIPTS/recipe.sh" --list

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
