#!/usr/bin/env bash
# hs sys routes plan|start (scripts/services-change.sh): apply, adopt, import and remove for the services of the reverse proxy. Apply is red
# (typed word) when a route goes public, changes or goes away. A fake services.sh stands in: no proxy, no containers.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en
unset HS_CALLER HS_GUIDED_TTY
T=$'\t'
CALLS=$WORK/calls; : > "$CALLS"
export FAKE_PLAN=$WORK/plan.tsv FAKE_IMPORT=$WORK/import.txt
cat > "$WORK/services.sh" <<FAKE
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
case "\$1" in
  list) printf 'jellyfin${T}Jellyfin${T}jellyfin:8096${T}private-ok${T}-${T}reverse-proxy\n' ;;
  show) [ "\$2" = jellyfin ] || exit 3; printf 'name${T}jellyfin
exposure${T}%s
' "\${FAKE_EXPOSURE:-private-ok}" ;;
  plan) cat "\$FAKE_PLAN" ;;
  import) cat "\$FAKE_IMPORT" ;;
esac
FAKE
export HS_SERVICES=$WORK/services.sh
run() { rc=0; out=$(timeout 20 bash "$SCRIPTS/services-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }

echo "-- no proxy"
printf 'status\tnone\n' > "$FAKE_PLAN"
run plan apply; check_eq "no proxy: refused" 1 "$rc"; has "No reverse proxy" && pass "reason" || fail "$out"

echo "-- apply: only additions are not red"
printf 'add\tjf.lan\t/\thttp://10.0.0.5:8096\tjellyfin\t-\nok\tx.lan\t/\thttp://a\tx\tfine\n' > "$FAKE_PLAN"
run plan apply; check_eq "plan: exit 0" 0 "$rc"
has "^step${T}add jf.lan/" && pass "lists the route" || fail "$out"
has "^confirm_name" && fail "an add alone must not be red" || pass "no typed word for an add"
run start apply --now 2>/dev/null; check_eq "start refuses an unknown option" 1 "$rc"

echo "-- apply: a public route is red"
printf 'confirm\tpub.example.com\t/\thttp://10.0.0.6:80\tblog\t-\nremove\told.lan\t/\thttp://b\t-\t-\n' > "$FAKE_PLAN"
run plan apply; check_eq "plan: exit 0" 0 "$rc"
has "^danger${T}pub.example.com goes on the internet" && pass "danger line" || fail "$out"
has "^confirm_name${T}apply" && pass "asks for the word apply" || fail "$out"
run start apply; check_eq "no word: refused" 1 "$rc"
run start apply --confirm nope; check_eq "wrong word: refused" 1 "$rc"
: > "$CALLS"

echo "-- apply: nothing to do and blocked rows"
printf 'blocked\tadmin.lan\t/\thttp://c\tadm\tnever public\nok\tx.lan\t/\thttp://a\tx\tfine\n' > "$FAKE_PLAN"
run plan apply; check_eq "nothing to do: refused" 1 "$rc"

echo "-- adopt"
printf 'ok\tmanual.lan\t/\thttp://d\tm\tnot adopted: made by hand\n' > "$FAKE_PLAN"
run plan adopt; check_eq "plan: exit 0" 0 "$rc"
has "manual.lan/ -> http://d (m)" && pass "lists the route" || fail "$out"
: > "$CALLS"; run start adopt; check_eq "start: exit 0" 0 "$rc"
has "^status${T}done" && pass "done" || fail "$out"
grep -qx "adopt --yes" "$CALLS" && pass "services.sh adopt --yes" || fail "$(cat "$CALLS")"
printf 'ok\tx.lan\t/\thttp://a\tx\tfine\n' > "$FAKE_PLAN"
run plan adopt; check_eq "nothing to adopt: refused" 1 "$rc"

echo "-- import"
printf 'Nothing new to describe.\n' > "$FAKE_IMPORT"
run plan import; check_eq "nothing new: refused" 1 "$rc"
printf 'create  jf  jellyfin:8096  private-ok  jf.lan\n' > "$FAKE_IMPORT"
run plan import; check_eq "plan: exit 0" 0 "$rc"
: > "$CALLS"; run start import; check_eq "start: exit 0" 0 "$rc"
grep -qx "import --yes" "$CALLS" && pass "services.sh import --yes" || fail "$(cat "$CALLS")"

echo "-- remove"
run plan remove jellyfin; check_eq "plan: exit 0" 0 "$rc"
has "routes on the reverse proxy stay" && pass "says the routes stay" || fail "$out"
run plan remove nosuch; check_eq "unknown service: refused" 1 "$rc"
run plan remove 'a b';  check_eq "bad name: refused" 1 "$rc"
: > "$CALLS"; run start remove jellyfin; check_eq "start: exit 0" 0 "$rc"
grep -qx "remove jellyfin" "$CALLS" && pass "services.sh remove jellyfin" || fail "$(cat "$CALLS")"

echo "-- add"
run plan add wiki --port 3000 --container wiki --title Wiki; check_eq "plan: exit 0" 0 "$rc"
has "^step${T}write the description of wiki" && pass "step" || fail "$out"
has "^confirm_name" && fail "private-ok is not red" || pass "no typed word for private-ok"
: > "$CALLS"; run start add wiki --port 3000 --container wiki --names wiki,w; check_eq "start: exit 0" 0 "$rc"
grep -qx "add wiki --port 3000 --container wiki --names wiki,w" "$CALLS" && pass "services.sh add gets the options" || fail "$(cat "$CALLS")"
run plan add jellyfin --port 1 --host x; check_eq "name taken: refused" 1 "$rc"
run plan add wiki --port 0 --host x; check_eq "port 0: refused" 1 "$rc"
run plan add wiki --port 80; check_eq "no target: refused" 1 "$rc"
run plan add wiki --port 80 --host x --container y; check_eq "both targets: refused" 1 "$rc"
run plan add wiki --port 80 --host x --exposure open; check_eq "bad exposure: refused" 1 "$rc"
run plan add 'W k' --port 80 --host x; check_eq "bad name: refused" 1 "$rc"
run plan add wiki --port 80 --host x --exposure public-ok; has "^confirm_name${T}wiki" && pass "public-ok asks for the name" || fail "$out"
run start add wiki --port 80 --host x --exposure public-ok; check_eq "public-ok without the word: refused" 1 "$rc"
run start add wiki --port 80 --host x --exposure public-ok --confirm wiki; check_eq "with the word: exit 0" 0 "$rc"
run plan apply --port 3; check_eq "add options on another action: refused" 1 "$rc"

echo "-- bad calls"
run plan bogus; check_eq "unknown action: refused" 1 "$rc"
run plan apply --bogus; check_eq "unknown option: refused" 1 "$rc"
echo "-- set"
run plan set jellyfin --local yes; check_eq "plan: exit 0" 0 "$rc"
has "^step${T}give a local name for jellyfin" && pass "lists the local name" || fail "$out"
has "^confirm_name" && fail "a local name alone must not be red" || pass "local alone has no typed word"
run plan set jellyfin --public yes --public-name media.example.org; has "^confirm_name${T}jellyfin" && pass "public yes asks for the name" || fail "$out"
run plan set jellyfin --public no; has "^confirm_name" && fail "public no must not be red" || pass "public no has no typed word"
run plan set jellyfin --public yes; check_eq "public without a name: refused" 1 "$rc"
run plan set jellyfin --public-name 'not a name'; check_eq "bad public name: refused" 1 "$rc"
run plan set jellyfin --local maybe; check_eq "bad yes/no: refused" 1 "$rc"
run plan set jellyfin; check_eq "nothing to change: refused" 1 "$rc"
run plan set nosuch --local yes; check_eq "unknown service: refused" 1 "$rc"
run plan set 'W k' --local yes; check_eq "bad name: refused" 1 "$rc"
run plan remove jellyfin --local yes; check_eq "set option on another action: refused" 1 "$rc"
: > "$CALLS"; run start set jellyfin --public yes --public-name media.example.org; check_eq "public without the word: refused" 1 "$rc"
: > "$CALLS"; run start set jellyfin --public yes --public-name media.example.org --confirm jellyfin; check_eq "with the word: exit 0" 0 "$rc"
grep -qx "set jellyfin --public yes --public-name media.example.org" "$CALLS" && pass "services.sh set gets the options" || fail "$(cat "$CALLS")"
run start set jellyfin --local no; check_eq "start local: exit 0" 0 "$rc"
echo "-- the local slot (--proxy local)"
: > "$CALLS"
printf 'add	app.lan	/	10.0.0.5:80	app	-
' > "$FAKE_PLAN"
run plan apply --proxy local; check_eq "plan apply --proxy local: exit 0" 0 "$rc"
check_out "plan asks services.sh for the local slot" "^plan --plain --proxy local" cat "$CALLS"
has "^command${T}hs services apply --yes --proxy local" && pass "the command carries --proxy local" || fail "$out"
: > "$CALLS"
run plan apply; has "^command${T}hs services apply --yes\$" && pass "without it the command is unchanged" || fail "$out"
check_eq "and asks for the public plan" "plan --plain" "$(head -n1 "$CALLS")"
run plan import --proxy local; check_eq "import --proxy local is accepted" 0 "$rc"
run plan remove x --proxy local; check_eq "--proxy on remove is refused" 1 "$rc"
run plan apply --proxy other; check_eq "a bad --proxy is refused" 1 "$rc"

echo "-- edit"
run plan edit jellyfin --title Jelly; check_eq "plan: exit 0" 0 "$rc"
has "^note${T}Nothing is sent to the reverse proxy" && pass "says nothing is sent" || fail "$out"
has "^note${T}If a recipe declared" && pass "warns about recipes" || fail "$out"
has "^confirm_name" && fail "a plain edit must not be red" || pass "no typed word for a plain edit"
run plan edit nosuch --title X; check_eq "unknown service: refused" 1 "$rc"
run plan edit jellyfin; check_eq "nothing to change: refused" 1 "$rc"
run plan edit jellyfin --port 0; check_eq "port 0: refused" 1 "$rc"
run plan edit jellyfin --host x --container y; check_eq "both targets: refused" 1 "$rc"
run plan edit jellyfin --exposure open; check_eq "bad exposure: refused" 1 "$rc"
run plan edit 'J k' --title X; check_eq "bad name: refused" 1 "$rc"
run plan edit jellyfin --clear title --clear names; check_eq "--clear is accepted" 0 "$rc"
run plan add wiki --port 80 --host x --clear title; check_eq "--clear on add is refused" 1 "$rc"
run plan edit jellyfin --exposure public-ok; has "^confirm_name${T}jellyfin" && pass "going public asks for the name" || fail "$out"
run start edit jellyfin --exposure public-ok; check_eq "going public without the word: refused" 1 "$rc"
: > "$CALLS"; run start edit jellyfin --exposure public-ok --confirm jellyfin; check_eq "with the word: exit 0" 0 "$rc"
grep -qx "edit jellyfin --exposure public-ok" "$CALLS" && pass "services.sh edit gets the options" || fail "$(cat "$CALLS")"
export FAKE_EXPOSURE=public-ok
run plan edit jellyfin --exposure public-ok --title J; has "^confirm_name" && fail "already public: no word" || pass "already public-ok: no typed word"
run plan edit jellyfin --exposure private-ok; has "^warn${T}jellyfin is public-ok today" && pass "leaving public-ok warns" || fail "$out"
unset FAKE_EXPOSURE
finish
