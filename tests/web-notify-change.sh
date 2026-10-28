#!/usr/bin/env bash
# hs sys notify plan|start (scripts/notify-change.sh): the Notifications page of the web interface, against the real notify-channel.sh with
# fake providers' curl; and the CHANGES / READS allowlists of scripts/web-serve.py (tests/web-notify-test.py). No root, no network.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en
unset HS_CALLER HS_GUIDED_TTY HS_NOTIFY_URL HS_NOTIFY_URL_SECOND HS_NOTIFY_SECOND_MIN HS_QUIET_HOURS HS_HEARTBEAT_URL
T=$'\t'
mkdir -p "$WORK/bin" "$WORK/state" "$WORK/prov"
printf '#!/usr/bin/env bash\necho "$*" >> "$CALLS"\nexit 0\n' > "$WORK/bin/curl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/logger"
chmod +x "$WORK/bin/curl" "$WORK/bin/logger"
printf '#!/usr/bin/env bash\nexec bash "%s/notify/ntfy.sh" "$@"\n' "$SCRIPTS" > "$WORK/prov/ntfy.sh"
printf '#!/usr/bin/env bash\nexec bash "%s/notify/email.sh" "$@"\n' "$SCRIPTS" > "$WORK/prov/email.sh"
export PATH=$WORK/bin:$PATH CALLS=$WORK/calls NTFY_HOST=Home
export HS_STATE_DIR=$WORK/state HS_SETTINGS_DIR=$WORK/state/settings HS_ETC_DIR=$WORK/etc HS_NOTIFY_PROVIDERS=$WORK/prov
: > "$CALLS"
run() { local in=$1 verb=$2; shift 2; rc=0; out=$(printf '%s' "$in" | timeout 30 bash "$SCRIPTS/notify-change.sh" "$verb" "$@" 2>/dev/null) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }
chans() { bash "$SCRIPTS/notify-channel.sh" --list </dev/null | cut -f1 | paste -sd, -; }

echo "-- registry rows"
for r in "sys${T}sys notify plan <action>" "sys${T}sys notify start <action>"; do check "row: ${r//$T/ | }" grep -q "^$r${T}" "$SCRIPTS/lib/registry.tsv"; done

echo "-- plan add"
run "" plan add phone --provider ntfy --secret url
check_eq "a secret that was not given: needs" 2 "$rc"
has '^status	needs$' && has '^needs	Address of the topic' && pass "names the missing field" || fail "needs: $out"
run "https://ntfy.sh/a-long-random-topic
" plan add phone --provider ntfy --secret url --min-priority high --categories alarm,status
check_eq "with the secret: allowed" 0 "$rc"
has '^status	ok$' && has '^heading	add the channel phone (ntfy)$' && has '^command	hs notify channel add phone --provider ntfy --min-priority high --categories alarm,status --secret url$' && pass "the plan and the command" || fail "plan: $out"
if grep -q "ntfy.sh" <<<"$out"; then fail "the plan never shows the secret"; else pass "the plan never shows the secret"; fi
has '^danger' && fail "adding is not red" || pass "adding is not red"
check_eq "a plan writes nothing" "" "$(chans)"
run "x
" plan add phone --provider ntfy --secret url
check_eq "a secret the provider refuses" 1 "$rc"
run "https://ntfy.sh/x
" plan add Bad_Name --provider ntfy --secret url; check_eq "bad name refused" 1 "$rc"
run "" plan add phone --provider nope; check_eq "unknown provider refused" 1 "$rc"
run "https://ntfy.sh/x
" plan add phone --provider ntfy --secret url --categories nonsense; check_eq "bad class refused" 1 "$rc"
run "x
" plan add phone --provider ntfy --set url=https://ntfy.sh/x; check_eq "a secret setting cannot come as --set" 1 "$rc"
run "pw
" plan add mail --provider email --secret password --set host=smtp.example.org --set from=a@example.org --set to=me@example.org --categories heartbeat
check_eq "email cannot carry the heartbeat" 1 "$rc"
has 'cannot carry heartbeat' && pass "says why" || fail "caps: $out"
run "pw
" plan add mail --provider email --secret password --set host=smtp.example.org --set from=a@example.org
check_eq "email without a recipient: needs" 2 "$rc"
has '^needs	Recipient address$' && pass "names it" || fail "needs to: $out"

echo "-- start add, set, test, remove"
run "https://ntfy.sh/a-long-random-topic
" start add phone --provider ntfy --secret url --min-priority high
check_eq "start add: done" 0 "$rc"; has '^status	done$' && pass "status done" || fail "start add: $out"
check_eq "the channel exists" "phone" "$(chans)"
run "" start add phone --provider ntfy --secret url; check_eq "adding it again is refused" 1 "$rc"
run "" plan set phone --categories alarm
check_eq "plan set" 0 "$rc"; has '^heading	change the channel phone$' && has '^step	it carries: alarm$' && pass "set plan" || fail "set plan: $out"
run "" start set phone --categories alarm --enabled yes; check_eq "start set" 0 "$rc"
check_eq "the classes were saved" "alarm" "$(bash "$SCRIPTS/notify-channel.sh" --show phone </dev/null | awk -F'\t' '$1 == "categories" { print $2 }')"
run "" plan set nobody --enabled no; check_eq "set of an unknown channel refused" 1 "$rc"
run "" plan set phone --provider email; check_eq "the provider cannot change" 1 "$rc"
: > "$CALLS"
run "" start test phone; check_eq "start test" 0 "$rc"; has '^status	done$' && pass "test done" || fail "test: $out"
grep -q "ntfy.sh/a-long-random-topic" "$CALLS" && pass "the test message went to curl" || fail "test calls: $(cat "$CALLS")"
run "" plan remove phone
check_eq "plan remove" 0 "$rc"
has '^danger' && has '^confirm_name	phone$' && pass "remove is red and names the channel to type" || fail "remove plan: $out"
run "" start remove phone; check_eq "remove without the name typed is refused" 1 "$rc"
check_eq "and nothing was removed" "phone" "$(chans)"
run "" start remove phone --confirm phone; check_eq "remove with the name" 0 "$rc"
check_eq "gone" "" "$(chans)"
run "" plan remove phone; check_eq "removing it twice is refused" 1 "$rc"

echo "-- migrate"
rm -rf "$WORK/state/notify-channels"
printf 'https://ntfy.sh/old\n' > "$WORK/state/notify-url"
run "" plan migrate; check_eq "plan migrate" 0 "$rc"
run "" start migrate; check_eq "start migrate" 0 "$rc"
check "main is a file now" test -f "$WORK/state/notify-channels/main.conf"
run "" plan migrate extra; check_eq "extra words are refused" 1 "$rc"

echo "-- the allowlists"
if have python3; then
  if o=$(python3 -I "$ROOT/tests/web-notify-test.py" 2>&1); then pass "web-serve CHANGES / READS for notify ($(grep -E '^Ran ' <<<"$o"))"; else fail "web allowlist: $(tail -n 25 <<<"$o")"; fi
else
  skip "python3 missing"
fi

echo "-- the page is wired in"
for f in web/src/pages/Notifications.svelte web/src/forms/ops/ChannelForm.svelte; do check "$f exists" test -f "$ROOT/$f"; done
check "route" grep -q "'/operations/notifications': Notifications" "$ROOT/web/src/routes.js"
check "tree node with the capability" grep -q "path: '/operations/notifications', capability: 'notifications'" "$ROOT/web/src/nav.js"
check "prefetch" grep -q "operations/notifications" "$ROOT/web/src/readsfor.js"

finish
