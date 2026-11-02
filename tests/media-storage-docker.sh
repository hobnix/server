#!/usr/bin/env bash
# media_storage_docker (scripts/recipes/_media.sh): the share comes in through `hs sys docker mount`, which restarts the container docker and so
# every app in it. With other apps running the recipe stops and prints the command; with none it mounts by itself; in lxc mode it is not used.
# A fake incus and a fake `bash docker.sh mount` (a function that logs the call); no root, no server.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
have jq || { skip "the mount check needs jq"; finish; exit 0; }
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test HS_STATE_DIR=$WORK/state HS_SETTINGS_DIR=$WORK/state/settings HS_ETC_DIR=$WORK/etc
mkdir -p "$WORK/bin" "$HS_SETTINGS_DIR" "$HS_ETC_DIR"
cat > "$WORK/bin/incus" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  query) echo '{"expanded_devices":{}}' ;;
  exec) all="$*"
    case "$all" in
      *"docker ps"*) [ -z "${FAKE_PS_FAIL:-}" ] || exit 1; cat "$FAKE_PS" 2>/dev/null || true ;;
      *'echo "'*) echo 1001:1001 ;;
      *) : ;;
    esac ;;
  info) exit 1 ;;
esac
exit 0
FAKE
chmod +x "$WORK/bin/incus"
export PATH="$WORK/bin:$PATH" HS_INCUS=$WORK/bin/incus FAKE_PS=$WORK/ps
cat > "$WORK/stub.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
scripts=$SCRIPTS
state=\$HS_STATE_DIR
ct=\${DEMO_CT:-radarr}
app=\${DEMO_APP:-}
share=media
. "\$scripts/recipes/_lib.sh"
. "\$scripts/recipes/_media.sh"
wait_address=true
bash() { if [ "\${2:-}" = mount ]; then echo "mount \$*" >> "$WORK/mount.log"; else command bash "\$@"; fi; }
RUNS_DOCKER=\${DEMO_DOCKER:-false}
media_storage_docker_or_lxc() { media_storage media; }
media_storage_docker_or_lxc
EOF
run() { rm -f "$WORK/mount.log"; bash "$WORK/stub.sh" 2>&1; }

echo "-- other apps run in docker: stop, print the command, do not mount"
printf 'jellyfin\nsonarr\nsonarr\nradarr\n' > "$WORK/ps"
rc=0; out=$(DEMO_DOCKER=true DEMO_APP=radarr run) || rc=$?
check "it stops" test "$rc" != 0
check_out "the exact command is shown" "hs sys docker mount media /media --as 1001:1001" echo "$out"
check_out "it names the apps that would restart" "running now: jellyfin, sonarr" echo "$out"
check_out "and warns about the restart" "restarts, and with it everything in it" echo "$out"
check "mount was not called" test ! -e "$WORK/mount.log"

echo "-- only the app itself (or nothing) runs: mount once with --yes"
printf 'radarr\n' > "$WORK/ps"
DEMO_DOCKER=true DEMO_APP=radarr run >/dev/null || true
check "mount was called once" test "$(wc -l < "$WORK/mount.log" 2>/dev/null || echo 0)" = 1
check "with the share, the path, the user and --yes" grep -q 'mount .*docker.sh mount media /media --as 1001:1001 --yes' "$WORK/mount.log"
: > "$WORK/ps"
DEMO_DOCKER=true DEMO_APP=radarr run >/dev/null || true
check "no apps at all: mounted too" test "$(wc -l < "$WORK/mount.log" 2>/dev/null || echo 0)" = 1

echo "-- docker ps fails or hangs: do not guess, do not mount"
printf 'radarr	radarr-1
' > "$WORK/ps"
rc=0; out=$(FAKE_PS_FAIL=1 DEMO_DOCKER=true DEMO_APP=radarr run) || rc=$?
check "it stops" test "$rc" != 0
check_out "it says it could not read Docker" "Could not read what runs in Docker" echo "$out"
check_out "and shows the command" "hs sys docker mount media /media --as 1001:1001" echo "$out"
check "mount was not called" test ! -e "$WORK/mount.log"

echo "-- the manager's own project is not an app"
printf 'arcane' > "$HS_SETTINGS_DIR/dockerManager"
printf 'arcane	arcane
radarr	radarr-1
' > "$WORK/ps"
DEMO_DOCKER=true DEMO_APP=radarr run >/dev/null || true
check "only the manager and the app: mounted" test "$(wc -l < "$WORK/mount.log" 2>/dev/null || echo 0)" = 1
printf 'arcane	arcane
sonarr	sonarr-1
' > "$WORK/ps"
rc=0; out=$(DEMO_DOCKER=true DEMO_APP=radarr run) || rc=$?
check "another app next to the manager: stop" test "$rc" != 0
check_out "the manager is not named" "running now: sonarr)" echo "$out"
rm -f "$HS_SETTINGS_DIR/dockerManager"

echo "-- a container without a compose project counts too"
printf '	my-nginx
' > "$WORK/ps"
rc=0; out=$(DEMO_DOCKER=true DEMO_APP=radarr run) || rc=$?
check "it stops" test "$rc" != 0
check_out "it is named by its container name" "running now: my-nginx)" echo "$out"
check "mount was not called" test ! -e "$WORK/mount.log"

echo "-- lxc mode never takes this route"
printf 'jellyfin\n' > "$WORK/ps"
DEMO_DOCKER=false run >/dev/null || true
check "no docker mount in lxc mode" test ! -e "$WORK/mount.log"
finish
