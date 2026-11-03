#!/usr/bin/env bash
# hs docker move-apps (scripts/docker.sh): the apps of /opt/apps into the share apps, with a fake incus that runs the commands on a temp tree
# and a fake docker (a marker file per running project). No root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1
BIN=$WORK/bin; mkdir -p "$BIN"
T=$WORK/tree
export OPT=$T/opt/apps SHR=$T/shares/apps
export HS_DOCKER_APPS_LEGACY=$OPT HS_DOCKER_APPS_ROOT=$SHR
export HS_FAST=$T/fast HS_BULK=$T/bulk HS_ZFS=false
export HS_SETTINGS_DIR=$WORK/settings HS_STATE_DIR=$WORK/state HS_CAPABILITIES_FILE=$WORK/caps HS_DOCKER_NO_JOB=1
export DLOG=$WORK/docker.log CLOG=$WORK/ct.log UPFAIL=$WORK/upfail STUCK=$WORK/stuck NOMOUNT=$WORK/nomount ST=$WORK/running SLOWMARK=$WORK/slow
REALMV=$(command -v mv); export REALMV REALCP=$(command -v cp)
mkdir -p "$HS_SETTINGS_DIR" "$HS_STATE_DIR/backup-dump" "$HS_FAST/shares/apps" "$OPT" "$SHR/stacks" "$SHR/recipes" "$ST"
: > "$HS_CAPABILITIES_FILE"; : > "$DLOG"; : > "$CLOG"

cat > "$BIN/incus" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  info) exit 0 ;;
  query) echo '{"type":"container","config":{"user.hs.managed_by":"docker"},"expanded_devices":{}}' ;;
  config) exit 0 ;;
  list) echo RUNNING ;;
  exec) shift 3; [ "$1" = -- ] && shift; exec "$@" ;;
esac
exit 0
FAKE
cat > "$BIN/docker" <<'FAKE'
#!/usr/bin/env bash
# docker compose down | up -d | ps -q | ps -aq, run in the folder of the app; the project is the folder name; no -p
echo "docker $* in $PWD" >> "$DLOG"
proj=$(basename "$PWD"); m=$ST/$proj
case "$2" in
  down) grep -qx "$proj" "$STUCK" 2>/dev/null && exit 0; rm -f "$m" ;;
  up) if grep -qx "$proj" "$UPFAIL" 2>/dev/null && [ "${PWD#"$SHR"}" != "$PWD" ]; then exit 1; fi; : > "$m" ;;
  ps) [ -e "$m" ] && echo cid123 ;;
esac
exit 0
FAKE
cat > "$BIN/mountpoint" <<'FAKE'
#!/usr/bin/env bash
[ ! -e "$NOMOUNT" ]
FAKE
cat > "$BIN/chown" <<'FAKE'
#!/usr/bin/env bash
echo "chown $*" >> "$DLOG"
FAKE
cat > "$BIN/mv" <<'FAKE'
#!/usr/bin/env bash
# the old folder of "nomv" can not be renamed
case "${*: -1}" in *nomv.moved-*) exit 1 ;; esac
exec "$REALMV" "$@"
FAKE
cat > "$BIN/cp" <<'FAKE'
#!/usr/bin/env bash
# copying "slow" takes a while (the test stops the run meanwhile)
case "${*: -1}" in *slow.partial) : > "$SLOWMARK"; sleep 3 ;; esac
exec "$REALCP" "$@"
FAKE
cat > "$BIN/ctchange" <<'FAKE'
#!/usr/bin/env bash
echo "ct-change $*" >> "$CLOG"
FAKE
chmod +x "$BIN"/*
export PATH="$BIN:$PATH" HS_CT_CHANGE=$BIN/ctchange
D="bash $SCRIPTS/docker.sh move-apps"

mk() {   # mk <app> <running yes|no> <compose text> [web]: a folder in /opt/apps
  mkdir -p "$OPT/$1"; printf '%s\n' "$3" > "$OPT/$1/docker-compose.yml"
  if [ "${4:-}" = web ]; then : > "$OPT/$1/.hs-webui"; fi
  if [ "$2" = yes ]; then : > "$ST/$1"; fi
}
fresh() { rm -rf "$T/opt" "$SHR" "$ST"; mkdir -p "$OPT" "$SHR/stacks" "$SHR/recipes" "$ST"; rm -f "$UPFAIL" "$STUCK" "$NOMOUNT" "$SLOWMARK"; : > "$DLOG"; : > "$CLOG"; : > "$HS_STATE_DIR/backup-dump/docker"; }
mkapps() {
  fresh
  mk webby yes "volumes: [$OPT/webby/data:/data]" web; mkdir -p "$OPT/webby/data"; echo hello > "$OPT/webby/data/f.txt"
  mk reci yes "volumes: [$OPT/reci/config:/config]"
  printf 'DIR=%s/reci/config\n' "$OPT" > "$OPT/reci/.env"
  printf 'volumes: [%s/reci/extra:/e]\n' "$OPT" > "$OPT/reci/docker-compose.override.yml"
  mk rad yes "volumes: [$OPT/rad/data:/data]"
  mk rad2 yes "volumes: [$OPT/rad2/data:/data]"
  mk linky yes "volumes: [$OPT/linky/c:/c, $OPT/rad/downloads:/dl]"
  mk quiet no "volumes: [$OPT/quiet/data:/data]"
  mk bad yes "image: y"; printf 'bad\n' > "$UPFAIL"
  mk stuck yes "image: z"; printf 'stuck\n' > "$STUCK"
  mk nomv yes "volumes: [$OPT/nomv/d:/d]"
  mkdir -p "$OPT/.hs-tmp" "$OPT/old.moved-2020-01-01" "$SHR/recipes/rad2.partial"; echo junk > "$SHR/recipes/rad2.partial/junk"
  printf 'docker exec x tool --dir %s/reci/config\n' "$OPT" > "$HS_STATE_DIR/backup-dump/docker"
}
snap() { find "$T" \( -type f -o -type d \) | sort | md5sum; }

echo "-- dry run changes nothing"
mkapps
before=$(snap)
out=$($D --dry-run 2>&1); rc=$?
check_eq "exit 0" 0 "$rc"
check_eq "tree unchanged" "$before" "$(snap)"
case "$out" in *webby*stacks/webby*) pass "web app goes to stacks" ;; *) fail "plan: $out" ;; esac
case "$out" in *reci*recipes/reci*) pass "recipe goes to recipes" ;; *) fail "plan: $out" ;; esac
case "$out" in *hs-tmp*|*old.moved*) fail "plan lists a skipped folder" ;; *) pass "tmp and moved folders skipped" ;; esac
case "$out" in *"Size to copy"*"Free on the SSD pool"*) pass "plan has size and free space" ;; *) fail "no size lines: $out" ;; esac
check_eq "no docker call" "" "$(cat "$DLOG")"
check_eq "no snapshot" "" "$(cat "$CLOG")"

echo "-- refusals"
out=$($D --yes 2>&1); rc=$?
check_eq "--yes without --confirm refused" 1 "$rc"
check_eq "tree unchanged after refusal" "$before" "$(snap)"
: > "$NOMOUNT"
out=$($D --dry-run 2>&1); rc=$?
check_eq "share not mounted in docker refused" 1 "$rc"
case "$out" in *"not mounted"*) pass "reason names the mount" ;; *) fail "reason: $out" ;; esac
rm -f "$NOMOUNT"
mkdir -p "$SHR/stacks/webby"
out=$($D --yes --confirm docker 2>&1); rc=$?
check_eq "existing target refused" 1 "$rc"
case "$out" in *"exists already"*) pass "reason names the target" ;; *) fail "reason: $out" ;; esac
check_eq "nothing moved" "" "$(cat "$DLOG")"
test -d "$OPT/webby" && pass "old folder still there" || fail "old folder gone"

echo "-- move"
mkapps
out=$($D --yes --confirm docker 2>&1); rc=$?
check_eq "exit 1 (some apps stayed)" 1 "$rc"
grep -q 'ct-change start docker snapshot' "$CLOG" && pass "snapshot taken" || fail "no snapshot: $(cat "$CLOG")"
grep -q 'docker compose down in .*/opt/apps/webby' "$DLOG" && pass "down runs in the folder of the app" || fail "no down: $(cat "$DLOG")"
grep -q ' -p ' "$DLOG" && fail "docker was called with -p" || pass "no -p override"
# web app
test -f "$SHR/stacks/webby/data/f.txt" && pass "web data copied" || fail "web data missing"
test -f "$SHR/stacks/webby/docker-compose.yml.prev" && pass "web .prev kept" || fail "no .prev"
grep -q "$SHR/stacks/webby/data:/data" "$SHR/stacks/webby/docker-compose.yml" && pass "web compose rewritten" || fail "web compose: $(cat "$SHR/stacks/webby/docker-compose.yml")"
grep -q "$OPT/webby/data" "$SHR/stacks/webby/docker-compose.yml.prev" && pass ".prev is the original" || fail ".prev changed"
grep -q "chown -R 1000:1000 $SHR/stacks/webby" "$DLOG" && pass "web owner set" || fail "no chown: $(cat "$DLOG")"
grep -q "chown.*recipes" "$DLOG" && fail "recipe was chowned" || pass "recipe not chowned"
test -e "$ST/webby" && pass "web app runs again" || fail "web app is down"
ls -d "$OPT"/webby.moved-* >/dev/null 2>&1 && pass "web old folder renamed" || fail "no webby.moved"
# recipe with .env and an override file
grep -q "$SHR/recipes/reci/config:/config" "$SHR/recipes/reci/docker-compose.yml" && pass "recipe compose rewritten" || fail "recipe compose"
grep -q "DIR=$SHR/recipes/reci/config" "$SHR/recipes/reci/.env" && pass ".env rewritten" || fail ".env: $(cat "$SHR/recipes/reci/.env")"
grep -q "$SHR/recipes/reci/extra" "$SHR/recipes/reci/docker-compose.override.yml" && pass "override file rewritten" || fail "override file"
test -f "$SHR/recipes/reci/.env.prev" && test -f "$SHR/recipes/reci/docker-compose.override.yml.prev" && pass ".prev of .env and override kept" || fail "missing .prev"
grep -q "$SHR/recipes/reci/config" "$HS_STATE_DIR/backup-dump/docker" && pass "backup dump list rewritten" || fail "dump: $(cat "$HS_STATE_DIR/backup-dump/docker")"
ls -d "$OPT"/reci.moved-* >/dev/null 2>&1 && pass "recipe old folder renamed" || fail "no reci.moved"
# exact path segment: rad does not touch rad2
grep -q "$SHR/recipes/rad2/data:/data" "$SHR/recipes/rad2/docker-compose.yml" && pass "rad2 got its own path" || fail "rad2 compose: $(cat "$SHR/recipes/rad2/docker-compose.yml")"
grep -q "$SHR/recipes/rad/data:/data" "$SHR/recipes/rad/docker-compose.yml" && pass "rad got its own path" || fail "rad compose"
test -e "$SHR/recipes/rad2.partial" && fail "a half copy was left" || pass "a leftover .partial is removed"
# a link to another app's folder: not moved
test -d "$OPT/linky" && test ! -e "$SHR/recipes/linky" && pass "app that points into another folder stays" || fail "linky moved"
case "$out" in *"linky still points into"*"docker-compose.yml:"*) pass "report names file and line" ;; *) fail "linky report: $out" ;; esac
case "$out" in *"rad/downloads"*) fail "report leaks the path text" ;; *) pass "report has no file content" ;; esac
test -e "$ST/linky" && pass "linky runs as before" || fail "linky is down"
# stopped app: moved, left stopped
test -f "$SHR/recipes/quiet/docker-compose.yml" && pass "stopped app moved" || fail "quiet not moved"
test -e "$ST/quiet" && fail "stopped app was started" || pass "stopped app stays stopped"
grep -q "up -d in $SHR/recipes/quiet" "$DLOG" && fail "up ran for a stopped app" || pass "no up for a stopped app"
# a failing up: back to /opt/apps, running as before
test -d "$OPT/bad" && pass "failed app stays in /opt/apps" || fail "bad folder gone"
ls -d "$OPT"/bad.moved-* >/dev/null 2>&1 && fail "failed app was renamed" || pass "failed app not renamed"
test -e "$SHR/recipes/bad" && fail "failed copy left at the target" || pass "failed copy set aside"
ls -d "$SHR"/recipes/bad.failed-* >/dev/null 2>&1 && pass "copy kept as .failed" || fail "no .failed copy"
test -e "$ST/bad" && pass "failed app runs again" || fail "bad is down"
# containers that do not go away: not moved
case "$out" in *"stuck could not be stopped"*) pass "stuck project reported" || true ;; *) fail "stuck report: $out" ;; esac
test -d "$OPT/stuck" && test ! -e "$SHR/recipes/stuck" && pass "stuck app not moved" || fail "stuck moved"
# the old folder can not be renamed
test -f "$SHR/recipes/nomv/docker-compose.yml" && test -d "$OPT/nomv" && pass "nomv runs from the share, old folder in place" || fail "nomv state"
case "$out" in *"nomv"*"could not be renamed"*) pass "rename failure warned" ;; *) fail "nomv report: $out" ;; esac
case "$out" in *"old folder is kept as"*nomv.moved*) fail "ok printed although the rename failed" ;; *) pass "no false ok for nomv" ;; esac
test -d "$OPT/old.moved-2020-01-01" && pass "an earlier .moved folder untouched" || fail "old.moved gone"

echo "-- an interrupted run puts the app back"
fresh
mk slow yes "volumes: [$OPT/slow/data:/data]"; mkdir -p "$OPT/slow/data"
$D --yes --confirm docker >"$WORK/slow.out" 2>&1 &
pid=$!
for _ in $(seq 1 50); do [ -e "$SLOWMARK" ] && break; sleep 0.2; done
kill -TERM "$pid" 2>/dev/null
wait "$pid" 2>/dev/null; rc=$?
check_eq "interrupted run fails" 1 "$rc"
test -d "$OPT/slow" && test ! -e "$SHR/recipes/slow" && pass "app is still in /opt/apps, no target" || fail "slow state"
test -e "$ST/slow" && pass "app runs again" || fail "slow is down: $(cat "$DLOG")"
ls -d "$OPT"/slow.moved-* >/dev/null 2>&1 && fail "slow was renamed" || pass "slow not renamed"
$D --yes --confirm docker >/dev/null 2>&1; rc=$?
check_eq "a second run finishes it" 0 "$rc"
test -f "$SHR/recipes/slow/docker-compose.yml" && test ! -e "$SHR/recipes/slow.partial" && pass "second run moved it, no .partial" || fail "slow second run"

echo "-- --finish"
mkapps
$D --yes --confirm docker >/dev/null 2>&1
before=$(snap)
out=$($D --finish --dry-run 2>&1); rc=$?
check_eq "finish dry run exit 0" 0 "$rc"
check_eq "finish dry run changes nothing" "$before" "$(snap)"
out=$($D --finish --yes 2>&1); rc=$?
check_eq "finish needs --confirm" 1 "$rc"
out=$($D --finish --yes --confirm docker 2>&1); rc=$?
check_eq "finish exit 0" 0 "$rc"
ls -d "$OPT"/*.moved-* >/dev/null 2>&1 && fail "moved folders left" || pass "moved folders removed"
test -d "$OPT/bad" && test -f "$SHR/stacks/webby/data/f.txt" && pass "live folders kept" || fail "finish removed too much"

echo "-- the web route (docker-setup.sh)"
fresh
mk solo yes "volumes: [$OPT/solo/data:/data]"
S="bash $SCRIPTS/docker-setup.sh"
out=$($S plan move-apps 2>&1); rc=$?
check_eq "plan exit 0" 0 "$rc"
echo "$out" | grep -qx $'status\tok' && pass "plan status ok" || fail "plan: $out"
echo "$out" | grep -q $'^step\t1\. solo to .*recipes/solo' && pass "plan has a step per app with the size" || fail "plan steps: $out"
echo "$out" | grep -q $'^note\tSize to copy' && echo "$out" | grep -q $'^note\tFree on the SSD pool' && pass "plan has size and free space" || fail "plan notes: $out"
echo "$out" | grep -qx $'long\tyes' && pass "plan is long" || fail "plan long: $out"
test -d "$OPT/solo" && test ! -e "$SHR/recipes/solo" && pass "plan changed nothing" || fail "plan changed something"
out=$($S start move-apps 2>&1); rc=$?
check_eq "start exit 0" 0 "$rc"
echo "$out" | grep -qx $'status\tstarted' && pass "start status started" || fail "start: $out"
test -f "$SHR/recipes/solo/docker-compose.yml" && pass "start moved the app" || fail "start did not move"
: > "$NOMOUNT"
out=$($S plan move-apps 2>&1); rc=$?
check_eq "plan refused when not mounted" 1 "$rc"
echo "$out" | grep -qx $'status\trefused' && pass "refused status" || fail "refused: $out"

finish
