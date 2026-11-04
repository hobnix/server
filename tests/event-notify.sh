#!/usr/bin/env bash
# The subscriber that turns events into push messages (scripts/event-notify.sh and event-notify.py): rules, the cursor, no loop on notify.*,
# the first run, a failing notify call, the spool folder of the media helpers. `hs notify` is a stub that logs its arguments. python3 stdlib only, no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
command -v python3 >/dev/null || { echo "python3 missing: skipped"; exit 0; }
wp() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
export HS_PLAIN=1 HS_LANG=en HS_CALLER=test
mkdir -p "$WORK/st" "$WORK/rules.d" "$WORK/spool"
export HS_STATE_DIR=$(wp "$WORK/st") HS_STATE_DB=$(wp "$WORK/st/state.db") HS_NOTIFY_RULES_DIR=$(wp "$WORK/rules.d")
NLOG=$WORK/notify.log
cat > "$WORK/notify-stub" <<'EOF'
#!/usr/bin/env bash
# logs: category|priority|title|message|payload-file-content ; exit 1 when the title says FAIL
pf=""; cat=""; pos=()
while [ $# -gt 0 ]; do case "$1" in --category) cat=$2; shift 2 ;; --payload-file) pf=$2; shift 2 ;; *) pos+=("$1"); shift ;; esac; done
printf '%s|%s|%s|%s|%s\n' "$cat" "${pos[2]:--}" "${pos[0]}" "${pos[1]//$'
'/'~'}" "$([ -n "$pf" ] && cat "$pf" || echo -)" >> "$NOTIFY_LOG"
case "${pos[0]}" in *FAIL*) exit 1 ;; esac
EOF
chmod +x "$WORK/notify-stub"
export NOTIFY_LOG=$(wp "$NLOG") HS_NOTIFY_CMD="\"$(wp "$(command -v bash)")\" $(wp "$WORK/notify-stub")"
EN=$SCRIPTS/event-notify.py
SD=$SCRIPTS/state-db.py
emit() { python3 "$SD" emit "$@"; }
run() { python3 "$EN" run "$@"; }
lines() { if [ -f "$NLOG" ]; then wc -l < "$NLOG" | tr -d ' '; else echo 0; fi; }
cursor() { tr -d '\r\n' < "$WORK/st/event-notify.cursor"; }

echo "-- the rules file is valid"
R=$SCRIPTS/lib/notify-rules.tsv
check_eq "5 columns per rule" "" "$(grep -v '^#' "$R" | awk -F'\t' 'NF != 5 {print $1}')"
check_eq "categories and priorities are known" "" "$(grep -v '^#' "$R" | awk -F'\t' '$2 !~ /^(alarm|lock|problem|ok|start|stop|info|-)$/ || $3 !~ /^(min|low|default|high|urgent|-)$/ {print $1}')"
check_eq "every media kind has a rule" "" "$(for k in $(grep -o '^ext\.media\.[a-z.-]*' "$SCRIPTS/lib/event-kinds.tsv"); do python3 "$EN" match "$k" >/dev/null || echo "$k"; done)"
python3 "$EN" match job.failed >/dev/null; rc1=$?
python3 "$EN" match storage.pool-fault >/dev/null; rc2=$?
check_eq "job.failed and storage.pool-fault are told elsewhere: no rule" "1/1" "$rc1/$rc2"

echo "-- the first run starts at the newest row"
emit job.ok old1 "history"
emit job.ok old2 "history"
run
check_eq "history is not replayed" "0" "$(lines)"
check_eq "the cursor is the newest id" "2" "$(cursor)"

echo "-- a matching row sends one message with the payload"
emit ext.media.sabnzbd.failed sabnzbd "Download failed: X" --payload '{"name":"Downloadarr","label":"Download failed","body":"**X**","title":"X"}'
run
check_eq "one call" "1" "$(lines)"
check_eq "category, priority, title, message, payload" 'problem|high|Downloadarr: Download failed|**X**|{"name": "Downloadarr", "label": "Download failed", "body": "**X**", "title": "X"}' "$(tail -n1 "$NLOG")"
check_eq "the cursor moved" "3" "$(cursor)"
run
check_eq "a second run sends nothing again" "1" "$(lines)"

echo "-- rows without a rule and the notify.* kinds send nothing (no loop)"
emit job.ok u1 "x"
emit notify.sent main "title"
emit notify.failed main "title: boom"
emit ext.media.sabnzbd.failed sabnzbd "t" --payload '{"name":"N","label":"L","body":"B"}'
run
check_eq "only the media row" "2" "$(lines)"
check_eq "the cursor is past all of them" "7" "$(cursor)"

echo "-- a rule file in the drop-in folder comes first and can mute"
printf 'ext.media.sabnzbd.failed\t-\t-\tx\ty\njob.ok\tinfo\t-\t{subject} done\tlevel {level}\\nsecond line\n' > "$WORK/rules.d/10-own.tsv"
emit ext.media.sabnzbd.failed sabnzbd "t" --payload '{"name":"N","label":"L","body":"B"}'
emit job.ok unit-9 "ok"
run
check_eq "muted kind silent, job.ok has a new rule " "3" "$(lines)"
check_eq "templates: subject, level and a new line" "info|-|unit-9 done|level info~second line|-" "$(tail -n1 "$NLOG")"
rm -f "$WORK/rules.d/10-own.tsv"

echo "-- a failing notify call does not stop the other rows"
printf 'job.ok\tinfo\t-\tFAIL {subject}\tm\njob.ok\tinfo\t-\tnever\tm\n' > "$WORK/rules.d/20-fail.tsv"
emit job.ok a1
emit job.ok a2
before=$(lines)
run 2>"$WORK/err"
check_eq "both rows were tried" "$((before + 2))" "$(lines)"
check_eq "the failure is said" "2" "$(grep -c 'exited 1' "$WORK/err" | tr -d ' ')"
check_eq "the cursor still moved" "$(python3 "$SD" event-list 1 | cut -f1)" "$(cursor)"
rm -f "$WORK/rules.d/20-fail.tsv"

echo "-- a broken rule line is skipped, the rest works"
printf 'job.ok\tbogus\t-\tt\tm\nnot a rule\n' > "$WORK/rules.d/30-bad.tsv"
emit ext.media.sabnzbd.added sabnzbd "t" --payload '{"name":"N","label":"L","body":"B"}'
before=$(lines)
run 2>"$WORK/err"
check_eq "the good rule still fires" "$((before + 1))" "$(lines)"
check_eq "two warnings" "2" "$(grep -c 'not a rule' "$WORK/err" | tr -d ' ')"
rm -f "$WORK/rules.d/30-bad.tsv"

echo "-- an unreadable log does not move the cursor"
c0=$(cursor)
HS_STATE_DB=$(wp "$WORK/no/such/dir/x.db") HS_PYTHON=false run 2>/dev/null
check_eq "cursor unchanged" "$c0" "$(cursor)"

echo "-- the spool folder: only ext.media kinds, only small ordinary files"
SP=$WORK/spool
good='{"kind":"ext.media.sabnzbd.finished","subject":"sabnzbd","text":"Download finished: Z","payload":{"name":"Downloadarr","label":"Download finished","body":"**Z**","poster_url":"http://10.0.0.5/p.jpg","evil":{"a":1}}}'
printf '%s' "$good" > "$SP/ev-1-1.json"
printf '%s' '{"kind":"storage.new","subject":"S1","text":"forged"}' > "$SP/ev-2-1.json"
printf '%s' '{"kind":"notify.sent","subject":"x"}' > "$SP/ev-3-1.json"
printf '%s' '{"kind":"ext.media.sabnzbd.finished","subject":"a b","payload":{}}' > "$SP/ev-4-1.json"
printf 'not json' > "$SP/ev-5-1.json"
printf '%s' '{"kind":"ext.media.sabnzbd.finished","subject":"x"' > "$SP/.tmp-1-1"
printf '%s' "$good" > "$SP/other.txt"
before=$(lines)
HS_EVENT_SPOOL=$(wp "$SP") bash "$SCRIPTS/event-notify.sh" 2>"$WORK/err"
check_eq "one message from the good event" "$((before + 1))" "$(lines)"
check_eq "the message is the finished rule" "ok|default|Downloadarr: Download finished|**Z**" "$(tail -n1 "$NLOG" | cut -d'|' -f1-4)"
check_eq "the forged kinds never reached the log" "0" "$(python3 "$SD" event-list 20 --source storage | grep -c forged)"
check_eq "the nested payload key was dropped" "0" "$(tail -n1 "$NLOG" | grep -c evil)"
check_eq "taken files are gone, other files and the half-written one stay" ".tmp-1-1
other.txt" "$(ls -A "$SP" | sort)"
if ln -s "$WORK/notify-stub" "$SP/ev-6-1.json" 2>/dev/null && [ -L "$SP/ev-6-1.json" ]; then
  before=$(lines); HS_EVENT_SPOOL=$(wp "$SP") bash "$SCRIPTS/event-notify.sh" 2>/dev/null
  check_eq "a link is not followed and not read" "$before" "$(lines)"
  check "the link stays" test -L "$SP/ev-6-1.json"
else skip "links cannot be made here"; fi

echo "-- the media helper writes an event the subscriber takes in"
rm -f "$SP"/ev-*.json
printf '{"spool": "%s"}' "$(wp "$SP")" > "$WORK/media.json"
HS_MEDIA_NOTIFY_CONF=$(wp "$WORK/media.json") python3 "$SCRIPTS/recipes/files/hs-media-notify.py" send --service maintainerr --event planned --title "Film (2020)" --field "Keep=4K" --footer f
check_eq "one spool file, no .tmp left" "1" "$(ls "$SP" | grep -c '^ev-.*\.json$')"
before=$(lines)
HS_EVENT_SPOOL=$(wp "$SP") bash "$SCRIPTS/event-notify.sh" 2>/dev/null
check_eq "it became a message" "$((before + 1))" "$(lines)"
check_eq "title and category" "info|default|Maintainerr (Script): Duplicate found" "$(tail -n1 "$NLOG" | cut -d'|' -f1-3)"
finish
