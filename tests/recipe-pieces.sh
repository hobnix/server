#!/usr/bin/env bash
# The piece helpers of scripts/recipes/_lib.sh (stamps, pins, --check). No server needed.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1
run() {   # run <args...> -- <snippet>: the snippet runs with the helpers loaded
  local args=() ; while [ "$1" != -- ]; do args+=("$1"); shift; done; shift
  bash -c 'state=$1; ct=t; scripts=$2; shift 2; set -- "$@"; . "$2/recipes/_lib.sh" 2>/dev/null; '"$1" _ "$WORK" "$SCRIPTS" "${args[@]}"
}
S() { bash -c 'state=$1; ct=t; scripts=$2; shift 2; . "$scripts/recipes/_lib.sh"; '"$SNIP" _ "$WORK" "$SCRIPTS" "$@"; }
echo "-- stamps and pieces"
SNIP='piece app 1.2 App && echo current || echo stale'
check_eq "no stamp: stale" "stale" "$(S 2>/dev/null | tail -n1)"
SNIP='piece_done app 1.2; piece app 1.2 App && echo current || echo stale'
check_eq "after piece_done: current" "current" "$(S 2>/dev/null | tail -n1)"
SNIP='piece app 1.3 App && echo current || echo stale'
check_eq "a new pin: stale again" "stale" "$(S 2>/dev/null | tail -n1)"
echo "-- --check"
SNIP='piece app 1.3 App; piece other 2 Other; check_done'
out=$(S --check 2>&1); rc=$?
check_out "--check names the piece that would update" "would update +App [(]1.2 -> 1.3[)]" echo "$out"
check_eq "--check exits 1 when something would update" "1" "$(S --check >/dev/null 2>&1; echo $?)"
SNIP='piece_done app 1.3; piece_done other 2; piece app 1.3 App; piece other 2 Other; check_done'
check_eq "--check exits 0 when all is current" "0" "$(S --check >/dev/null 2>&1; echo $?)"
echo "-- fetch_pinned (curl is replaced by a copy)"
printf 'hello
' > "$WORK/src"; sum=$(sha256sum "$WORK/src" | cut -d' ' -f1)
SNIP='curl() { cp '"$WORK"'/src "$3"; }; fetch_pinned blob http://x/y '"$sum"' '"$WORK"'/dest 1; cat '"$WORK"'/dest'
check_out "downloads on the first run" "hello" S
SNIP='curl() { return 9; }; fetch_pinned blob http://x/y '"$sum"' '"$WORK"'/dest 1; echo kept'
check_out "does not download when current" "kept" S
rm -f "$WORK/hit"
SNIP='curl() { touch '"$WORK"'/hit; return 9; }; fetch_pinned blob http://x/y '"$sum"' '"$WORK"'/dest 2'
S >/dev/null 2>&1 || true
check "a new pin downloads again" test -e "$WORK/hit"
SNIP='curl() { echo evil > "$3"; }; fetch_pinned bad http://x/y '"$sum"' '"$WORK"'/dest2 1'
check_out "a wrong checksum installs nothing" "does not match" S
check "and leaves no file" test ! -e "$WORK/dest2"
echo "-- child helpers (a recipe that runs in the container docker)"
cat > "$WORK/dstatus" <<'FAKE'
#!/usr/bin/env bash
printf 'state	on
running	yes
address	10.1.2.3
'
FAKE
cat > "$WORK/dstatus-off" <<'FAKE'
#!/usr/bin/env bash
printf 'state	off
running	no
address	-
'
FAKE
mkdir -p "$WORK/fbin"
cat > "$WORK/fbin/incus" <<'FAKE'
#!/usr/bin/env bash
echo "incus $*" >> "$WORK/incus.log"
case "$1" in
  info) exit 1 ;;
  exec) case "$*" in *"docker ps"*) printf 'other	0.0.0.0:7878->7878/tcp
' ;; *"test -d"*|*'[ -d "$d" ]'*) exit 1 ;; *'mountpoint -q'*) [ ! -e "$WORK/nomount" ]; exit $? ;; *) cat >/dev/null ;; esac ;;
esac
exit 0
FAKE
chmod +x "$WORK/dstatus" "$WORK/dstatus-off" "$WORK/fbin/incus"
C() {   # C <status script> <snippet>: a recipe called radarr asks for its runtime
  PATH="$WORK/fbin:$PATH" WORK=$WORK HS_DOCKER_STATUS=$1 RECIPE_RUNS=docker bash -c 'state=$1; scripts=$2; app=radarr; ct=$app; . "$scripts/recipes/_lib.sh"; shift 2; '"$2" _ "$WORK" "$SCRIPTS" 2>&1
}
: > "$WORK/incus.log"
out=$(C "$WORK/dstatus" 'recipe_runtime lxc docker; echo "$ct $RUNS_DOCKER $ip $existed $conf"')
check_eq "docker mode: parent, flag, address, answers stay with the app" "docker true 10.1.2.3 false $WORK/recipe-radarr.conf" "$(printf '%s
' "$out" | tail -n1)"
: > "$WORK/nomount"
out=$(C "$WORK/dstatus" 'recipe_runtime lxc docker; echo reached')
check "share apps not mounted: refused with the pointer" grep -q "hs docker enable" <<<"$out"
check "share apps not mounted: the recipe did not go on" bash -c '! grep -q reached <<<"$1"' _ "$out"
rm -f "$WORK/nomount"
out=$(C "$WORK/dstatus-off" 'recipe_runtime lxc docker; echo reached')
check "docker off: refused with the pointer" grep -q "hs docker enable" <<<"$out"
check "docker off: the recipe did not go on" bash -c '! grep -q reached <<<"$1"' _ "$out"
out=$(C "$WORK/dstatus" 'child_port_free 7878 radarr; echo free')
check "a port of another project is not free" grep -q "used by 'other'" <<<"$out"
out=$(C "$WORK/dstatus" 'child_port_free 7878 other; echo free')
check_eq "its own port is free" "free" "$(printf '%s
' "$out" | tail -n1)"
: > "$WORK/incus.log"
C "$WORK/dstatus" 'APP_DIR=/shares/apps/recipes/radarr; printf "services: {}
" | child_compose radarr; child_up radarr; child_pull radarr' >/dev/null
check "compose written under /shares/apps/recipes/radarr" grep -q "/shares/apps/recipes/radarr/docker-compose.yml.new" "$WORK/incus.log"
check "compose checked with the project name" grep -q "docker compose -p radarr config -q" "$WORK/incus.log"
check "up and pull use the project name" grep -q "sh radarr /shares/apps/recipes/radarr pull" "$WORK/incus.log"
mkdir -p "$WORK/st"; : > "$WORK/st/x"
out=$(C "$WORK/dstatus" 'RUNS_DOCKER=true; ct=docker; state='"$WORK"'/st; declare_dump radarr "hs-dump sqlite-tree radarr /opt/apps/radarr"; backup_with_dump radarr ""; cat $state/backup-dump/docker')
check "docker mode: the dump goes to the descriptor of docker" grep -q "# dump:radarr" <<<"$out"
check "docker mode: a warning when docker is not in the backup" grep -q "not in the backup" <<<"$out"
finish
