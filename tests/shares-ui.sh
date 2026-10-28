#!/usr/bin/env bash
# manage-shares.sh, create-share.sh, recipe.sh, mac.sh and `hs job follow` after their move to lib/ui.sh: the lines the
# interface reads (--list, --principals, --acl, the dry-run plans, the Samba/ZFS calls) are exactly as before, the messages
# for people use the styled helpers (plain text here), failures still exit 1. Stand-ins for net, sharesec, wbinfo, zfs,
# incus, systemctl and journalctl; no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=tests/lib-standins.sh
. "$(dirname "$0")/lib-standins.sh"
export TZ=UTC HS_LANG=en HS_PLAIN=1 HS_STATE_DIR=$WORK/state HS_LOCK=$WORK/lock HS_BULK_TYPE_FILE=$WORK/no-bulk-type
MS="bash $SCRIPTS/manage-shares.sh"; CS="bash $SCRIPTS/create-share.sh"

echo "-- manage-shares: what the interface reads is unchanged"
check_eq "--list: name, kind, path, cache, bytes, measured (empty = live)" "docs	shares	/bulk/shares/docs	-	1234	
media	sensitive	/bulk/sensitive/media	-	99	" "$($MS --list)"
check_eq "--principals: sid, name, kind (noise groups left out)" "S-1-1-0	Everyone	group
S-1-5-21-1-512	Domain Admins	group
S-1-5-21-1-513	Staff	group
S-1-5-21-1-1000	HOME\\anna	user" "$($MS --principals)"
check_eq "--acl: sid, name, kind, level" "S-1-1-0	Everyone	group	read
S-1-5-21-1-1000	HOME\\anna	user	write
S-1-5-21-1-512	HOME\\Domain Admins	group	full
S-1-5-21-1-2000	S-1-5-21-1-2000	unknown	denied" "$($MS docs --acl)"
check_eq "--set --dry-run: the plan the interface shows" "Access to 'docs' afterwards:
  read   Everyone
  full   HOME\\Domain Admins
  read   HOME\\anna" "$($MS docs --set S-1-5-21-1-1000=read S-1-5-21-1-2000=none --dry-run)"
check_eq "--rename --dry-run: the plan" "Rename 'docs' to 'newdocs':
  dataset  bulk/shares/docs -> bulk/shares/newdocs
  Samba    share 'docs' is replaced by 'newdocs' (same settings and permissions)
  note     old backup snapshots keep the old path; the backup switch moves to the new name
(dry run, nothing changed)" "$($MS docs --rename newdocs --dry-run)"
: > "$LOG"
$MS docs --rename newdocs >/dev/null
check_eq "a rename makes the same calls as before" "net conf showshare docs
net conf listshares
zfs list -H -o name bulk/shares/docs
zfs list -H -o name bulk/shares/newdocs
incus list -c n -f csv
flock -w 600 9
smbcontrol smbd close-share docs
zfs rename bulk/shares/docs bulk/shares/newdocs
sharesec docs --view
net conf showshare docs
net conf addshare newdocs /bulk/shares/newdocs
net conf setparm newdocs read only no
sharesec newdocs --replace S-1-1-0:ALLOWED/0x0/READ,S-1-5-21-1-1000:ALLOWED/0x0/CHANGE,S-1-5-21-1-512:ALLOWED/0x0/FULL,S-1-5-21-1-2000:DENIED/0x0/FULL
net conf delshare docs" "$(grep -v 'wbinfo\|getparm docs path' "$LOG")"

echo "-- manage-shares: messages for people"
check_out "a good change says so" "✓ Saved\. It applies to new connections" $MS docs --set S-1-5-21-1-1000=read
check_out "a rename says where it ends up" "✓ Done: 'docs' is now 'newdocs'" $MS docs --rename newdocs
check_out "an unknown share" "✗ No share called 'nope'" $MS nope --acl
check_eq "and exit status 1" "1" "$($MS nope --acl >/dev/null 2>&1; echo $?)"
check_out "a bad level" "✗ unknown level 'bad'" $MS docs --set S-1-5-21-1-1000=bad
check_out "a bad argument" "✗ expected <sid>=<level>, got 'bogus'" $MS docs --set bogus
check_out "nobody with full access: the reason and the hint" "! Not possible: nobody would have full access to 'media'" $MS media --set S-1-5-21-1-512=read
check_eq "that also exits 1" "1" "$($MS media --set S-1-5-21-1-512=read >/dev/null 2>&1; echo $?)"
check_out "a name that exists" "✗ A share called 'media' exists already\." $MS docs --rename media
check_out "a name that is not usable" "✗ 'bad name' is not a usable name" $MS docs --rename 'bad name'
check_out "a reserved name" "✗ 'shares' is a reserved name\." $MS docs --rename shares
check_out "the same name" "✗ That is the name it has already\." $MS docs --rename docs
check_out "ZFS: nothing to measure" "Nothing to measure" $MS --measure
echo snapraid > "$WORK/sr-type"; mkdir -p "$WORK/state"
printf '/bulk/shares/docs\t5\n/bulk/sensitive/media\t77\n' > "$WORK/state/share-sizes"
HS_BULK_TYPE_FILE=$WORK/sr-type $MS --measure docs >/dev/null 2>&1 || true
check_eq "--measure <share>: the other share keeps its size, the measured one is rewritten" "1 77" "$(grep -c '^/bulk/shares/docs' "$WORK/state/share-sizes") $(awk -F'\t' '$1 == "/bulk/sensitive/media" { print $2 }' "$WORK/state/share-sizes")"
check_eq "--measure <share>: the old size of that share is gone" "0" "$(grep -c '^/bulk/shares/docs.5$' "$WORK/state/share-sizes" || true)"
check_out "the overview has a heading per share" "── docs  \(/bulk/shares/docs\) ──" $MS
check_out "German" "✗ Keine Freigabe namens 'nope'" env HS_LANG=de $MS nope --acl
check_out "German: the plan stays English" "Rename 'docs' to 'newdocs':" env HS_LANG=de $MS docs --rename newdocs --dry-run

echo "-- create-share"
check_out "no name: the usage" "usage: hs share add <name>" $CS
check_out "an invalid name" "✗ invalid name 'bad name'" $CS 'bad name'
check_out "an option is not a name" "✗ invalid name '--sensitive'" $CS --sensitive
check_out "an unknown container" "✗ 'nope' does not exist\." $CS notes --ct nope /data
check_out "a bad --as" "usage: hs share add" $CS notes --ct web /data --as abc
check_eq "exit status 1" "1" "$($CS 'bad name' >/dev/null 2>&1; echo $?)"
check_out "German" "✗ ungültiger Name 'bad name'|✗ Ungültiger Name 'bad name'" env HS_LANG=de $CS 'bad name'

echo "-- recipe"
check_out "the list has a heading and a table" "Recipes \(run with: hs recipe <name>\):" bash "$SCRIPTS/recipe.sh" --list
check_out "the table has a header" "RECIPE +WHAT" bash "$SCRIPTS/recipe.sh" --list
check_out "an unknown recipe says so, then lists" "! No recipe called 'nope'\." bash "$SCRIPTS/recipe.sh" nope
check_eq "and exits 1" "1" "$(bash "$SCRIPTS/recipe.sh" nope >/dev/null 2>&1; echo $?)"
check_out "a helper is not a recipe" "! No recipe called '_lib'\." bash "$SCRIPTS/recipe.sh" _lib
check_out "German" "! Kein Rezept namens 'nope'\." env HS_LANG=de bash "$SCRIPTS/recipe.sh" nope

echo "-- mac"
cat > "$BIN/incus" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "list -c n -f csv") printf 'one\ntwo\nthree\n' ;;
  "config device get one eth0 hwaddr") echo 00:16:3e:00:00:01 ;;
  "config device get"*) exit 1 ;;
  "config get two volatile.eth0.hwaddr") echo 00:16:3e:00:00:02 ;;
  "config get three volatile.eth0.hwaddr") ;;
  "config device override two eth0 hwaddr=00:16:3e:00:00:02") ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
FAKE
out=$(bash "$SCRIPTS/mac.sh" 2>&1)
check_eq "mac: one line per container, then the hint" "    one: 00:16:3e:00:00:01 (already pinned)
  ✓ two: 00:16:3e:00:00:02 pinned
  ! three: no MAC yet (never started?), skipped
    Give each new one a fixed IP: hs net ip <name> set, or in UniFi under Client Devices." "$out"
check_out "mac, German" "! three: noch keine MAC" env HS_LANG=de bash "$SCRIPTS/mac.sh" three

echo "-- hs job follow"
# systemctl: ActiveState is 'active' for the first two asks, then 'inactive'; journalctl prints three lines and waits
cat > "$BIN/systemctl" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = show ] || exit 0
unit=$2; prop=$4
case "$unit" in hs-job-gone.service) [ "$prop" = LoadState ] && echo not-found; exit 0 ;; esac
case "$prop" in
  LoadState) echo loaded ;;
  Description) echo "Parity sync of the bulk pool" ;;
  ActiveEnterTimestamp) echo "Mon 2026-10-05 04:00:00 UTC" ;;
  InactiveEnterTimestamp) echo "Mon 2026-10-05 04:02:05 UTC" ;;
  ActiveState)
    n=$(cat "$WORK_COUNT" 2>/dev/null || echo 0); echo $((n + 1)) > "$WORK_COUNT"
    if [ "$n" -lt 2 ]; then echo active; else echo inactive; fi ;;
  Result) echo "${FAKE_RESULT:-success}" ;;
  ExecMainStatus) echo "${FAKE_STATUS:-0}" ;;
esac
FAKE
cat > "$BIN/journalctl" <<'FAKE'
#!/usr/bin/env bash
case "$FAKE_JOURNAL" in
  none) ;;
  *) printf '2026-10-05T04:00:01+0000 host sync[1]: pass 1 of 3\n2026-10-05T04:01:00+0000 host sync[1]: pass 2 of 3\n2026-10-05T04:02:04+0000 host sync[1]: done\n' ;;
esac
FAKE
chmod +x "$BIN/systemctl" "$BIN/journalctl"
export WORK_COUNT=$WORK/count HS_FOLLOW_EVERY=0.2
J="bash $SCRIPTS/jobs.sh"
echo 0 > "$WORK_COUNT"
out=$($J hs-job-sync --follow 2>&1); rc=$?
check_out "the header names the job and the unit" "── Parity sync of the bulk pool ──" echo "$out"
check_out "the header says it is running, since when" "running since 05\.10\. 04:00" echo "$out"
check_out "the journal lines follow" "    2026-10-05T04:01:00\+0000 host sync\[1\]: pass 2 of 3" echo "$out"
check_out "a finished job: ok, exit status, how long it took" "✓ Finished successfully \(exit status 0\) after 2:05" echo "$out"
check_eq "and exit status 0" "0" "$rc"
echo 0 > "$WORK_COUNT"
out=$(FAKE_RESULT=exit-code FAKE_STATUS=3 $J hs-job-sync --follow 2>&1); rc=$?
check_out "a failed job: failed and its exit status" "✗ Failed: exit-code, exit status 3 after 2:05" echo "$out"
check_eq "and exit status 1" "1" "$rc"
echo 0 > "$WORK_COUNT"
check_out "German" "Erfolgreich beendet \(Exit-Status 0\)" env HS_LANG=de $J hs-job-sync --follow
echo 5 > "$WORK_COUNT"
check_out "a finished unit shows its journal and the result at once" "pass 1 of 3" $J hs-job-sync --follow
check_out "a unit that is gone and has no journal" "✗ No job called 'hs-job-gone.service'\." env FAKE_JOURNAL=none $J hs-job-gone --follow
check_out "without a name and nothing running" "✗ No job is running\." $J --follow
check_eq "the plain journal view is unchanged (no header)" "" "$($J hs-job-sync 2>&1 | grep -c '──' | sed 's/^[1-9].*/x/;s/^0$//')"

finish
