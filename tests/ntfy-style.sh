#!/usr/bin/env bash
# scripts/lib/ntfy.sh: categories (icon, priority), markdown body, footer, and the copy in the proxyserver repo.
# Fake curl records the call; no network.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'FAKE'
#!/usr/bin/env bash
a="$*"; echo "${a//$'\n'/ ¶ }" > "$CALLS"
[ -z "${CURL_FAIL:-}" ]
FAKE
chmod +x "$WORK/bin/curl"
export PATH=$WORK/bin:$PATH CALLS=$WORK/calls NTFY_HOST=Home-Server
# shellcheck source=scripts/lib/ntfy.sh
. "$SCRIPTS/lib/ntfy.sh"
sent() { ntfy_send https://ntfy.test/t "$@"; cat "$CALLS"; }

echo "-- categories"
for row in alarm:rotating_light:urgent lock:closed_lock_with_key:urgent problem:warning:high ok:white_check_mark:default \
           start:arrow_up:low stop:arrow_down:low info:information_source:default heartbeat:heartbeat:min nonsense:information_source:default; do
  IFS=: read -r c icon prio <<<"$row"
  out=$(sent "T" "m" "$c")
  check_out "$c: icon $icon" "Tags: $icon,home-server " echo "$out"
  check_out "$c: priority $prio by default" "Priority: $prio " echo "$out"
done
check_out "an explicit priority wins" "Priority: low " sent T m alarm low
check_out "markdown is switched on" "Markdown: yes" sent T m ok
check_eq "no priority names info" "info" "$(ntfy_category_for default)"
check_eq "urgent is an alarm" "alarm" "$(ntfy_category_for urgent)"
check_eq "high is a problem" "problem" "$(ntfy_category_for high)"
check_eq "low is a start/stop-like message" "start" "$(ntfy_category_for low)"

echo "-- markdown"
check_eq "one line stays one line" "Disk sdb is BAD" "$(ntfy_md 'Disk sdb is BAD')"
check_eq "several lines become bullets" $'- one\n- two' "$(ntfy_md $'one\ntwo')"
check_eq "a bold lead stays, the rest are bullets" $'**Open**\n- one\n- two' "$(ntfy_md $'**Open**\none\ntwo')"
check_eq "the commands at the end are code" 'pool is bad. Details: `zpool status fast`' "$(ntfy_md 'pool is bad. Details: zpool status fast')"
check_eq "a closing full stop stays outside the code" 'Try: `hs backup now`.' "$(ntfy_md 'Try: hs backup now.')"
check_eq "a line with backticks is left alone" 'Run `hs unlock` now' "$(ntfy_md 'Run `hs unlock` now')"
check_eq "< and > are escaped (they would be taken for HTML)" 'leave shares out (hs backup \<share\> off)' "$(ntfy_md 'leave shares out (hs backup <share> off)')"
once=$(ntfy_md $'**Open**\nx. Details: journalctl -u a\ny')
check_eq "idempotent" "$once" "$(ntfy_md "$once")"
check_eq "a blank line stays (paragraphs)" $'**a**\n\nRun `x`' "$(ntfy_md $'**a**\n\nRun `x`')"

echo "-- body and footer"
body=$(ntfy_body "hello" ok)
check_out "the footer has host and time" '^_Home-Server · [0-9-]+ [0-9:]+_$' echo "$body"
check_eq "the heartbeat has no footer" "alive" "$(ntfy_body alive heartbeat)"

echo "-- the call"
out=$(sent "host: x" $'**Open**\na\nb' problem)
check_out "title" "Title: host: x " echo "$out"
check_out "body with lead and bullets" "data-raw \*\*Open\*\* ¶ - a ¶ - b " echo "$out"
check_out "body starting with @ is data, not a file" "data-raw @file" sent T '@file' info
check_eq "a failed send returns failure" "1" "$(CURL_FAIL=1 ntfy_send u t m >/dev/null 2>&1; echo $?)"

echo "-- hs notify uses it"
check_out "the category flag" "Tags: rotating_light," env HS_NOTIFY_URL=https://ntfy.test/t HS_STATE_DIR="$WORK" bash -c "bash '$SCRIPTS/notify.sh' --category alarm T M; cat '$CALLS'"
check_out "no category: from the priority" "Tags: warning," env HS_NOTIFY_URL=https://ntfy.test/t HS_STATE_DIR="$WORK" bash -c "bash '$SCRIPTS/notify.sh' T M high; cat '$CALLS'"
check_out "dry run names the icon" "category: ok \(white_check_mark\)" env HS_NOTIFY_URL=https://ntfy.test/t bash "$SCRIPTS/notify.sh" --dry-run --category ok T M

echo "-- the providers are the only curl that sends a push message"
check "the ntfy provider sends through ntfy_send" grep -q 'ntfy_send "\$url"' "$SCRIPTS/notify/ntfy.sh"
check_eq "no curl in notify.sh, the routing or the channel library" "" "$(grep -lE '^[^#]*curl' "$SCRIPTS/notify.sh" "$SCRIPTS/lib/notify-route.sh" "$SCRIPTS/lib/channels.sh" "$SCRIPTS/notify-channel.sh" || true)"

echo "-- the copy in the proxyserver repo"
copy=$ROOT/../proxyserver/modules/notify/ntfy.sh
if [ -r "$copy" ]; then check "identical to scripts/lib/ntfy.sh" cmp "$SCRIPTS/lib/ntfy.sh" "$copy"; else echo "  (no ../proxyserver next to this repo: copy not compared)"; fi

echo "  -> $T_PASS ok, $T_FAIL failed, $T_SKIP skipped"
[ "$T_FAIL" -eq 0 ]
