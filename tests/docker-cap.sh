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
  config) [ "$2" = get ] && [ "$4" = raw.idmap ] && { cat "$STATE.idmap" 2>/dev/null; exit 0; }
    [ "$2" = device ] && [ "$3" = get ] && { [ -e "$STATE.dev" ]; exit $?; }
    [ "$2" = set ] && [ -e "$LOCKFAIL" ] && exit 1; [ "$2" = set ] && echo "${4#user.hs.managed_by=}" > "$OWNERF" ;;
  list) case "$*" in *" s"*) echo RUNNING ;; *) printf '"172.17.0.1 (docker0)\n10.10.95.50 (eth0)"\n' ;; esac ;;
  exec) shift 3; [ "$1" = -- ] && shift
    if [ "$1" = docker ] && [ "$2" = ps ]; then
      [ ! -e "$PSFAIL" ] || exit 1
      case "$*" in *'{{.Names}}'*) printf 'arr-app-1\tarr\trunning\nsolo\t\texited\n'; exit 0 ;; esac
      printf 'arr\trunning\t0.0.0.0:8989->8989/tcp, :::7878->7878/tcp\n'
      printf 'arr\trunning\t0.0.0.0:8989->8989/tcp\n'
      printf 'notes\texited\t\n'
      printf 'arcane\trunning\t0.0.0.0:80->3552/tcp\n'
      printf '\trunning\t\n'
    elif [ "$1" = docker ] && [ "$2" = compose ]; then
      case "$*" in
        *logs*) printf '2024-01-01T00:00:00Z line one\n2024-01-01T00:00:01Z line two\n' ;;
      esac
    elif [ "$1" = sh ] && [ "$2" = -c ]; then
      cmd=$3
      case "$cmd" in
        *'docker ps -a --format'*)
          [ ! -e "$PSFAIL" ] || exit 1
          printf 'arr\trunning\t0.0.0.0:8989->8989/tcp, :::7878->7878/tcp\tlinuxserver/arr:latest\n'
          printf 'arr\trunning\t0.0.0.0:8989->8989/tcp\tlinuxserver/arr:latest\n'
          printf 'notes\texited\t-\tnginx:alpine\n'
          printf 'wiki\trunning\t0.0.0.0:3000->3000/tcp\trequarks/wiki:2\n'
          printf 'wiki\tcreated\t-\trequarks/wiki:2\n'
          printf 'arcane\trunning\t0.0.0.0:80->3552/tcp\tportainer/portainer-ce:latest\n'
          printf '\trunning\t-\tbusybox\n'
          printf '__HS_MARKER_WEBUI__\n'
          printf '/opt/apps/arr/.hs-webui\n'
          printf '/opt/apps/kept1/.hs-webui\n'
          printf '__HS_MARKER_DIR__\n'
          printf '/opt/apps/arr/\n'
          printf '/opt/apps/wiki/\n'
          printf '/opt/apps/kept1/\n'
          printf '__HS_MARKER_COMPOSE__\n'
          printf '/opt/apps/arr/docker-compose.yml\n'
          printf '/opt/apps/kept1/docker-compose.yml\n'
          printf '__HS_MARKER_STACKS__\n'
          [ ! -e "$STATE.newapps" ] || printf '/shares/apps/stacks/zeta/docker-compose.yml\n'
          printf '__HS_MARKER_RECIPES__\n'
          [ ! -e "$STATE.newapps" ] || printf '/shares/apps/recipes/pico/\n'
          printf '__HS_MARKER_RECIPECOMPOSE__\n'
          [ ! -e "$STATE.newapps" ] || printf '/shares/apps/recipes/pico/docker-compose.yml\n'
          ;;
        *'ls -d /opt/apps/*/docker-compose.yml'*)   # the folders that hold a compose file (kept1: a delete that kept the data)
          printf '/opt/apps/arr/docker-compose.yml\n/opt/apps/kept1/docker-compose.yml\n/opt/apps/arcane/docker-compose.yml\n' ;;
      esac
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
cat > "$BIN/mkshare" <<'FAKE'
#!/usr/bin/env bash
echo "create-share $*" >> "$MLOG"
exit 0
FAKE
cat > "$BIN/snaps" <<'FAKE'
#!/usr/bin/env bash
echo "snapshots-auto $*" >> "$MLOG"
exit 0
FAKE
chmod +x "$BIN/incus" "$BIN/manage" "$BIN/backup" "$BIN/mkshare" "$BIN/snaps"
export PATH="$BIN:$PATH" HS_DOCKER_MANAGE_CT=$BIN/manage HS_DOCKER_BACKUP=$BIN/backup HS_DOCKER_CREATE_SHARE=$BIN/mkshare HS_DOCKER_SNAPS=$BIN/snaps
export HS_BULK=$WORK/nobulk HS_FAST=$WORK/nofast HS_ZFS=false
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

echo "-- listed as on, but no container"
reset; echo docker > "$HS_CAPABILITIES_FILE"; echo webui > "$HS_SETTINGS_DIR/dockerManager"
out=$($D --status)
echo "$out" | grep -qx $'state\toff' && pass "state off without an owned container" || fail "state: $out"
echo "$out" | grep -qx $'owned\tno' && pass "owned no" || fail "owned: $out"
out=$($D status 2>&1)
echo "$out" | grep -q "hs docker enable" && pass "status names hs docker enable" || fail "status text: $out"
: > "$HS_CAPABILITIES_FILE"

echo "-- status on (owned)"
reset; : > "$STATE"; echo docker > "$OWNERF"; echo docker > "$HS_CAPABILITIES_FILE"; echo webui > "$HS_SETTINGS_DIR/dockerManager"
out=$($D --status)
echo "$out" | grep -qx $'state\ton' && pass "state on when owned" || fail "state: $out"
: > "$HS_CAPABILITIES_FILE"

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
grep -qF "create-share apps --fast" "$MLOG" && grep -qF "backup apps on" "$BLOG" && grep -qF "snapshots-auto apps on" "$MLOG" && pass "share apps made, in the backup, snapshots on" || fail "share apps: $(cat "$MLOG" "$BLOG")"
grep -qF "manage-ct docker --add-storage shares apps /shares/apps --as 1000:1000" "$MLOG" && pass "docker gets the share apps at /shares/apps" || fail "mount: $(cat "$MLOG")"
grep -qF "backup ct docker on" "$BLOG" && pass "in the backup" || fail "backup: $(cat "$BLOG")"
grep -qF "tee /opt/portainer/docker-compose.yml" "$LOG" && pass "manager compose written" || fail "compose not written"
check_eq "dockerManager" portainer "$(cat "$HS_SETTINGS_DIR/dockerManager" 2>/dev/null || true)"
cap_on && pass "capability on" || fail "capability not on"

echo "-- backupNewInstances false: not in the backup, a note, the plan says so"
reset; printf false > "$HS_SETTINGS_DIR/backupNewInstances"
rc=0; out=$($D enable --yes </dev/null 2>&1) || rc=$?
check_eq "exit 0" 0 "$rc"
! grep -qv '^backup apps on' "$BLOG" && pass "not in the backup" || fail "backup: $(cat "$BLOG")"
echo "$out" | grep -q "'docker' is not put into the backup (backupNewInstances is false). Later: hs backup ct docker on" && pass "note" || fail "note: $out"
reset; printf false > "$HS_SETTINGS_DIR/backupNewInstances"
out=$($D enable --dry-run 2>&1 </dev/null || true)
echo "$out" | grep -q "It is not added to the backup" && pass "plan says no backup" || fail "plan: $out"
reset
out=$($D enable --dry-run 2>&1 </dev/null || true)
echo "$out" | grep -q "and add it to the backup" && pass "plan says backup" || fail "plan: $out"
echo "-- status works with docker out of the backup"
reset; : > "$STATE"; echo docker > "$OWNERF"; printf false > "$HS_SETTINGS_DIR/backupNewInstances"
rc=0; $D --status >/dev/null 2>&1 || rc=$?
check_eq "status exit 0" 0 "$rc"
echo "-- the address is the eth0 one, not docker0"
out=$($D --status 2>/dev/null || true)
echo "$out" | grep -qx $'address	10.10.95.50' && pass "address eth0" || fail "address: $(echo "$out" | grep address)"

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

echo "-- enable on a server where Docker is on already: it gets the share apps"
reset; : > "$STATE"; echo docker > "$OWNERF"; echo docker > "$HS_CAPABILITIES_FILE"
out=$($D enable --dry-run </dev/null 2>&1) || true
echo "$out" | grep -q "Mount it in the container docker at /shares/apps" && pass "plan: the mount, with the restart warning" || fail "ensure plan: $out"
echo "$out" | grep -q "restarts" && pass "plan warns about the restart" || fail "restart warning: $out"
check_eq "dry-run changed nothing" 0 "$(grep -c 'create-share\|add-storage' "$MLOG" || true)"
rc=0; $D enable --yes </dev/null >/dev/null 2>&1 || rc=$?
check_eq "ensure exit 0" 0 "$rc"
grep -qF "create-share apps --fast" "$MLOG" && grep -qF "backup apps on" "$BLOG" && pass "ensure: share made, in the backup" || fail "ensure share: $(cat "$MLOG" "$BLOG")"
grep -qF "manage-ct docker --add-storage shares apps /shares/apps --as 1000:1000" "$MLOG" && pass "ensure: mounted" || fail "ensure mount: $(cat "$MLOG")"
check_eq "ensure created no container" 0 "$(grep -c -- '--create' "$MLOG" || true)"

echo "-- a share apps on the disks stops enable"
reset; mkdir -p "$HS_BULK/shares/apps"
rc=0; out=$($D enable --yes </dev/null 2>&1) || rc=$?
check_eq "refused" 1 "$rc"
echo "$out" | grep -q "exists on the disks" && pass "says why" || fail "bulk apps: $out"
check_eq "nothing created" 0 "$(grep -c -- '--create' "$MLOG" || true)"
: > "$STATE"; echo docker > "$OWNERF"; echo docker > "$HS_CAPABILITIES_FILE"
rc=0; $D enable --yes </dev/null >/dev/null 2>&1 || rc=$?
check_eq "refused also when Docker is on" 1 "$rc"
rm -rf "$HS_BULK"; : > "$HS_CAPABILITIES_FILE"

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
check_eq "3 rows (with the kept app)" 3 "$(printf '%s\n' "$list" | grep -c .)"
check_eq "arr row" $'arr\tdocker\tarr\trunning\t7878,8989' "$(printf '%s\n' "$list" | sed -n 1p)"
check_eq "notes row" $'notes\tdocker\tnotes\texited\t-' "$(printf '%s\n' "$list" | sed -n 3p)"
check_eq "5 fields" "5 5 5" "$(printf '%s\n' "$list" | awk -F'\t' '{print NF}' | tr '\n' ' ' | sed 's/ $//')"
reset
rc=0; out=$($D --list) || rc=$?
check_eq "off: exit 0" 0 "$rc"; check_eq "off: no output" "" "$out"
reset; : > "$STATE"; echo docker > "$OWNERF"; : > "$PSFAIL"
rc=0; out=$($D --list) || rc=$?
check_eq "exec fails: exit 0" 0 "$rc"; check_eq "exec fails: no output" "" "$out"

echo "-- apps"
reset; : > "$STATE"; echo docker > "$OWNERF"; echo arcane > "$HS_SETTINGS_DIR/dockerManager"
apps=$($D --apps)
check_eq "4 rows" 4 "$(printf '%s\n' "$apps" | grep -c .)"
check_eq "10 fields" "10 10 10 10" "$(printf '%s\n' "$apps" | awk -F'\t' '{print NF}' | tr '\n' ' ' | sed 's/ $//')"
check_eq "arr row" $'arr\tdocker\tarr\trunning\t2/2\t7878,8989\t10.10.95.50\tlinuxserver/arr:latest\tweb\t-' "$(printf '%s\n' "$apps" | sed -n 1p)"
check_eq "kept app: folder, no container -> stopped 0/0" $'kept1\tdocker\tkept1\tstopped\t0/0\t-\t10.10.95.50\t-\tweb\t-' "$(printf '%s\n' "$apps" | sed -n 2p)"
check_eq "notes row" $'notes\tdocker\tnotes\texited\t0/1\t-\t10.10.95.50\tnginx:alpine\tother\t-' "$(printf '%s\n' "$apps" | sed -n 3p)"
check_eq "wiki partial" $'wiki\tdocker\twiki\tpartial\t1/2\t3000\t10.10.95.50\trequarks/wiki:2\trecipe\t-' "$(printf '%s\n' "$apps" | sed -n 4p)"
: > "$STATE.newapps"
apps=$($D --apps)
check_eq "stacks/ is web, recipes/ is recipe" $'pico\tdocker\tpico\tstopped\t0/0\t-\t10.10.95.50\t-\trecipe\t-\nzeta\tdocker\tzeta\tstopped\t0/0\t-\t10.10.95.50\t-\tweb\t-' "$(printf '%s\n' "$apps" | grep -E '^(pico|zeta)')"
rm -f "$STATE.newapps"
check_eq "the manager folder is not an app" 0 "$(printf '%s\n' "$apps" | grep -c '^arcane')"
check_eq "--list has the kept app too" $'kept1\tdocker\tkept1\tstopped\t-' "$($D --list | grep '^kept1')"

echo "-- logs"
reset; : > "$STATE"; echo docker > "$OWNERF"; echo arcane > "$HS_SETTINGS_DIR/dockerManager"
rc=0; out=$($D --logs arr) || rc=$?
check_eq "logs exit 0" 0 "$rc"
echo "$out" | grep -q "line one" && pass "logs default has line one" || fail "logs default: $out"
grep -qF -- "--tail 200" "$LOG" && pass "logs default tail 200" || fail "tail default: $(cat "$LOG")"
rc=0; out=$($D --logs arr 500) || rc=$?
check_eq "logs 500 exit 0" 0 "$rc"
grep -qF -- "--tail 500" "$LOG" && pass "logs tail 500" || fail "tail 500: $(cat "$LOG")"
rc=0; out=$($D --logs unknown 200) || rc=$?
check_eq "unknown app exit 1" 1 "$rc"
check_eq "unknown app no output" "" "$out"
rc=0; out=$($D --logs arr 99999) || rc=$?
check_eq "bad count exit 1" 1 "$rc"
check_eq "bad count no output" "" "$out"
rc=0; out=$($D --logs arr 0) || rc=$?
check_eq "zero count exit 1" 1 "$rc"
check_eq "zero count no output" "" "$out"
reset
rc=0; out=$($D --logs arr) || rc=$?
check_eq "off: logs exit 1" 1 "$rc"; check_eq "off: logs no output" "" "$out"

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

echo "-- hs sys docker plan|start setup (docker-setup.sh)"
S="bash $SCRIPTS/docker-setup.sh"
T=$'	'
reset
rc=0; out=$($S plan setup --set dockerManager=arcane --set dockerSize=s </dev/null 2>&1) || rc=$?
check_eq "plan exit 0" 0 "$rc"
echo "$out" | grep -qx "status${T}ok" && pass "plan status ok" || fail "plan: $out"
echo "$out" | grep -q "^step${T}1\. Create the container docker (2048 MiB, 2 CPUs" && pass "plan step with the size" || fail "plan step: $out"
echo "$out" | grep -q "^step${T}.*Start the manager arcane" && pass "plan names the manager" || fail "plan manager: $out"
check_eq "plan changed nothing" 0 "$(changes)"
rc=0; out=$($S plan setup --set dockerManager=foo </dev/null 2>&1) || rc=$?
check_eq "bad manager: exit 1" 1 "$rc"
echo "$out" | grep -qx "status${T}refused" && echo "$out" | grep -q "^reason${T}" && pass "bad manager refused with a reason" || fail "bad manager: $out"
rc=0; out=$($S plan setup --set dockerMemory=1 </dev/null 2>&1) || rc=$?
check_eq "other key: exit 1" 1 "$rc"
rc=0; out=$($S plan setup </dev/null 2>&1) || rc=$?
check_eq "no --set: exit 1" 1 "$rc"
reset; : > "$STATE"
rc=0; out=$($S plan setup --set dockerManager=webui </dev/null 2>&1) || rc=$?
check_eq "foreign instance docker: exit 1" 1 "$rc"
echo "$out" | grep -qx "status${T}refused" && pass "foreign instance refused" || fail "foreign: $out"
echo "$out" | grep -q "^reason${T}An instance called .docker. exists and is not managed by hs" && pass "foreign instance: the real reason, not the Fix line" || fail "foreign reason: $out"
echo "-- listed or dockerManager set, but no container: allowed"
reset; echo webui > "$HS_SETTINGS_DIR/dockerManager"
rc=0; out=$($S plan setup --set dockerManager=webui </dev/null 2>&1) || rc=$?
check_eq "manager set, no container: exit 0" 0 "$rc"
echo "$out" | grep -qx "status${T}ok" && pass "manager set, no container: plan ok" || fail "manager set: $out"
reset; echo docker > "$HS_CAPABILITIES_FILE"
rc=0; out=$($S plan setup --set dockerManager=webui </dev/null 2>&1) || rc=$?
check_eq "listed, no container: exit 0" 0 "$rc"
echo "$out" | grep -qx "status${T}ok" && pass "listed, no container: plan ok" || fail "listed: $out"
rc=0; $S start setup --set dockerManager=none </dev/null >/dev/null 2>&1 || rc=$?
check_eq "listed, no container: start exit 0" 0 "$rc"
grep -q "manage-ct --create docker" "$MLOG" && pass "listed, no container: enable ran" || fail "enable did not run: $(cat "$MLOG")"
echo "-- owned: refused"
reset; : > "$STATE"; echo docker > "$OWNERF"; echo docker > "$HS_CAPABILITIES_FILE"; echo webui > "$HS_SETTINGS_DIR/dockerManager"
rc=0; out=$($S plan setup --set dockerManager=webui </dev/null 2>&1) || rc=$?
check_eq "docker on already: exit 1" 1 "$rc"
echo "$out" | grep -q "^reason${T}Docker is on already" && pass "on already refused" || fail "on already: $out"
echo "-- owned, not listed: status says so"
reset; : > "$HS_CAPABILITIES_FILE"; : > "$STATE"; echo docker > "$OWNERF"
out=$($D status 2>&1)
echo "$out" | grep -q "exists, but Docker is not listed" && pass "owned, not listed: true text" || fail "text: $out"
: > "$HS_CAPABILITIES_FILE"
reset
rc=0; out=$($S start setup --set dockerManager=none </dev/null 2>&1) || rc=$?
check_eq "start exit 0" 0 "$rc"
echo "$out" | grep -qx "status${T}started" && pass "start status started" || fail "start: $out"
check_eq "dockerManager written by enable" none "$(cat "$HS_SETTINGS_DIR/dockerManager" 2>/dev/null || true)"

echo "-- hs sys docker mount"
reset; : > "$STATE"; echo docker > "$OWNERF"
mkdir -p "$WORK/remote/nas"; export HS_REMOTE_ROOT=$WORK/remote
printf '#!/usr/bin/env bash
[ "$2" = "$HS_REMOTE_ROOT/nas/movies" ]
' > "$BIN/mountpoint"; chmod +x "$BIN/mountpoint"
export HS_MOUNTPOINT=$BIN/mountpoint
printf 'nas	nas.lan	movies	remote-nas	-
' > "$HS_STATE_DIR/remote-mounts"
rc=0; out=$($D mount media /media --as 1000:1000 </dev/null 2>&1) || rc=$?
check_eq "no terminal, no --yes: refused" 1 "$rc"
check_eq "nothing changed" 0 "$(changes)"
echo "$out" | grep -q "restarts, and with it every app" && pass "restart warning in the plan" || fail "plan: $out"
rc=0; $D mount media /media </dev/null >/dev/null 2>&1 || rc=$?
check_eq "local share without --as refused" 1 "$rc"
rc=0; $D mount media media --as 1000:1000 --yes </dev/null >/dev/null 2>&1 || rc=$?
check_eq "relative path refused" 1 "$rc"
rc=0; $D mount media /media --as 1000:1000 --dry-run </dev/null >/dev/null 2>&1 || rc=$?
check_eq "dry run exit 0" 0 "$rc"; check_eq "dry run changes nothing" 0 "$(changes)"
rc=0; $D mount media /media --as 1000:1000 --yes </dev/null >/dev/null 2>&1 || rc=$?
check_eq "local: exit 0" 0 "$rc"
grep -qF "manage-ct docker --add-storage shares media /media --as 1000:1000 OWNER=docker" "$MLOG" && pass "local: owner's pass" || fail "local: $(cat "$MLOG")"
: > "$LOG"
rc=0; $D mount remote:nas /media-nas --yes </dev/null >/dev/null 2>&1 || rc=$?
check_eq "remote: exit 0" 0 "$rc"
grep -qF "incus config device add docker remote-nas disk source=$WORK/remote/nas path=/media-nas recursive=true propagation=rslave" "$LOG" && pass "remote: peer directory, recursive, rslave" || fail "remote: $(cat "$LOG")"
rc=0; $D mount remote:nas /x --as 1000:1000 --yes </dev/null >/dev/null 2>&1 || rc=$?
check_eq "remote with --as refused" 1 "$rc"
printf 'nas	nas.lan	music	remote-nas	-
' > "$HS_STATE_DIR/remote-mounts"
rc=0; $D mount remote:nas /x --yes </dev/null >/dev/null 2>&1 || rc=$?
check_eq "remote configured but its share not mounted: refused" 1 "$rc"
printf 'nas	nas.lan	movies	remote-nas	-
' > "$HS_STATE_DIR/remote-mounts"
rc=0; $D mount remote:gone /x --yes </dev/null >/dev/null 2>&1 || rc=$?
check_eq "remote not mounted refused" 1 "$rc"
: > "$STATE.dev"; rc=0; $D mount remote:nas /y --yes </dev/null >/dev/null 2>&1 || rc=$?
check_eq "device exists: refused" 1 "$rc"; rm -f "$STATE.dev"
reset; rc=0; $D mount media /media --as 1000:1000 --yes </dev/null >/dev/null 2>&1 || rc=$?
check_eq "Docker not on: refused" 1 "$rc"

echo "-- hs sys docker containers"
reset; : > "$STATE"; echo docker > "$OWNERF"
out=$($D --containers </dev/null 2>&1)
check_eq "containers: 2 rows" 2 "$(printf '%s
' "$out" | grep -c .)"
check_eq "containers: every row has 3 fields" 0 "$(printf '%s
' "$out" | awk -F'	' 'NF != 3' | wc -l | tr -d ' ')"
printf '%s
' "$out" | grep -qx "solo${T}-${T}exited" && pass "containers: empty project is -" || fail "containers: $out"
printf '%s
' "$out" | grep -qx "arr-app-1${T}arr${T}running" && pass "containers: name project state" || fail "containers: $out"
reset; out=$($D --containers </dev/null 2>&1); check_eq "containers: no row when Docker is off" "" "$out"

echo "-- hs sys docker plan|start mount (docker-setup.sh)"
reset; : > "$STATE"; echo docker > "$OWNERF"
rc=0; out=$($S plan mount media --path /shares/media </dev/null 2>&1) || rc=$?
check_eq "mount plan exit 0" 0 "$rc"
echo "$out" | grep -qx "status${T}ok" && pass "mount plan status ok" || fail "mount plan: $out"
echo "$out" | grep -q "^step${T}1\. Mount the share media as /shares/media, files seen as the user 1000:1000" && pass "mount plan: default --as 1000:1000" || fail "mount plan step: $out"
echo "$out" | grep -q "^warn${T}Docker restarts, and with it every app: arcane, arr" && pass "mount plan: restart warning names the running apps" || fail "mount plan warn: $out"
echo "$out" | grep -qx "command${T}hs docker mount media /shares/media --as 1000:1000 --yes --job" && pass "mount plan: the command carries the resolved --as" || fail "mount plan command: $out"
echo "$out" | grep -qx "long${T}yes" && pass "mount plan: long" || fail "mount plan long: $out"
check_eq "mount plan changed nothing" 0 "$(grep -c . "$MLOG")"
printf 'uid 1000 1001
gid 100 1002' > "$STATE.idmap"
out=$($S plan mount media --path /shares/media </dev/null 2>&1) || true
echo "$out" | grep -q "files seen as the user 1001:1002" && pass "mount plan: reuses the mapped user" || fail "mount plan idmap: $out"
echo "$out" | grep -q "^warn${T}" && fail "mount plan: warn although the mapping stays" || pass "mount plan: no restart warning when the mapping stays"
rc=0; out=$($S plan mount media --path /shares/media --as 1000:1000 </dev/null 2>&1) || rc=$?
check_eq "mount plan: another user than the mapped one: exit 1" 1 "$rc"
echo "$out" | grep -qx "status${T}refused" && echo "$out" | grep -q "^reason${T}.*maps another user already" && pass "mount plan: idmap conflict refused with the reason" || fail "mount conflict: $out"
rm -f "$STATE.idmap"
: > "$STATE.dev"; rc=0; out=$($S plan mount media --path /shares/media </dev/null 2>&1) || rc=$?
check_eq "mount plan: a share Docker has already is refused up front" 1 "$rc"
echo "$out" | grep -q "^reason${T}.*has a device media already" && pass "mount plan: the reason says it is mounted" || fail "mount device: $out"
rm -f "$STATE.dev"
rc=0; out=$($S plan mount media --path media </dev/null 2>&1) || rc=$?
check_eq "mount plan: relative path refused" 1 "$rc"
rc=0; out=$($S plan mount remote:nas --path /shares/nas --as 1000:1000 </dev/null 2>&1) || rc=$?
check_eq "mount plan: remote with --as refused" 1 "$rc"
: > "$MLOG"
rc=0; out=$($S start mount media --path /shares/media </dev/null 2>&1) || rc=$?
check_eq "mount start exit 0" 0 "$rc"
echo "$out" | grep -qx "status${T}started" && pass "mount start: started" || fail "mount start: $out"
grep -qF "manage-ct docker --add-storage shares media /shares/media --as 1000:1000 OWNER=docker" "$MLOG" && pass "mount start: the owner's pass, the default user" || fail "mount start: $(cat "$MLOG")"

finish
