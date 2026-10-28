#!/usr/bin/env bash
# hs cleanup: finds leftovers, changes nothing. No root needed.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1
BIN=$WORK/fake; mkdir -p "$BIN"
cat > "$BIN/incus" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "list -c n -f csv") printf 'dc1\nlam\n' ;;
  "list -c ns -f csv") printf 'dc1,RUNNING\nlam,STOPPED\nold,STOPPED\n' ;;
esac
FAKE
chmod +x "$BIN/incus"
export HS_INCUS=$BIN/incus HS_STATE_DIR=$WORK/state HS_WEBZFS_DIR=$WORK/webzfs HS_TEMP_DIR=$WORK/temp HS_GENERATIONS=3 HS_NO_PASSWD=1
mkdir -p "$HS_STATE_DIR" "$WORK/webzfs" "$WORK/temp/usb"
touch "$HS_STATE_DIR/machine.nix.before-config"
C="bash $SCRIPTS/cleanup.sh"

check_out "the lam container is found" "hs ct lam remove" $C
check_out "WebZFS state is found" "left over from WebZFS" $C
check_out "an empty temp folder is found" "empty leftover folder" $C
check_out "a stopped container is named" "'old' is stopped" $C
check_out "it says it changed nothing" "Nothing was changed" $C
check_eq "--list is tab separated: kind, what, fix" "container	leftover	mount	container	copy" \
  "$($C --list | cut -f1 | paste -sd'	')"
check_eq "nothing was removed" "yes" "$([ -d "$WORK/webzfs" ] && [ -d "$WORK/temp/usb" ] && echo yes)"
export HS_GENERATIONS=40
check_out "many generations are named" "40 system generations" $C
rm -rf "$WORK/webzfs" "$WORK/temp" "$HS_STATE_DIR"/machine.nix.before-config
cat > "$BIN/incus" <<'FAKE'
#!/usr/bin/env bash
case "$*" in "list -c n -f csv") echo dc1 ;; esac
FAKE
export HS_GENERATIONS=3
check_out "a clean server says so" "Leftovers: None" $C

finish
