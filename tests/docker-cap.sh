#!/usr/bin/env bash
# The capability docker: hs docker enable/disable/status/list (scripts/docker.sh) with a fake incus. Needs jq, no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1
BIN=$WORK/bin; mkdir -p "$BIN"
export LOG=$WORK/incus.log MLOG=$WORK/manage.log BLOG=$WORK/backup.log
export STATE=$WORK/ct-state OWNERF=$WORK/ct-owner PSFAIL=$WORK/ps-fail LOCKFAIL=$WORK/lock-fail
: > "$LOG"; : > "$MLOG"; : > "$BLOG"
export HS_SETTINGS_DIR=$WORK/settings HS_STATE_DIR=$WORK/state HS_CAPABILITIES_FILE=$WORK/caps HS_DOCKER_NO_JOB=1
mkdir -p "$HS_SETTINGS_DIR" "$HS_STATE_DIR"; : > "$HS_CAPABILITIES_FILE"

if ! command -v jq >/dev/null 2>&1; then skip "jq is not installed: docker capability tests not run"; finish; exit $?; fi

# STATE: the file exists when the container docker exists; OWNERF holds the managed_by value
cat > "$BIN/incus" <<'FAKE'
#!/usr/bin/env bash
echo "incus $*" >> "$LOG"
case "$1" in
  info) [ -e "$STATE" ]; exit $? ;;
  query) o=$(cat "$OWNERF" 2>/dev/null || true)
    jq -n --arg o "$o" '{type:"container",config:(if $o=="" then {} else {"user.hs.managed_by":$o} end),expanded_devices:{}}' ;;
  config) [ "$2" = set ] && [ -e "$LOCKFAIL" ] && exit 1; [ "$2" = set ] && echo "${4#user.hs.managed_by=}" > "$OWNERF" ;;
  list) case "$*" in *" s"*) echo RUNNING ;; *) echo "10.10.95.50 (eth0)" ;; esac ;;
  exec) shift 3
    if [ "$1" = docker ] && [ "$2" = ps ]; then
      [ ! -e "$PSFAIL" ] || exit 1
      printf 'arr\trunning\t0.0.0.0:8989->8989/tcp, :::7878->7878/tcp\n'
      printf 'arr\trunning\t0.0.0.0:8989->8989/tcp\n'
      printf 'notes\texited\t\n'
      printf 'arcane\trunning\t0.0.0.0:80->3552/tcp\n'
      printf '\trunning\t\n'
    else cat >/dev/null 2>&1 </dev/null || true; fi ;;
esac
exit 0
FAKE
cat > "$BIN/manage" <<'FAKE'
#!/usr/bin/env bash
echo "manage-ct $* OWNER=${HS_OWNER:-}" >> "$MLOG"
case "$*" in *--create*) : > "$STATE" ;; *--delete*) rm -f "$STATE" "$OWNERF" ;; esac
exit 0
FAKE
cat > "$BIN/backup" <<'FAKE'
#!/usr/bin/env bash
echo "backup $* OWNER=${HS_OWNER:-}" >> "$BLOG"
exit 0
FAKE
chmod +x "$BIN/incus" "$BIN/manage" "$BIN/backup"
export PATH="$BIN:$PATH" HS_DOCKER_MANAGE_CT=$BIN/manage HS_DOCKER_BACKUP=$BIN/backup
D="bash $SCRIPTS/docker.sh"
reset() { rm -f "$STATE" "$OWNERF" "$PSFAIL" "$LOCKFAIL" "$HS_SETTINGS_DIR"/*; : > "$LOG"; : > "$MLOG"; : > "$BLOG"; }
changes() { grep -cE 'incus (config set|exec)|manage-ct' "$LOG" "$MLOG" "$BLOG" | awk -F: '{s+=$2} END{print s+0}'; }
cap_on() { bash -c ". $SCRIPTS/lib/capability.sh; capability_on docker"; }

echo "-- status off"
reset
out=$($D --status); rc=$?
check_eq "exit 0" 0 "$rc"
echo "$out" | grep -qx $'state\toff' && pass "state off" || fail "state: $out"
echo "$out" | grep -qx $'instance\t-' && pass "instance -" || fail "instance: $out"

echo "-- enable --dry-run"
reset
out=$($D enable --dry-run --yes 2>&1) || true
echo "$out" | grep -q "Create the container docker (4096 MiB, 4 CPUs" && pass "plan shown" || fail "plan: $out"
echo "$out" | grep -q "web interface of hobnix" && pass "default manager is webui" || fail "webui note: $out"
check_eq "nothing changed" 0 "$(changes)"

echo "-- enable without a terminal and without --yes"
reset
rc=0; $D enable </dev/null >/dev/null 2>&1 || rc=$?
check_eq "refused" 1 "$rc"
check_eq "nothing changed" 0 "$(changes)"

echo "-- enable --manager portainer --size s"
reset
rc=0; $D enable --yes --manager portainer --size s </dev/null >/dev/null 2>&1 || rc=$?
check_eq "exit 0" 0 "$rc"
grep -qF "manage-ct --create docker --docker --ram 2048 --cpu 2 OWNER=docker" "$MLOG" && pass "create with the owner's pass" || fail "create: $(cat "$MLOG")"
grep -qF "incus config set docker user.hs.managed_by=docker" "$LOG" && pass "locked" || fail "lock not set"
grep -qF "backup ct docker on" "$BLOG" && pass "in the backup" || fail "backup: $(cat "$BLOG")"
grep -qF "tee /opt/portainer/docker-compose.yml" "$LOG" && pass "manager compose written" || fail "compose not written"
check_eq "dockerManager" portainer "$(cat "$HS_SETTINGS_DIR/dockerManager" 2>/dev/null || true)"
cap_on && pass "capability on" || fail "capability not on"

echo "-- enable with the default manager (webui)"
reset
rc=0; $D enable --yes </dev/null >/dev/null 2>&1 || rc=$?
check_eq "exit 0" 0 "$rc"
check_eq "dockerManager" webui "$(cat "$HS_SETTINGS_DIR/dockerManager" 2>/dev/null || true)"
! grep -q "docker compose up" "$LOG" && pass "no manager installed" || fail "a manager was started"
cap_on && pass "capability on" || fail "capability not on"

echo "-- the lock fails after the create"
reset; : > "$LOCKFAIL"
rc=0; $D enable --yes </dev/null >/dev/null 2>&1 || rc=$?
check_eq "exit 1" 1 "$rc"
grep -qF "manage-ct docker --delete --yes OWNER=docker" "$MLOG" && pass "container removed again" || fail "rollback: $(cat "$MLOG")"
[ ! -e "$HS_SETTINGS_DIR/dockerManager" ] && pass "setting not written" || fail "setting written"

echo "-- a job that cannot start"
reset
printf '#!/usr/bin/env bash
exit 1
' > "$BIN/systemd-run"; chmod +x "$BIN/systemd-run"
rc=0; out=$(env -u HS_DOCKER_NO_JOB $D enable --yes --job </dev/null 2>&1) || rc=$?
check_eq "exit 1" 1 "$rc"
echo "$out" | grep -q "Started in the background" && fail "claimed to have started: $out" || pass "no false success"
rm -f "$BIN/systemd-run"

echo "-- enable when docker exists and is not ours"
reset; : > "$STATE"
rc=0; $D enable --yes </dev/null >/dev/null 2>&1 || rc=$?
check_eq "refused" 1 "$rc"
check_eq "nothing created" 0 "$(grep -c -- '--create' "$MLOG" || true)"

echo "-- enable --manager foo"
reset
rc=0; $D enable --yes --manager foo </dev/null >/dev/null 2>&1 || rc=$?
check_eq "refused" 1 "$rc"

echo "-- list"
reset; : > "$STATE"; echo docker > "$OWNERF"; echo arcane > "$HS_SETTINGS_DIR/dockerManager"
list=$($D --list)
check_eq "2 rows" 2 "$(printf '%s\n' "$list" | grep -c .)"
check_eq "arr row" $'arr\tdocker\tarr\trunning\t7878,8989' "$(printf '%s\n' "$list" | sed -n 1p)"
check_eq "notes row" $'notes\tdocker\tnotes\texited\t-' "$(printf '%s\n' "$list" | sed -n 2p)"
check_eq "5 fields" "5 5" "$(printf '%s\n' "$list" | awk -F'\t' '{print NF}' | tr '\n' ' ' | sed 's/ $//')"
reset
rc=0; out=$($D --list) || rc=$?
check_eq "off: exit 0" 0 "$rc"; check_eq "off: no output" "" "$out"
reset; : > "$STATE"; echo docker > "$OWNERF"; : > "$PSFAIL"
rc=0; out=$($D --list) || rc=$?
check_eq "exec fails: exit 0" 0 "$rc"; check_eq "exec fails: no output" "" "$out"

echo "-- disable"
reset; : > "$STATE"; echo docker > "$OWNERF"; echo webui > "$HS_SETTINGS_DIR/dockerManager"
rc=0; $D disable --yes </dev/null >/dev/null 2>&1 || rc=$?
check_eq "without --confirm docker refused" 1 "$rc"
! grep -q -- '--delete' "$MLOG" && pass "no delete" || fail "deleted without the name"
rc=0; $D disable --yes --confirm docker --no-backup </dev/null >/dev/null 2>&1 || rc=$?
check_eq "exit 0" 0 "$rc"
grep -qF "manage-ct docker --delete --yes OWNER=docker" "$MLOG" && pass "delete with the owner's pass" || fail "delete: $(cat "$MLOG")"
[ ! -e "$HS_SETTINGS_DIR/dockerManager" ] && pass "dockerManager unset" || fail "dockerManager still set"
! cap_on && pass "capability off" || fail "capability still on"
check_eq "no backup with --no-backup" 0 "$(grep -c . "$BLOG" || true)"

echo "-- disable backs up first"
reset; : > "$STATE"; echo docker > "$OWNERF"; echo webui > "$HS_SETTINGS_DIR/dockerManager"
rc=0; $D disable --yes --confirm docker </dev/null >/dev/null 2>&1 || rc=$?
check_eq "exit 0" 0 "$rc"
grep -qF "backup now" "$BLOG" && pass "backup now ran" || fail "no backup"
grep -qF -- '--delete' "$MLOG" && pass "then deleted" || fail "not deleted"

finish
