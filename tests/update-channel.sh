#!/usr/bin/env bash
# Update channels (scripts/lib/update-channel.sh): which tag or branch each channel picks, the signature check, hs update on edge.
# Git repositories in temp dirs, no network, no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test
. "$SCRIPTS/lib/ui.sh"
. "$SCRIPTS/lib/update-channel.sh"
G="git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c tag.gpgsign=false"
export HS_STATE_DIR=$WORK/state HS_SETTINGS_DIR=$WORK/settings HS_ETC_DIR=$WORK/etc
mkdir -p "$HS_STATE_DIR" "$HS_SETTINGS_DIR"

mk() {   # mk <dir> <tag>...: a repository with one commit per tag (lightweight tags)
  local d=$1; shift
  git init -q "$d"
  echo 0 > "$d/f"; ( cd "$d" && $G add f && $G commit -q -m zero )
  local t n=0
  for t in "$@"; do
    n=$((n + 1)); echo "$n" > "$d/f"; ( cd "$d" && $G commit -q -am "c$n" && $G tag "$t" )
  done
}
pick() { uc_target "$1" "$2" | cut -f1,2 | tr '\t' ' '; }

echo "-- which ref a channel picks"
mk "$WORK/a" v1.3.0 v1.4.0-beta.1 v1.4.0-beta.2 v1.4.0-beta.10 v1.4.0-beta.9
check_eq "stable ignores beta tags" "tag v1.3.0" "$(pick "$WORK/a" stable)"
check_eq "beta: the newest beta number counts (10 > 9)" "tag v1.4.0-beta.10" "$(pick "$WORK/a" beta)"
mk "$WORK/b" v1.3.0 v1.4.0-beta.2 v1.4.0
check_eq "beta picks the release over its own beta" "tag v1.4.0" "$(pick "$WORK/b" beta)"
check_eq "stable picks the release" "tag v1.4.0" "$(pick "$WORK/b" stable)"
mk "$WORK/c" v1.4.0 v1.5.0-beta.1
check_eq "beta picks a newer beta over the release" "tag v1.5.0-beta.1" "$(pick "$WORK/c" beta)"
check_eq "stable stays on the release" "tag v1.4.0" "$(pick "$WORK/c" stable)"
mk "$WORK/d" v1.9.0 v1.10.0 v1.10.0-rc1 v2
check_eq "numbers sort as numbers (1.10 > 1.9); other names are ignored" "tag v1.10.0" "$(pick "$WORK/d" stable)"
check_eq "unknown channel behaves as stable" "tag v1.4.0" "$(pick "$WORK/c" nonsense)"
mk "$WORK/e"
check_eq "no tags: kind none" "none -" "$(pick "$WORK/e" stable)"
check_eq "no tags, beta: kind none" "none -" "$(pick "$WORK/e" beta)"
check_eq "edge is the branch origin/develop" "branch origin/develop" "$(pick "$WORK/e" edge)"

echo "-- the setting"
check_eq "no setting: stable" "stable" "$(uc_channel)"
echo beta > "$HS_SETTINGS_DIR/updateChannel"
check_eq "beta" "beta" "$(uc_channel)"
echo edge > "$HS_SETTINGS_DIR/updateChannel"
check_eq "edge" "edge" "$(uc_channel)"
echo nightly > "$HS_SETTINGS_DIR/updateChannel"
check_eq "an unknown value is stable" "stable" "$(uc_channel)"
rm -f "$HS_SETTINGS_DIR/updateChannel"
check_eq "last channel without a file: stable" "stable" "$(uc_last)"
uc_remember beta
check_eq "last channel is remembered" "beta" "$(uc_last)"

echo "-- signature"
if ! have ssh-keygen; then skip "ssh-keygen is missing: the signature tests"; finish; fi
R=$WORK/signed
mk "$R"
mkdir -p "$R/config/trusted-keys"
check_out "no signers file: refused with a hint" "release key" bash -c ". '$SCRIPTS/lib/ui.sh'; . '$SCRIPTS/lib/update-channel.sh'; uc_verify '$R' v1.0.0"
ssh-keygen -q -t ed25519 -N '' -f "$WORK/key" -C t >/dev/null
ssh-keygen -q -t ed25519 -N '' -f "$WORK/other" -C o >/dev/null
printf 'rel namespaces="git" %s\n' "$(cut -d' ' -f1,2 "$WORK/key.pub")" > "$R/config/trusted-keys/server.allowed_signers"
SIGN="-c gpg.format=ssh -c user.signingkey=$WORK/key.pub -c user.name=t -c user.email=t@t"
( cd "$R" && git $SIGN tag -s v1.0.0 -m rel 2>/dev/null )   # ssh-agent-less signing needs the private key file
if [ -z "$(git -C "$R" cat-file -p v1.0.0 2>/dev/null | grep -c 'BEGIN SSH SIGNATURE' | grep -v '^0$')" ]; then
  skip "this ssh-keygen/git cannot sign tags here"; finish
fi
( cd "$R" && git -c gpg.format=ssh -c user.signingkey="$WORK/other.pub" -c user.name=t -c user.email=t@t tag -s v1.0.1 -m x 2>/dev/null || true )
( cd "$R" && $G tag -a v1.0.2 -m unsigned )
if uc_verify "$R" v1.0.0; then pass "a tag signed with the trusted key verifies"; else fail "signed tag refused"; fi
if uc_verify "$R" v1.0.2; then fail "an unsigned tag was accepted"; else pass "an unsigned tag is refused"; fi
if git -C "$R" rev-parse -q --verify v1.0.1 >/dev/null; then
  if uc_verify "$R" v1.0.1; then fail "a tag signed with an unknown key was accepted"; else pass "a tag signed with another key is refused"; fi
fi

git -C "$R" update-ref refs/tags/v1.0.9 "$(git -C "$R" rev-parse v1.0.0)"   # the same signed object under a newer name
if uc_verify "$R" v1.0.9; then fail "a signed tag under another name was accepted"; else pass "the name inside the signed tag must equal the ref"; fi

echo "-- hs update on edge"
UP=$WORK/up.git; CL=$WORK/clone; PU=$WORK/pusher; BIN=$WORK/bin; mkdir -p "$BIN"
git init -q --bare "$UP"; git clone -q "$UP" "$PU" 2>/dev/null
( cd "$PU" && git checkout -q -b main && echo a > f && $G add f && $G commit -q -m one && git push -q origin main 2>/dev/null \
  && git checkout -q -b develop && echo b > f && $G commit -q -am dev && git push -q origin develop 2>/dev/null )
git -C "$UP" symbolic-ref HEAD refs/heads/main
git clone -q "$UP" "$CL" 2>/dev/null
mkdir -p "$CL/scripts"
printf '#!/bin/sh\nshift 3\nexec "$@"\n' > "$BIN/sudo"; chmod +x "$BIN/sudo"
printf '#!/bin/sh\nexit 0\n' > "$BIN/logger"; chmod +x "$BIN/logger"
printf '#!/usr/bin/env bash\necho "REBUILD RAN"\n' > "$CL/scripts/rebuild.sh"
export HS_REPO=$CL HS_LOCKED_MARKER=$WORK/nolock HS_MACHINE_FILE=$WORK/none.toml
U="bash $SCRIPTS/update.sh"
echo edge > "$HS_SETTINGS_DIR/updateChannel"
env PATH="$BIN:$PATH" $U > "$WORK/u.out" 2>&1 < /dev/null
check_out "edge without a terminal and without --yes stops with a note" "skipped, because no person" cat "$WORK/u.out"
check_eq "...and does not rebuild" "0" "$(grep -c 'REBUILD RAN' "$WORK/u.out")"
printf 'x\n' | env PATH="$BIN:$PATH" HS_GUIDED_TTY=1 $U > "$WORK/u.out" 2>&1
check_out "switching up asks for the name; a wrong answer stops" "name did not match" cat "$WORK/u.out"
printf 'edge\n' | env PATH="$BIN:$PATH" HS_GUIDED_TTY=1 $U > "$WORK/u.out" 2>&1
check_out "the right name goes on" "channel: edge \(develop\)" cat "$WORK/u.out"
check_eq "the checkout is on develop at the head of origin/develop" "develop $(git -C "$UP" rev-parse develop)" "$(git -C "$CL" rev-parse --abbrev-ref HEAD) $(git -C "$CL" rev-parse HEAD)"
check_eq "the channel is remembered" "edge" "$(uc_last)"
( cd "$PU" && echo c > f && $G commit -q -am dev2 && git push -q origin develop 2>/dev/null )
env PATH="$BIN:$PATH" $U --yes > "$WORK/u.out" 2>&1 < /dev/null
check_eq "--yes follows develop without asking" "$(git -C "$UP" rev-parse develop)" "$(git -C "$CL" rev-parse HEAD)"
check_eq "no question was asked" "0" "$(grep -c 'Type edge' "$WORK/u.out")"

echo "-- the web's Update counts as confirmed"
printf '#!/bin/sh
exit 0
' > "$BIN/preview"
out=$(env HS_CALLER=web HS_UPDATE_PREVIEW="$BIN/preview" HS_LOCKED_MARKER=$WORK/nolock bash "$SCRIPTS/system-change.sh" plan update 2>&1 || true)
if grep -q "^command.*update.sh --yes" <<<"$out"; then pass "web: the job runs update.sh --yes"; else fail "web update job has no --yes: $out"; fi
out=$(env HS_CALLER=timer HS_UPDATE_PREVIEW="$BIN/preview" HS_LOCKED_MARKER=$WORK/nolock bash "$SCRIPTS/system-change.sh" plan update 2>&1 || true)
if grep -q "^command.*--yes" <<<"$out"; then fail "a timer got --yes"; else pass "a timer does not get --yes"; fi

echo "-- local commits and a tag"
UP2=$WORK/up2.git; PU2=$WORK/pusher2; CL2=$WORK/clone2
git init -q --bare "$UP2"; git clone -q "$UP2" "$PU2" 2>/dev/null
mkdir -p "$PU2/config/trusted-keys"; cp "$R/config/trusted-keys/server.allowed_signers" "$PU2/config/trusted-keys/"
( cd "$PU2" && git checkout -q -b main && echo a > f && $G add -A && $G commit -q -m one && git $SIGN tag -s v1.0.0 -m rel 2>/dev/null   && git push -q origin main v1.0.0 2>/dev/null )
git -C "$UP2" symbolic-ref HEAD refs/heads/main
git clone -q "$UP2" "$CL2" 2>/dev/null
mkdir -p "$CL2/scripts"; printf '#!/usr/bin/env bash
echo "REBUILD RAN"
' > "$CL2/scripts/rebuild.sh"
rm -f "$HS_SETTINGS_DIR/updateChannel"; rm -f "$HS_STATE_DIR/update-channel"
export HS_REPO=$CL2
( cd "$CL2" && echo mine > g && $G add g && $G commit -q -m local )
env PATH="$BIN:$PATH" $U > "$WORK/u.out" 2>&1 < /dev/null; rc=$?
check_out "local commits on top of the tag: refused with a clear text" "local commit.*no remote has" cat "$WORK/u.out"
check_eq "...exit 1 and no rebuild" "1 0" "$rc $(grep -c 'REBUILD RAN' "$WORK/u.out")"
check_eq "...and HEAD did not move" "main" "$(git -C "$CL2" rev-parse --abbrev-ref HEAD)"
git -C "$CL2" push -q origin main 2>/dev/null
env PATH="$BIN:$PATH" $U > "$WORK/u.out" 2>&1 < /dev/null; rc=$?
check_out "HEAD ahead of the tag, commits published: already the latest" "Already the latest" cat "$WORK/u.out"
check_eq "...and HEAD stays on its branch" "main" "$(git -C "$CL2" rev-parse --abbrev-ref HEAD)"

finish

