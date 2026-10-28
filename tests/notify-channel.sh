#!/usr/bin/env bash
# Notification channels: scripts/notify-channel.sh, scripts/lib/channels.sh, the provider scripts/notify/ntfy.sh and the
# fan-out in scripts/notify.sh. Fake curl and logger, fake providers; no network, no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en
unset HS_CALLER HS_GUIDED_TTY HS_NOTIFY_URL HS_NOTIFY_URL_SECOND HS_NOTIFY_SECOND_MIN HS_QUIET_HOURS
T=$'\t'
mkdir -p "$WORK/bin" "$WORK/state" "$WORK/prov"
cat > "$WORK/bin/curl" <<'FAKE'
#!/usr/bin/env bash
a="$*"; echo "${a//$'\n'/ ¶ }" >> "$CALLS"
# the mail provider hands curl a message file (-T) and a config file with the login (-K): keep copies to look at
prev=""; for x in "$@"; do case "$prev" in -T) cp "$x" "$MAIL_OUT" 2>/dev/null ;; -K) cp "$x" "$CFG_OUT" 2>/dev/null ;; esac; prev=$x; done
case "$a" in *"$CURL_FAIL_ON"*) [ -n "${CURL_FAIL_ON:-}" ] && { echo "curl: (22) The requested URL returned error: 429" >&2; exit 22; } ;; esac
exit 0
FAKE
printf '#!/usr/bin/env bash\necho "$*" >> "$LOGGED"\nexit 0\n' > "$WORK/bin/logger"
chmod +x "$WORK/bin/curl" "$WORK/bin/logger"
# fake providers next to a wrapper for the real ntfy one
printf '#!/usr/bin/env bash\nexec bash "%s/notify/ntfy.sh" "$@"\n' "$SCRIPTS" > "$WORK/prov/ntfy.sh"
printf '#!/usr/bin/env bash\nexec bash "%s/notify/email.sh" "$@"\n' "$SCRIPTS" > "$WORK/prov/email.sh"
cat > "$WORK/prov/boom.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  fields) printf 'token\tToken\tsecret\trequired\t-\n' ;;
  check) [ -n "${CH_token:-}" ] || { echo "no token" >&2; exit 2; } ;;
  where) echo outside ;;
  send) echo "service said no" >&2; exit 1 ;;
esac
EOF
cat > "$WORK/prov/rec.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  fields) printf 'room\tRoom\ttext\trequired\t-\n' ;;
  check) [ -n "${CH_room:-}" ] || { echo "no room" >&2; exit 2; } ;;
  where) echo inside ;;
  send) echo "rec $2|$3|$4|room=$CH_room|cat=$CH_CATEGORY" >> "$REC"; exit 0 ;;
esac
EOF
export MAIL_OUT=$WORK/mail.out CFG_OUT=$WORK/cfg.out
export PATH=$WORK/bin:$PATH CALLS=$WORK/calls LOGGED=$WORK/logged REC=$WORK/rec NTFY_HOST=Home
export HS_STATE_DIR=$WORK/state HS_SETTINGS_DIR=$WORK/state/settings HS_ETC_DIR=$WORK/etc HS_HELD_DIR=$WORK/held
export HS_NOTIFY_PROVIDERS=$WORK/prov
: > "$CALLS"; : > "$LOGGED"; : > "$REC"
C() { rc=0; out=$(timeout 30 bash "$SCRIPTS/notify-channel.sh" "$@" </dev/null 2>"$WORK/err") || rc=$?; }
CIN() { local in=$1; shift; rc=0; out=$(printf '%s\n' "$in" | timeout 30 bash "$SCRIPTS/notify-channel.sh" "$@" 2>"$WORK/err") || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }
N="bash $SCRIPTS/notify.sh"
calls() { cat "$CALLS"; }
n_calls() { wc -l < "$CALLS" | tr -d ' '; }

echo "-- registry rows and the capability"
reg=$SCRIPTS/lib/registry.tsv
for r in "user${T}notify channel list" "user${T}notify channel show" "user${T}notify channel add" "user${T}notify channel set" "user${T}notify channel remove" \
         "user${T}notify channel test" "user${T}notify channel migrate" "user${T}notify channel providers" \
         "sys${T}sys notify channels" "sys${T}sys notify channel <name>" "sys${T}sys notify providers"; do
  check "row: ${r//$T/ | }" grep -q "^$r${T}" "$reg"
done
check "the rows carry the capability flag" test "$(grep -c "^[a-z]*${T}\(sys \)\?notify channel.*capability:notifications" "$reg")" -ge 8
check "implied by the old push addresses" grep -q "^notifications${T}notifyUrl,notifyUrlSecond,notifications${T}" "$SCRIPTS/lib/capabilities.tsv"
for f in notifications; do check "manifest and notes of $f exist" test -f "$ROOT/capabilities/$f/capability.toml" -a -f "$ROOT/capabilities/$f/NOTES.md"; done

echo "-- nothing set: no channels, a message is only journaled"
C --list; check_eq "no channels" "" "$out"
rc=0; $N --category problem T M high || rc=$?; check_eq "no call" 0 "$(n_calls)"; check_eq "and the exit is 0" 0 "$rc"

echo "-- an existing setup (notifyUrl, notifyUrlSecond) is derived, nothing is written"
mkdir -p "$WORK/state"
printf 'https://ntfy.test/one\n' > "$WORK/state/notify-url"
mkdir -p "$HS_SETTINGS_DIR"; printf 'https://ntfy.test/two\n' > "$HS_SETTINGS_DIR/notifyUrlSecond"
C --list
check_eq "main and second" "main second" "$(cut -f1 <<<"$out" | tr '\n' ' ' | sed 's/ $//')"
check_eq "main: all priorities, from the setting" "main${T}ntfy${T}yes${T}min${T}respect${T}outside${T}derived${T}ok${T}alarm,status,digest${T}alarm,status,heartbeat,digest${T}-${T}-${T}-" "$(sed -n 1p <<<"$out")"
check_eq "second: high and up" "second${T}ntfy${T}yes${T}high${T}respect${T}outside${T}derived${T}ok${T}alarm,status,digest${T}alarm,status,heartbeat,digest${T}-${T}-${T}-" "$(sed -n 2p <<<"$out")"
check "no file was written" test ! -d "$WORK/state/notify-channels"
$N --category ok T M default
check_eq "a default message goes to main only" 1 "$(n_calls)"; check_out "to the first address" "ntfy.test/one" calls
: > "$CALLS"; $N --category problem T M high
check_eq "a problem goes to both" 2 "$(n_calls)"
check_out "the topic is the setting's, the call is the old ntfy call" "Tags: warning,home" calls
echo "-- the address written by the ntfy recipe still wins (the channel only refers to the setting)"
printf 'https://ntfy.test/three\n' > "$WORK/state/notify-url"
: > "$CALLS"; $N --category ok T M default; check_out "new address" "ntfy.test/three" calls

echo "-- list and show never print a secret"
C --list; if grep -q "ntfy.test" <<<"$out"; then fail "list shows no address"; else pass "list shows no address"; fi
C --show main
check_eq "show: url is set, not shown" "url${T}set" "$(grep "^url${T}" <<<"$out")"
if grep -q "ntfy.test" <<<"$out"; then fail "show shows no address"; else pass "show shows no address"; fi
C --show nonsense; check_eq "unknown channel exits 1" 1 "$rc"
C list; check_out "the table for people" "main +ntfy" echo "$out"

echo "-- add: the secret comes from stdin, never argv"
CIN "https://ntfy.test/mail" add alerts --provider ntfy --min-priority urgent --quiet ignore --secret url
check_eq "added" 0 "$rc"
check "the files exist (the derived ones were written first)" test -f "$WORK/state/notify-channels/main.conf" -a -f "$WORK/state/notify-channels/second.conf" -a -f "$WORK/state/notify-channels/alerts.conf" -a -e "$WORK/state/notify-channels/.migrated"
check "main still refers to the setting" grep -q '^url=@setting:notifyUrl$' "$WORK/state/notify-channels/main.conf"
C add x --provider ntfy --secret url; check_eq "no value on stdin fails" 1 "$rc"
C add alerts --provider ntfy --secret url; check_eq "an existing name is refused" 1 "$rc"
C add main --provider ntfy --secret url; check_eq "also the derived name" 1 "$rc"
C add Bad_Name --provider ntfy; check_eq "a bad name is refused" 1 "$rc"
C add y --provider nope; check_eq "an unknown provider is refused" 1 "$rc"
C add y --provider ntfy --set url=https://ntfy.test/x; check_eq "a secret cannot be given on the command line" 1 "$rc"
check "and says why" has stdin
CIN "not-a-url" add y --provider ntfy --secret url; check_eq "the provider's check refuses a bad value" 1 "$rc"
check "nothing was written for it" test ! -f "$WORK/state/notify-channels/y.conf"
C add y --provider ntfy --min-priority loud; check_eq "a bad priority is refused" 1 "$rc"
C --list
check_eq "three channels, main first" "main alerts second" "$(cut -f1 <<<"$out" | tr '\n' ' ' | sed 's/ $//')"
check_eq "file source, quiet ignore" "alerts${T}ntfy${T}yes${T}urgent${T}ignore${T}outside${T}file${T}ok${T}alarm,status,digest${T}alarm,status,heartbeat,digest" "$(grep "^alerts" <<<"$out" | cut -f1-10)"

echo "-- fan-out: every channel that wants the priority, quiet=ignore at once in the quiet hours"
: > "$CALLS"; $N --category alarm T M urgent
check_eq "an alarm goes to all three" 3 "$(n_calls)"
: > "$CALLS"; $N --category problem T M high
check_eq "a problem to main and second only (alerts wants urgent)" 2 "$(n_calls)"
export HS_QUIET_HOURS=22:00-07:00 HS_NOW_HM=03:00
: > "$CALLS"; $N --category ok "Home: ok" "fine" default
check_eq "in the quiet hours a default message is held for the others" 0 "$(n_calls)"
C set alerts --min-priority min
: > "$CALLS"; $N --category ok "Home: ok2" "fine" default
check_eq "the channel that ignores the quiet hours gets it at once" 1 "$(n_calls)"; check_out "it is the alerts topic" "ntfy.test/mail" calls
: > "$CALLS"; HS_NOW_HM=08:00 $N --flush
check_eq "the digest goes to the channels that respect the quiet hours (main only: second wants high)" 1 "$(n_calls)"
check_out "and not to alerts" "ntfy.test/three" calls
unset HS_QUIET_HOURS HS_NOW_HM
check "the held ones are gone" test "$(ls "$WORK/held"/*.msg 2>/dev/null | wc -l | tr -d ' ')" = 0
C set alerts --min-priority urgent

echo "-- one failing channel never blocks the others"
CIN "tok" add boomer --provider boom --secret token
check_eq "a second provider is added" 0 "$rc"
: > "$CALLS"; rc=0; $N --category problem T M high || rc=$?
check_eq "notify exits 0" 0 "$rc"
check_eq "ntfy channels still got it (boom has no curl)" 2 "$(n_calls)"
check "the failure is in the journal with the reason" grep -q "channel boomer: service said no" "$LOGGED"
rc=0; CURL_FAIL_ON=ntfy.test HS_NOTIFY_STRICT=1 $N --category problem T M high || rc=$?
check_eq "strict callers learn that nothing arrived" 1 "$rc"
rc=0; CURL_FAIL_ON=ntfy.test $N --category problem T M high || rc=$?
check_eq "others get 0" 0 "$rc"
C test boomer; check_eq "test of a failing channel exits 1" 1 "$rc"
check "with the reason" grep -q "service said no" <<<"$out$(cat "$WORK/err")"
: > "$CALLS"; C test main; check_eq "test of a good channel" 0 "$rc"
check_out "it is a real send" "Title: .*test message" calls
check_out "and an info" "Tags: information_source," calls
C remove boomer --yes

echo "-- a provider gets its settings in the environment"
CIN "" add roomy --provider rec --set room='!abc:example.org' --min-priority min
check_eq "a text setting with --set" 0 "$rc"
: > "$REC"; $N --category problem T M high
check_eq "rec got the message" "rec high|T|" "$(cut -c1-11 "$REC" | head -n1)"
check_out "with the setting in CH_room" "room=!abc:example.org\|cat=problem" cat "$REC"
C --list; check_out "inside, as the provider says" "roomy${T}rec${T}yes${T}min${T}respect${T}inside" echo "$out"
C --show roomy; check_out "text settings are shown" "^room${T}!abc:example.org" echo "$out"
C --providers; check_out "providers: ntfy url is a secret" "^ntfy${T}url${T}.*${T}secret${T}required" echo "$out"
C set roomy --enabled no
: > "$REC"; $N --category problem T M high; check_eq "a disabled channel gets nothing" "" "$(cat "$REC")"
C test roomy; check_eq "but can still be tested" 0 "$rc"
C remove roomy; check_eq "removing needs --yes without a terminal" 1 "$rc"
C remove roomy --yes; check_eq "removed" 0 "$rc"
C set roomy --enabled yes; check_eq "gone" 1 "$rc"

echo "-- remove main for good: the old setting does not bring it back"
C remove main --yes
C --list; check_eq "main is gone" "alerts second" "$(cut -f1 <<<"$out" | tr '\n' ' ' | sed 's/ $//')"
: > "$CALLS"; $N --category problem T M high; check_eq "problem goes to second only" 1 "$(n_calls)"
C remove second --yes; C remove alerts --yes
C --list; check_eq "no channels left, still not derived again" "" "$out"
rc=0; $N --category problem T M high || rc=$?; check_eq "no channel at all is fine" 0 "$rc"

echo "-- dry run names the channels, never an address"
rm -rf "$WORK/state/notify-channels"
export HS_NOTIFY_URL=https://ntfy.test/dry HS_NOTIFY_URL_SECOND=https://ntfy.test/dry2
out=$($N --dry-run --category problem T M high 2>&1)
check "first channel named" grep -q "Would send to main" <<<"$out"
check "second channel named" grep -q "also to:  second" <<<"$out"
if grep -q "ntfy.test" <<<"$out"; then fail "the dry run shows no address"; else pass "the dry run shows no address"; fi
unset HS_NOTIFY_URL HS_NOTIFY_URL_SECOND

echo "-- migrate by itself"
printf 'https://ntfy.test/m\n' > "$WORK/state/notify-url"; rm -f "$HS_SETTINGS_DIR/notifyUrlSecond"
C migrate; check_eq "migrate" 0 "$rc"
check "main is a file" test -f "$WORK/state/notify-channels/main.conf"
C migrate; check_out "and a second time says so" "Already migrated" echo "$out"

echo "-- message classes: a channel carries only what it ticks"
rm -rf "$WORK/state/notify-channels" "$HS_SETTINGS_DIR"; mkdir -p "$HS_SETTINGS_DIR"; rm -f "$WORK/state/notify-url"
CIN "https://ntfy.test/all" add everything --provider ntfy --secret url --categories alarm,status,heartbeat,digest
check_eq "added with every class" 0 "$rc"
CIN "https://ntfy.test/alarms" add alarms --provider ntfy --secret url --categories alarm
CIN "https://ntfy.test/plain" add plain --provider ntfy --secret url
C --show plain; check_out "the default classes leave the heartbeat out" "^categories${T}alarm,status,digest" echo "$out"
C --show alarms; check_out "the classes are stored in a fixed order" "^categories${T}alarm$" echo "$out"
: > "$CALLS"; $N --category ok T M default
check_eq "a status message: everything and plain, not alarms" 2 "$(n_calls)"
: > "$CALLS"; $N --category problem T M high
check_eq "a problem: all three" 3 "$(n_calls)"
: > "$CALLS"; $N --category heartbeat "host alive" "alive, 0 problem(s)"
check_eq "the heartbeat goes to the one channel that carries it" 1 "$(n_calls)"; check_out "it is the all-classes topic" "ntfy.test/all" calls
check "the heartbeat is not in the journal" test "$(grep -c "alive" "$LOGGED")" = 0
echo "-- the heartbeat bypasses the quiet hours, the minimum priority and the digest"
C set everything --min-priority urgent
export HS_QUIET_HOURS=22:00-07:00 HS_NOW_HM=03:00
: > "$CALLS"; $N --category heartbeat "host alive" "alive, 0 problem(s)"
check_eq "at 03:00 with minimum urgent it still arrives at once" 1 "$(n_calls)"
check "and nothing was held" test "$(ls "$WORK/held"/*.msg 2>/dev/null | wc -l | tr -d ' ')" = 0
: > "$CALLS"; $N --category ok "Home: ok3" "fine" default
check_eq "an ordinary status message is held for everybody" 0 "$(n_calls)"
check "and held once" test "$(ls "$WORK/held"/*.msg 2>/dev/null | wc -l | tr -d ' ')" = 1
C set plain --categories alarm,status
: > "$CALLS"; HS_NOW_HM=08:00 $N --flush
check_eq "the digest goes only to channels that carry it (everything wants urgent: no)" 0 "$(n_calls)"
C set everything --min-priority min; C set plain --categories alarm,status,digest
unset HS_QUIET_HOURS HS_NOW_HM
echo "-- urgent passes every minimum, a disabled channel stays silent"
C set alarms --min-priority urgent
: > "$CALLS"; $N --category alarm T M urgent
check "urgent reaches the channel whose minimum is urgent" grep -q "ntfy.test/alarms" "$CALLS"
C set alarms --enabled no
: > "$CALLS"; $N --category alarm T M urgent
if grep -q "ntfy.test/alarms" "$CALLS"; then fail "a disabled channel gets nothing, not even urgent"; else pass "a disabled channel gets nothing, not even urgent"; fi
C set alarms --enabled yes
echo "-- the provider limits the classes"
C set alarms --categories nonsense; check_eq "an unknown class is refused" 1 "$rc"
CIN "pw" add mailx --provider email --set host=smtp.example.org --set from=a@example.org --set to=b@example.org --secret password --categories heartbeat
check_eq "email cannot carry the heartbeat" 1 "$rc"
C --providers; check_out "the providers list their classes" "^email${T}host${T}.*${T}alarm,status,digest$" echo "$out"
echo "-- files are root only"
: > "$WORK/modeprobe"; chmod 600 "$WORK/modeprobe"
if [ "$(stat -c %a "$WORK/modeprobe" 2>/dev/null)" = 600 ]; then
  check "the folder is 0700" test "$(stat -c %a "$WORK/state/notify-channels" 2>/dev/null)" = 700
  check "a channel file is 0600" test "$(stat -c %a "$WORK/state/notify-channels/plain.conf" 2>/dev/null)" = 600
else
  skip "this file system keeps no modes (Windows): 0700 / 0600 not checked"
fi
echo "-- email: the provider talks SMTP through curl, the login never in argv"
: > "$CALLS"
CIN "s3cret" add mail --provider email --set host=smtp.example.org --set from=alerts@example.org --set to=me@example.org --set user=meuser --secret password
check_eq "email channel added" 0 "$rc"
C --list; check_out "outside, carries alarm status digest" "^mail${T}email${T}yes${T}min${T}respect${T}outside${T}file${T}ok${T}alarm,status,digest${T}alarm,status,digest${T}-${T}-${T}-$" echo "$out"
C test mail; check_eq "the test mail is handed to curl" 0 "$rc"
check_out "SMTP with STARTTLS on 587" "smtp://smtp.example.org:587 .*--ssl-reqd" calls
check_out "sender and recipient" "mail-from alerts@example.org --mail-rcpt me@example.org" calls
if grep -q "s3cret" "$CALLS"; then fail "the password is not in argv"; else pass "the password is not in argv"; fi
check "it travelled in a config file" grep -q '^user = "meuser:s3cret"$' "$CFG_OUT"
check "the message has a subject and the body" grep -q "Subject: .*test message" "$MAIL_OUT"
: > "$CALLS"; rm -f "$CFG_OUT"; $N --category problem "Home: disk" "disk sda is hot" high
check_out "a problem is mailed" "smtp.example.org" calls
: > "$CALLS"; $N --category heartbeat "host alive" "alive"
if grep -q "smtp.example.org" "$CALLS"; then fail "no heartbeat mail"; else pass "no heartbeat mail"; fi
CURL_FAIL_ON=smtp.example.org C test mail; check_eq "a refused mail exits 1 with the reason" 1 "$rc"
C set mail --set security=none --set port=2525; : > "$CALLS"; C test mail
check_out "plain SMTP on the port given" "smtp://smtp.example.org:2525" calls
C set mail --set security=ssl --set port=; C test mail
CIN "x" add bad --provider email --set host=smtp.example.org --set from=nope --set to=me@example.org --secret password; check_eq "a sender that is no address is refused" 1 "$rc"
CIN "x" add bad2 --provider email --set host=10.0.0.5 --set from=a@example.org --set to=me@example.org --set user=u --secret password
C --list; check_out "a private SMTP host is inside" "^bad2${T}email${T}yes${T}min${T}respect${T}inside" echo "$out"
for c in mail bad2 everything alarms plain; do C remove "$c" --yes; done

echo "-- the heartbeat address is a channel of its own"
rm -rf "$WORK/state/notify-channels"; rm -f "$HS_SETTINGS_DIR"/* "$WORK/state/heartbeat-url" "$WORK/state/notify-url"
printf 'https://ntfy.test/hb\n' > "$WORK/state/heartbeat-url"
C --list; check_eq "derived: only the heartbeat" "heartbeat${T}ntfy${T}yes${T}min${T}ignore${T}outside${T}derived${T}ok${T}heartbeat${T}alarm,status,heartbeat,digest${T}-${T}-${T}-" "$out"
: > "$CALLS"; $N --category problem T M urgent; check_eq "an alarm does not go to the heartbeat topic" 0 "$(n_calls)"
: > "$CALLS"; $N --category heartbeat "h alive" "alive"; check_out "the heartbeat does" "ntfy.test/hb" calls
check_out "with the heartbeat icon" "Tags: heartbeat," calls
printf 'https://ntfy.test/one\n' > "$WORK/state/notify-url"
C migrate; check "migrate writes both" test -f "$WORK/state/notify-channels/main.conf" -a -f "$WORK/state/notify-channels/heartbeat.conf"
C remove heartbeat --yes; check_eq "the heartbeat channel is removed" 0 "$rc"
check "and the setting with it" test ! -e "$WORK/state/heartbeat-url"
C --list; check_eq "only main is left" "main" "$(cut -f1 <<<"$out")"
printf 'https://ntfy.test/hb2\n' > "$WORK/state/heartbeat-url"
C --list; check_out "a heartbeat address set later is derived again, also after the migration" "^heartbeat${T}ntfy" echo "$out"

echo "-- the channels folder is not readable: the commands ask sudo (stand-in)"
printf '#!/usr/bin/env bash\necho "sudo $*" >> "%s/sudo.log"\nexit 0\n' "$WORK" > "$WORK/bin/sudo"; chmod +x "$WORK/bin/sudo"
chmod 000 "$WORK/state/notify-channels" 2>/dev/null || true
if [ -r "$WORK/state/notify-channels" ]; then
  chmod 700 "$WORK/state/notify-channels"
  skip "this system does not enforce file modes (root, or Windows): nothing to ask sudo for"
else
  rc=0; bash "$SCRIPTS/notify.sh" --category ok T M default </dev/null >/dev/null 2>&1 || rc=$?
  check "notify.sh ran sudo bash notify.sh" grep -q "^sudo -- bash .*notify.sh" "$WORK/sudo.log"
  rm -f "$WORK/sudo.log"; rc=0; bash "$SCRIPTS/notify-channel.sh" --list </dev/null >/dev/null 2>&1 || rc=$?
  check "and notify-channel.sh" grep -q "^sudo -- bash .*notify-channel.sh" "$WORK/sudo.log"
  chmod 700 "$WORK/state/notify-channels"
fi
rm -f "$WORK/bin/sudo"

echo "-- health: no enabled channel outside this server that carries alarms"
rm -rf "$WORK/state/notify-channels"; rm -f "$HS_SETTINGS_DIR"/* "$WORK/state"/*-url
printf 'notifications\n' > "$WORK/caps"
hk() { HS_CAPABILITIES_FILE=$WORK/caps HS_HEALTH_STATE=$WORK/h.state HS_ACK_FILE=$WORK/none HS_BACKUP_STATE=$WORK/none HS_NOW=1000000 bash "$SCRIPTS/health-check.sh" --keys 2>/dev/null </dev/null || true; }
out=$(hk)
if grep -q '^notify:no-outside-channel$' <<<"$out"; then pass "no channel at all: the warning"; else skip "health-check does not run here (needs the server's tools)"; fi
if grep -q '^notify:no-outside-channel$' <<<"$out"; then
  CIN "http://10.0.0.5/topic" add lan --provider ntfy --secret url
  out=$(hk); check_out "a channel on the LAN is not outside" '^notify:no-outside-channel$' echo "$out"
  CIN "https://ntfy.test/out" add out --provider ntfy --secret url --categories status
  out=$(hk); check_out "an outside channel that carries no alarms does not help" '^notify:no-outside-channel$' echo "$out"
  C set out --categories alarm,status
  out=$(hk); if grep -q 'no-outside' <<<"$out"; then fail "an outside channel with alarms: no warning"; else pass "an outside channel with alarms: no warning"; fi
  C set out --enabled no
  out=$(hk); check_out "disabled does not count" '^notify:no-outside-channel$' echo "$out"
  : > "$WORK/caps"
  out=$(hk); if grep -q 'no-outside' <<<"$out"; then fail "capability off: no warning"; else pass "capability off: no warning"; fi
fi

echo "-- the last send per channel and the problems it told"
rm -rf "$WORK/state/notify-channels" "$HS_SETTINGS_DIR"; mkdir -p "$HS_SETTINGS_DIR"; rm -f "$WORK/state/notify-url"
CIN "https://ntfy.test/r1" add main --provider ntfy --secret url
CIN "https://ntfy.test/r2" add second --provider ntfy --secret url
CIN "tok" add boomer --provider boom --secret token
: > "$CALLS"; $N --category problem T M high
C --list
check_out "a channel that took it: time, ok" "^main${T}ntfy${T}.*${T}[0-9]+${T}ok${T}-$" echo "$out"
check_out "a channel that failed: the short reason, no address" "^boomer${T}boom${T}.*${T}[0-9]+${T}failed${T}service said no$" echo "$out"
CURL_FAIL_ON=ntfy.test $N --category problem T M high || true
C --list
check_out "a failed send names the reason" "^main${T}ntfy${T}.*${T}failed${T}" echo "$out"
if grep -q 'ntfy.test' <<<"$out"; then fail "no address in the list"; else pass "no address in the list"; fi
check_eq "the scrubber drops addresses and long tokens" "failed: <address> then ..." "$(bash -c ". '$SCRIPTS/lib/channels.sh'; chan_scrub_reason 'failed: https://ntfy.sh/secrettopic then abcdefghijklmnopqrstuvwxyz0123'")"
$N --category problem T M high
HS_NOTIFY_KEYS=zfs:x:y,disk:a:b $N --category problem T M high
told() { bash -c ". '$SCRIPTS/lib/channels.sh'; chan_told_get '$1'"; }
check_eq "the channels that took the message are kept per problem" "main,second" "$(told zfs:x:y)"
check_eq "also for the second key" "main,second" "$(told disk:a:b)"
check_eq "a problem nobody was told about is a dash" "-" "$(told other:key)"
check "the folder holds them root only, next to the channels" test -f "$WORK/state/notify-channels/.told" -a -f "$WORK/state/notify-channels/.results"

echo "-- the sources of curl"
cnt=$(grep -lE '^[^#]*curl' "$SCRIPTS"/notify/*.sh "$SCRIPTS"/lib/channels.sh "$SCRIPTS"/lib/notify-route.sh "$SCRIPTS"/notify.sh "$SCRIPTS"/notify-channel.sh 2>/dev/null | grep -v "scripts/notify/" || true)
check_eq "no curl in the routing, the library or the commands" "" "$cnt"

finish
