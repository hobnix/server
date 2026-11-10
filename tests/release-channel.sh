#!/usr/bin/env bash
# hs sys release show|plan|start (scripts/release-channel.sh, scripts/release-change.sh): the update channel switch of the web interface, against
# git repositories in temp dirs. No network, no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test
unset HS_GUIDED_TTY
G="git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c tag.gpgsign=false"
export HS_STATE_DIR=$WORK/state HS_SETTINGS_DIR=$WORK/settings HS_ETC_DIR=$WORK/etc
mkdir -p "$HS_STATE_DIR" "$HS_SETTINGS_DIR"
R=$WORK/repo
export HS_REPO=$R
show() { rc=0; out=$(timeout 30 bash "$SCRIPTS/release-channel.sh" --show </dev/null 2>/dev/null) || rc=$?; }
run() { rc=0; out=$(timeout 30 bash "$SCRIPTS/release-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }
has() { grep -q -- "$1" <<<"$out"; }
chan() { cat "$HS_SETTINGS_DIR/updateChannel" 2>/dev/null || echo unset; }

echo "-- rows exist"
check "release show row" grep -q "^sys.sys release show.release-channel.sh.--show." "$SCRIPTS/lib/registry.tsv"
check "release plan row" grep -q "^sys.sys release plan <action>.release-change.sh.plan {1} {rest}" "$SCRIPTS/lib/registry.tsv"
check "release start row" grep -q "^sys.sys release start <action>.release-change.sh.start {1} {rest}" "$SCRIPTS/lib/registry.tsv"

echo "-- no tags yet"
git init -q "$R"; echo 0 > "$R/f"; ( cd "$R" && $G add f && $G commit -q -m zero )
show
check_eq "show: exit 0" 0 "$rc"
has '^channel	stable$' && has '^offer	stable	-	none$' && has '^offer	edge	origin/develop	unknown$' && has '^ref	-$' && has '^state	none$' && has '^signed	-$' && pass "show without tags" || fail "show: $out"
run plan channel nightly
check_eq "an unknown channel: refused" 1 "$rc"
run plan channel stable
check_eq "the channel it is on: refused" 1 "$rc"
run plan channel beta
check_eq "plan to beta: exit 0" 0 "$rc"
has '^status	ok$' && has '^note	There is no release tag for beta yet' && has '^danger	' && has '^confirm_name	beta$' && pass "newer channel: danger and its name" || fail "beta plan: $out"
check_eq "plan changes nothing" "unset" "$(chan)"
run start channel beta
check_eq "start without the name: refused" 1 "$rc"
run start channel beta --confirm stable
check_eq "start with the wrong name: refused" 1 "$rc"
check_eq "still nothing changed" "unset" "$(chan)"
run start channel beta --confirm beta
check_eq "start with the name: exit 0" 0 "$rc"
has '^status	done$' && pass "status done" || fail "start: $out"
check_eq "the setting is written" "beta" "$(chan)"
run plan channel stable
has '^danger' && fail "moving back is not red" || pass "moving back to an older channel asks for no name"
run start channel stable
check_eq "back to stable: exit 0, no name" 0 "$rc"
check_eq "setting is stable again" "stable" "$(chan)"
run plan channel edge --frob x
check_eq "an unknown option: refused" 1 "$rc"
run plan frobnicate beta
check_eq "an unknown action: refused" 1 "$rc"

echo "-- an unsigned tag is refused"
( cd "$R" && $G tag -a v1.0.0 -m unsigned )
run plan channel beta
check_eq "unsigned beta target: refused" 1 "$rc"
has '^status	refused$' && has 'signature' && pass "the refusal names the signature" || fail "unsigned: $out"
check_eq "refusal writes nothing" "stable" "$(chan)"

echo "-- signed tags"
if ! have ssh-keygen; then skip "ssh-keygen is missing: the signature tests"; finish; fi
rm -rf "$R"; git init -q "$R"; echo 0 > "$R/f"; ( cd "$R" && $G add f && $G commit -q -m zero )
mkdir -p "$R/config/trusted-keys"
ssh-keygen -q -t ed25519 -N '' -f "$WORK/key" -C t >/dev/null
printf 'rel namespaces="git" %s\n' "$(cut -d' ' -f1,2 "$WORK/key.pub")" > "$R/config/trusted-keys/server.allowed_signers"
SIGN="-c gpg.format=ssh -c user.signingkey=$WORK/key.pub -c user.name=t -c user.email=t@t"
( cd "$R" && git $SIGN tag -s v1.0.0 -m rel 2>/dev/null )
if [ -z "$(git -C "$R" cat-file -p v1.0.0 2>/dev/null | grep -c 'BEGIN SSH SIGNATURE' | grep -v '^0$')" ]; then
  skip "this ssh-keygen/git cannot sign tags here"; finish
fi
echo 1 > "$R/f"; ( cd "$R" && $G commit -q -am one && git $SIGN tag -s v1.1.0-beta.1 -m beta 2>/dev/null )   # HEAD is the beta
rm -f "$HS_SETTINGS_DIR/updateChannel"
show
has '^offer	stable	v1.0.0	kept$' && has '^offer	beta	v1.1.0-beta.1	current$' && has '^ref	v1.0.0$' && has '^state	kept$' && has '^signed	yes$' && pass "show: stable is older than the installed beta" || fail "show: $out"
run plan channel beta
has '^status	ok$' && has '^note	No update is waiting' && has '^confirm_name	beta$' && pass "plan to beta: no update waiting, asks for the name" || fail "beta: $out"
run start channel beta --confirm beta
check_eq "beta set" "beta" "$(chan)"
run plan channel stable
check_eq "plan back to stable: exit 0" 0 "$rc"
has '^note	The installed version .* stays: v1.0.0 is older, so there is no downgrade' && pass "moving back keeps the installed version and says so" || fail "kept: $out"
has '^danger' && fail "no name to go back" || pass "no name to go back"
echo 2 > "$R/f"; ( cd "$R" && $G commit -q -am two && $G tag -a v1.2.0 -m unsigned )
run plan channel stable
check_eq "stable tag unsigned: refused" 1 "$rc"
rm -f "$HS_SETTINGS_DIR/updateChannel"
show
has '^signed	no$' && pass "show: an unsigned tag is marked" || fail "show unsigned: $out"
finish
