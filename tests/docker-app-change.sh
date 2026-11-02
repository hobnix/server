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
    elif [ "$1" = bash ] && [ "$2" = -c ] && [ -s "${PREP_ERR:-/nonexistent}" ]; then
      cat >/dev/null; cat "$PREP_ERR" >&2; exit 1      # the test of the editor: `compose config` fails with these lines
    elif [ "$1" = sh ] && [ "$2" = -c ]; then
      cmd=$3
      case "$cmd" in
        *'docker inspect --format'*) printf '/opt/apps/arr\n' ;;
        *'config --images'*) printf 'ghcr.io/acme/app:1\n' ;;
        *'config --format json'*) cat "${CFGJSON:-/nonexistent}" 2>/dev/null ;;
        *'[ -e "$p" ]'*) printf '%s\n' "${@:5}" | grep '^/missing' || true ;;
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

echo "-- app-save with an env text: line check and one shape per document"
unset HS_DOCKER_NO_JOB; export HS_DOCKER_SH=$BIN/docker.sh; on webui
doc_plan() { printf "$1" | $D plan web1 app-save --rev 0123456789abcdef 2>&1; }
export CFGJSON=$WORK/cfg.json; echo '{"services":{"web":{"image":"x"}}}' > "$CFGJSON"
out=$(doc_plan 'services: {}\0*A=1\nbroken line\n\0') || true
echo "$out" | grep -qx "status${T}refused" && pass "env text: a bad line is refused" || fail "env line status: $out"
echo "$out" | grep -qx "reason${T}The test found 1 problem." && pass "env text: the reason counts the problems" || fail "env line reason: $out"
echo "$out" | grep -qx "finding${T}error${T}env:2${T}Line 2 of the env file is not NAME=value." && pass "env text: a bad line is a finding with its number" || fail "env line: $out"
out=$(doc_plan 'services: {}\0*A=1\0+B=2\0') || true
echo "$out" | grep -qx "status${T}refused" && pass "env text then a set record is refused" || fail "env then set: $out"
out=$(doc_plan 'services: {}\0+B=2\0*A=1\0') || true
echo "$out" | grep -qx "status${T}refused" && pass "a set record then an env text is refused" || fail "set then env: $out"
echo "$out" | grep -q 'broken' && fail "a line of the env text was printed" || pass "plan output has no env text"

echo "-- the Test: every problem is a finding at its place"
printf 'yaml: line 3: mapping values are not allowed in this context\nservices.web.ports must be a list\nsomething else broke\n' > "$WORK/prep.err"
export PREP_ERR=$WORK/prep.err
out=$(doc_plan 'services: {}\0*A=1\nbad one\nbad two\n\0') || true
unset PREP_ERR
echo "$out" | grep -qx "reason${T}The test found 5 problems." && pass "test: five problems counted" || fail "test count: $out"
echo "$out" | grep -qx "finding${T}error${T}compose:3${T}yaml: line 3: mapping values are not allowed in this context" && pass "test: a compose error with a line maps to compose:<line>" || fail "test line: $out"
echo "$out" | grep -qx "finding${T}error${T}compose:services.web.ports${T}services.web.ports must be a list" && pass "test: a service path maps to compose:<path>" || fail "test path: $out"
echo "$out" | grep -qx "finding${T}error${T}-${T}something else broke" && pass "test: an unplaced error lands on -" || fail "test unplaced: $out"
echo "$out" | grep -qx "finding${T}error${T}env:2${T}Line 2 of the env file is not NAME=value." && echo "$out" | grep -qx "finding${T}error${T}env:3${T}Line 3 of the env file is not NAME=value." && pass "test: two bad env lines are two findings" || fail "test env: $out"
cat > "$CFGJSON" <<'JSON'
{"services":{"web":{"image":"x","container_name":"clash","environment":{"DB_PASSWORD":"zz"},"volumes":[{"type":"bind","source":"/missing/data","target":"/d"},{"type":"bind","source":"/opt/apps/web1/conf","target":"/c"}]}}}
JSON
cat > "$BIN/docker.sh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  --status) printf 'state\ton\nrunning\tyes\n' ;;
  --list) printf 'web1\tdocker\tweb1\trunning\t-\n' ;;
  --app) printf '{"rev":"0123456789abcdef","managed":"web"}\n' ;;
  --containers) printf 'clash\tother\trunning\nweb1-web-1\tweb1\trunning\n' ;;
esac
FAKE
out=$(doc_plan 'services: {}\0') || true
echo "$out" | grep -qx "finding${T}error${T}compose:services.web.container_name${T}The container name clash is used by other." && pass "test: a container_name used by another project is an error at its path" || fail "test cname: $out"
echo "$out" | grep -qx "finding${T}warn${T}compose:services.web.volumes${T}/missing/data does not exist: Docker would make an empty folder on the container disk." && pass "test: a missing bind source is a warning" || fail "test bind: $out"
echo "$out" | grep -q "/opt/apps/web1/conf" && fail "the app's own folder was reported" || pass "test: the app's own folder is not reported"
echo "$out" | grep -qx "finding${T}warn${T}compose:services.web.environment${T}Service web environment key DB_PASSWORD holds a literal value; move it to the env file." && pass "test: a literal secret is a warning at its path" || fail "test warn: $out"
echo "$out" | grep -q 'zz' && fail "a value was printed" || pass "test: no value in the output"
# the name taken between Test and Apply: the start checks it again
out=$(printf 'services: {}\0' | $D start web1 app-save --rev 0123456789abcdef 2>&1) || true
echo "$out" | grep -qx "reason${T}The container name clash is used by other." && pass "start: a container_name taken since the Test is refused" || fail "start cname: $out"
echo '{"services":{"web":{"image":"x","volumes":[{"type":"bind","source":"/missing/data","target":"/d"}]}}}' > "$CFGJSON"
out=$(doc_plan 'services: {}\0') || true
echo "$out" | grep -qx "status${T}ok" && echo "$out" | grep -q "^finding${T}warn${T}" && echo "$out" | grep -qx "step${T}Recreate the app" && pass "test: warnings alone keep the plan ok" || fail "test warn plan: $out"
out=$(printf 'services: {}\0' | $D plan web1 app-write --rev 0123456789abcdef 2>&1) || true
echo "$out" | grep -qx "step${T}Save the files (the app is not restarted)" && pass "app-write: the plan only saves the files" || fail "app-write plan: $out"
echo "$out" | grep -q "Recreate" && fail "app-write plans a recreate" || pass "app-write: no recreate step"
# a closed vault is one finding next to the others (app-save), and no problem for app-write
mkdir -p "$WORK/state" "$WORK/vault"
export HS_VAULT_DIR=$WORK/vault
printf 'ghcr.io\tme\n' > "$WORK/state/docker-registries.tsv"
echo uuid > "$WORK/state/vault-uuid"
ln -sf "$WORK/vault/secrets/docker-registry-ghcr.io" "$WORK/state/docker-registry-ghcr.io"
echo '{"services":{"web":{"image":"ghcr.io/acme/app:1","ports":["8080:80"],"volumes":[{"type":"bind","source":"/missing/data","target":"/d"}]}}}' > "$CFGJSON"
out=$(doc_plan 'services: {}\0') || true
echo "$out" | grep -qx "finding${T}error${T}-${T}The vault is closed: the token for ghcr.io is in it." && pass "test: a closed vault is a finding" || fail "test vault: $out"
echo "$out" | grep -q "^finding${T}warn${T}compose:services.web.volumes" && pass "test: the other findings stay next to the vault one" || fail "test vault others: $out"
echo "$out" | grep -qx "fix${T}hs vault open" && pass "test: the vault refusal keeps its fix" || fail "test vault fix: $out"
out=$(printf 'services: {}\0' | $D plan web1 app-write --rev 0123456789abcdef 2>&1) || true
echo "$out" | grep -qx "status${T}ok" && pass "app-write: a closed vault is no problem" || fail "app-write vault: $out"
rm -f "$WORK/state/docker-registries.tsv" "$WORK/state/vault-uuid" "$WORK/state/docker-registry-ghcr.io"
unset HS_VAULT_DIR
echo '{"services":{"web":{"image":"x"}}}' > "$CFGJSON"

echo "-- env_diff: names only, also for an empty or a missing old .env"
mkdir -p "$WORK/apps/e1" "$WORK/apps/e2" "$WORK/apps/e3" "$WORK/etmp"
printf '#!/bin/sh\nshift 3\nexec "$@"\n' > "$WORK/localexec"; chmod +x "$WORK/localexec"
eval "$(sed -n '/^env_diff() {/,/^}/p' "$SCRIPTS/docker-app-change.sh" | sed "s#/opt/apps#$WORK/apps#g")"
export HS_INCUS=$WORK/localexec CT=x
printf 'A=1\nSECRETX=old\nKEEP=same\n' > "$WORK/apps/e1/.env"
printf 'A=1\nKEEP=same\nNEWV=n\nSECRETX=new\n' > "$WORK/etmp/.env"
check_eq "env_diff: added and changed, names only" $'added\tNEWV\nchanged\tSECRETX' "$(env_diff e1 "$WORK/etmp")"
: > "$WORK/apps/e2/.env"
check_eq "env_diff: an empty old .env: everything is added" $'added\tA\nadded\tKEEP\nadded\tNEWV\nadded\tSECRETX' "$(env_diff e2 "$WORK/etmp")"
check_eq "env_diff: no old .env: everything is added" $'added\tA\nadded\tKEEP\nadded\tNEWV\nadded\tSECRETX' "$(env_diff e3 "$WORK/etmp")"
printf 'A=1\n' > "$WORK/etmp/.env"
check_eq "env_diff: removed" $'removed\tKEEP\nremoved\tSECRETX' "$(env_diff e1 "$WORK/etmp")"
unset HS_INCUS CT

finish
