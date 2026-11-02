#!/usr/bin/env bash
# scripts/docker-app-change.sh: plan/start for docker apps. Fake incus, no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1
BIN=$WORK/bin; mkdir -p "$BIN"
export STATE=$WORK/ct-state OWNERF=$WORK/ct-owner SETTINGS=$WORK/settings CAPS=$WORK/caps SLOG=$WORK/systemd.log
: > "$STATE"; : > "$OWNERF"; : > "$CAPS"; mkdir -p "$SETTINGS"
export HS_SETTINGS_DIR=$SETTINGS HS_STATE_DIR=$WORK/state HS_CAPABILITIES_FILE=$CAPS
export LOG=$WORK/incus.log SLOG=$WORK/systemd.log
: > "$LOG"; : > "$SLOG"

# Fake incus for the docker container and the commands inside it
cat > "$BIN/incus" <<'FAKE'
#!/usr/bin/env bash
echo "incus $*" >> "$LOG"
case "$1" in
  info) [ -e "$STATE" ]; exit $? ;;
  query) o=$(cat "$OWNERF" 2>/dev/null || true)
    jq -n --arg o "$o" '{type:"container",config:(if $o=="" then {} else {"user.hs.managed_by":$o} end),expanded_devices:{}}' ;;
  list) case "$*" in *" s"*) echo RUNNING ;; *) printf '"10.10.95.50 (eth0)"\n' ;; esac ;;
  exec) shift 3; [ "$1" = -- ] && shift
    if [ "$1" = docker ] && [ "$2" = ps ]; then
      case "$*" in
        *-aq*) printf 'c1\n' ;;
        *) printf 'arr\trunning\t8989\nnotes\texited\t-\narcane\trunning\t80\n' ;;
      esac
    elif [ "$1" = docker ] && [ "$2" = inspect ]; then
      printf '/opt/apps/arr\n'
    elif [ "$1" = docker ] && [ "$2" = compose ]; then
      :  # compose actions succeed silently
    elif [ "$1" = sh ] && [ "$2" = -c ]; then
      cmd=$3
      case "$cmd" in
        *'docker inspect --format'*) printf '/opt/apps/arr\n' ;;
        *'docker compose -p'*) : ;;
        *'[ -d'*) : ;;
      esac
    else cat >/dev/null 2>&1 </dev/null || true; fi ;;
esac
exit 0
FAKE

# Fake systemd-run: parse the unit name, do not run the command, succeed
cat > "$BIN/systemd-run" <<'FAKE'
#!/usr/bin/env bash
unit=""; next=0
for a; do
  if [ "$next" = 1 ]; then unit="$a"; next=0; continue; fi
  case "$a" in --unit=*) unit="${a#--unit=}" ;; --unit) next=1 ;; esac
done
[ -n "$unit" ] && echo "systemd-run $unit" >> "$SLOG"
exit 0
FAKE

chmod +x "$BIN/incus" "$BIN/systemd-run"
export PATH="$BIN:$PATH"
unset HS_OWNER HS_DOCKER_NO_JOB
D="bash $SCRIPTS/docker-app-change.sh"
T=$'\t'

reset() {
  rm -f "$STATE" "$OWNERF" "$SETTINGS"/* "$SLOG"
  : > "$CAPS"; mkdir -p "$SETTINGS"
}

on() {
  : > "$STATE"; echo docker > "$OWNERF"; echo docker > "$CAPS"
  echo "${1:-webui}" > "$SETTINGS/dockerManager"
}

echo "-- plan allows all actions"
on webui
for a in start stop restart; do
  rc=0; out=$($D plan arr "$a" </dev/null 2>&1) || rc=$?
  check_eq "plan $a exit 0" 0 "$rc"
  echo "$out" | grep -qx "status${T}ok" && pass "plan $a status ok" || fail "plan $a status: $out"
  echo "$out" | grep -qx "long${T}no" && pass "plan $a long no" || fail "plan $a long: $out"
done
rc=0; out=$($D plan arr pull </dev/null 2>&1) || rc=$?
check_eq "plan pull exit 0" 0 "$rc"
echo "$out" | grep -qx "status${T}ok" && pass "plan pull status ok" || fail "plan pull status: $out"
echo "$out" | grep -qx "long${T}yes" && pass "plan pull long yes" || fail "plan pull long: $out"

echo "-- start/stop/restart run directly and use the right argv"
on webui
for a in start stop restart; do
  rc=0; out=$($D start arr "$a" </dev/null 2>&1) || rc=$?
  check_eq "start $a exit 0" 0 "$rc"
  echo "$out" | grep -qx "status${T}done" && pass "start $a done" || fail "start $a: $out"
  grep -qF "sh arr $a" "$LOG" && pass "start $a argv" || fail "start $a argv: $(cat "$LOG")"
done

echo "-- normal pull runs as a job"
on webui
rc=0; out=$($D start arr pull </dev/null 2>&1) || rc=$?
check_eq "start pull exit 0" 0 "$rc"
echo "$out" | grep -qx "status${T}started" && pass "start pull status started" || fail "start pull status: $out"
echo "$out" | grep -qE "^unit${T}hs-job-docker-app-pull-arr" && pass "start pull unit" || fail "start pull unit: $out"

echo "-- HS_DOCKER_NO_JOB pulls inline"
on webui
export HS_DOCKER_NO_JOB=1
rc=0; out=$($D start arr pull </dev/null 2>&1) || rc=$?
unset HS_DOCKER_NO_JOB
check_eq "inline pull exit 0" 0 "$rc"
echo "$out" | grep -qx "status${T}done" && pass "inline pull done" || fail "inline pull: $out"
grep -qF 'sh arr /opt/apps/arr pull' "$LOG" && pass "inline pull command" || fail "inline pull command: $(cat "$LOG")"

echo "-- delete keeps /opt/apps/<app> unless --delete-data"
cat > "$BIN/docker.sh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  --status) printf 'state	on
running	yes
' ;;
  --list) printf 'web1	docker	web1	running	-
' ;;
  --app) printf '{"rev":"0123456789abcdef","managed":"web"}
' ;;
esac
FAKE
printf '#!/usr/bin/env bash
exit 0
' > "$BIN/ct-change.sh"
chmod +x "$BIN/docker.sh" "$BIN/ct-change.sh"
export HS_DOCKER_SH=$BIN/docker.sh HS_CT_CHANGE=$BIN/ct-change.sh
on webui
out=$($D plan web1 delete </dev/null 2>&1) || true
echo "$out" | grep -qx "confirm_name${T}web1" && pass "plan delete asks for the name" || fail "plan delete: $out"
echo "$out" | grep -q "^note${T}/opt/apps/web1 is kept" && pass "plan delete keep: says the folder stays" || fail "plan keep: $out"
echo "$out" | grep -q "^danger" && fail "plan keep has a danger line" || pass "plan keep: no danger line"
out=$($D plan web1 delete --delete-data </dev/null 2>&1) || true
echo "$out" | grep -q "^danger${T}Delete the app" && pass "plan delete-data: danger line" || fail "plan data: $out"
rc=0; out=$($D plan web1 delete --force </dev/null 2>&1) || rc=$?
check_eq "plan delete --force refused" 1 "$rc"
export HS_DOCKER_NO_JOB=1
: > "$LOG"
rc=0; out=$($D start web1 delete --confirm web1 </dev/null 2>&1) || rc=$?
check_eq "delete keep exit 0" 0 "$rc"
grep -q 'down --remove-orphans' "$LOG" && pass "keep: compose down --remove-orphans" || fail "keep: no down: $(cat "$LOG")"
grep -q 'rm -rf -- "/opt/apps' "$LOG" && fail "keep: the folder was removed" || pass "keep: the folder stays"
: > "$LOG"
rc=0; out=$($D start web1 delete --confirm web1 --delete-data </dev/null 2>&1) || rc=$?
check_eq "delete-data exit 0" 0 "$rc"
grep -q 'rm -rf -- "/opt/apps' "$LOG" && pass "delete-data: the folder is removed" || fail "data: not removed: $(cat "$LOG")"
rc=0; out=$($D start web1 delete --delete-data </dev/null 2>&1) || rc=$?
check_eq "delete without the typed name refused" 1 "$rc"

echo "-- an app with a folder and no container (a delete that kept the data) starts with up -d"
cat > "$BIN/docker.sh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  --status) printf 'state\ton\nrunning\tyes\n' ;;
  --list) printf 'web1\tdocker\tweb1\tstopped\t-\n' ;;
  --app) printf '{"rev":"0123456789abcdef","managed":"web"}\n' ;;
esac
FAKE
: > "$LOG"
rc=0; out=$($D start web1 start </dev/null 2>&1) || rc=$?
check_eq "start of a stopped app exit 0" 0 "$rc"
echo "$out" | grep -qx "status${T}done" && pass "start of a stopped app done" || fail "start stopped: $out"
grep -q 'sh web1 /opt/apps/web1 up -d' "$LOG" && pass "start of a stopped app runs up -d in its folder" || fail "no up -d: $(cat "$LOG")"
rc=0; out=$($D plan web1 delete --delete-data </dev/null 2>&1) || rc=$?
check_eq "delete-data plan of a stopped app" 0 "$rc"
unset HS_DOCKER_NO_JOB HS_DOCKER_SH HS_CT_CHANGE

echo "-- refused shapes"
on webui
bad=(
  "plan BadApp start"
  "plan app_with_underscore stop"
  "plan tooooooolongnameeeeeeeeeeeeeeeeeeeeeeeeeeeee start"
  "plan arr deploy"
  "plan arr start extra"
  "start BadApp start"
)
for b in "${bad[@]}"; do
  rc=0; out=$($D $b </dev/null 2>&1) || rc=$?
  check_eq "refused: $b" 1 "$rc"
  echo "$out" | grep -qx "status${T}refused" && pass "refused status $b" || fail "refused status $b: $out"
done

echo "-- docker off, unknown app, manager refused"
reset
rc=0; out=$($D plan arr start </dev/null 2>&1) || rc=$?
check_eq "off refused" 1 "$rc"
echo "$out" | grep -qx "status${T}refused" && pass "off status refused" || fail "off: $out"

on webui
rc=0; out=$($D plan missing start </dev/null 2>&1) || rc=$?
check_eq "unknown app refused" 1 "$rc"
echo "$out" | grep -qx "status${T}refused" && pass "unknown app status refused" || fail "unknown app: $out"

on arcane
rc=0; out=$($D plan arcane start </dev/null 2>&1) || rc=$?
check_eq "manager refused" 1 "$rc"
echo "$out" | grep -qx "status${T}refused" && pass "manager status refused" || fail "manager: $out"

echo "-- no HS_OWNER is needed"
grep -qE 'OWNER=' "$LOG" && fail "HS_OWNER leaked to incus" || pass "no HS_OWNER in incus calls"

finish
