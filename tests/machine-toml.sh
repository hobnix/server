#!/usr/bin/env bash
# machine.toml: sync (the layout of the example, the values of the user), check, migrate, get/set/unset, and the
# question of hs update. Temp files and stand-ins only: no root, no server (needs python3 with tomllib).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test
export HS_STATE_DIR=$WORK/state HS_MACHINE_FILE=$WORK/machine.toml HS_MACHINE_EXAMPLE=$ROOT/machine.toml.example
mkdir -p "$HS_STATE_DIR"
EX=$HS_MACHINE_EXAMPLE M=$HS_MACHINE_FILE
SYNC="bash $SCRIPTS/machine-sync.sh"
TOOL="python3 $SCRIPTS/machine-toml.py"
CFG="bash $SCRIPTS/config.sh"
# lines that differ from the example (diff lines starting with < or >)
difflines() { diff "$M" "$EX" | grep -c '^[<>]' || true; }

echo "-- the example itself"
check "the example parses" python3 -c "import tomllib,sys; tomllib.load(open(sys.argv[1],'rb'))" "$EX"
check_eq "every option paragraph has a key the tool finds" "51" "$(grep -cE '^(# )?[A-Za-z][A-Za-z0-9]* = ' "$EX")"
check_out "check against itself: only CHANGEME is wrong" "hostId.*still CHANGEME" $TOOL check "$EX" "$EX"

echo "-- sync creates the file from the example"
check_out "no file yet" "No .* yet: copy" $SYNC sync
cp "$EX" "$M"; sed -i 's/CHANGEME/deadbeef/' "$M"
check_eq "only the hostId differs" "2" "$(difflines)"
check_out "nothing to add" "has every option" $SYNC sync
check_eq "and nothing was rewritten (no copy made)" "no" "$(test -e "$HS_STATE_DIR/machine.toml.before-sync" && echo yes || echo no)"

echo "-- values stay, the layout is the example's"
$CFG set keyMap de >/dev/null; $CFG set syncEveryHours 6 >/dev/null; $CFG set gpu intel >/dev/null
$TOOL set "$M" sshKeys '["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIkeyone a@pc", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIkeytwo b@pc"]' >/dev/null
$TOOL set "$M" vlans '{ home = { id = 95, default = true }, iot = { id = 30 } }' >/dev/null
$TOOL set "$M" adDomain '{ realm = "AD.HOME.LAN", workgroup = "HOME" }' >/dev/null
$TOOL set "$M" dhcpRange '[100, 150]' >/dev/null
cp "$M" "$WORK/mine.toml"
check_out "sync on a file that is in layout" "has every option" $SYNC sync
check_eq "the file is byte for byte the same" "$(cksum < "$WORK/mine.toml")" "$(cksum < "$M")"
# a file the user mangled: own comments, shuffled order, blank lines, a different spelling of the values
cat > "$M" <<'T'
# my notes
keyMap = 'de'
hostId   = "deadbeef"
hostName = "mine"

sshKeys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIkeyone a@pc" ]
nic = "enp9s0"
smbAllow = "10.0.0.0/24"
vlans = { home = { id = 95, default = true } }
syncEveryHours = 6
T
check_out "sync lists what was missing" "keyMap" $SYNC sync --check
check_eq "--check changes nothing" "keyMap = 'de'" "$(sed -n 2p "$M")"
$SYNC sync >/dev/null
check_eq "the order is the example's" "hostName,hostId,sshKeys,keyMap" "$(grep -E '^(# )?(hostName|hostId|sshKeys|keyMap) = ' "$M" | sed -E 's/^# //; s/ =.*//' | paste -sd,)"
check_eq "values are kept (and spelled the standard way)" 'keyMap = "de"' "$(grep '^keyMap' "$M")"
check_eq "hostName kept" 'hostName = "mine"' "$(grep '^hostName' "$M")"
check_eq "a new option is there, commented out" "1" "$(grep -c "^# timeZone = " "$M")"
check_eq "the example's text is back (my note is gone)" "0" "$(grep -c '^# my notes' "$M")"
check_eq "a copy of the old file was made" "keyMap = 'de'" "$(sed -n 2p "$HS_STATE_DIR/machine.toml.before-sync")"
check_eq "set values: only their lines differ from the example" "14" "$(difflines)"
check_eq "the values read the same" "mine" "$($TOOL get "$M" hostName)"
$SYNC sync >/dev/null; rm -f "$HS_STATE_DIR/machine.toml.before-sync"; $SYNC sync >/dev/null
check_eq "a second sync changes nothing and makes no copy" "no" "$(test -e "$HS_STATE_DIR/machine.toml.before-sync" && echo yes || echo no)"

echo "-- an option that is new in the example lands in its place"
sed -i '/^# How many days Prometheus/,/^$/d' "$M"
check_out "--list names it" "^new.metricsDays" $SYNC --list
$SYNC sync >/dev/null
check_eq "it is back after metrics" "metrics,metricsDays,metricsMaxGB" "$(grep -E '^(# )?(metrics|metricsDays|metricsMaxGB) = ' "$M" | sed -E 's/^# //; s/ =.*//' | paste -sd,)"
check_eq "--list is empty now" "" "$($SYNC --list)"

echo "-- keys the example does not know"
echo 'keyMpa = "de"' >> "$M"
$SYNC sync >/dev/null 2>&1
check_eq "kept in the closing section" "1" "$(grep -c '^keyMpa = "de"' "$M")"
check_out "named as not in the example" "Not in the example.*keyMpa" $SYNC sync
check_out "check suggests the right name" "did you mean keyMap" $SYNC check
sed -i '/^# ═══ Not in the example/,$d' "$M"
$SYNC sync >/dev/null 2>&1

echo "-- a broken file is left alone"
cp "$M" "$WORK/good.toml"; echo 'this is = = not toml' >> "$M"; cp "$M" "$WORK/broken.toml"
check_out "sync refuses" "does not parse|nothing changed|Expected" $SYNC sync
check_eq "and changes nothing" "$(cksum < "$WORK/broken.toml")" "$(cksum < "$M")"
cp "$WORK/good.toml" "$M"

echo "-- check"
check_out "a fine file" "machine.toml is fine" env HS_QUIET_OK= $SYNC check
$TOOL set "$M" syncEveryHours '"six"' >/dev/null
check_out "a wrong type" "syncEveryHours: must be int" $SYNC check
$TOOL set "$M" syncEveryHours 6 >/dev/null
sed -i 's/^nic = .*/# nic = "x"/' "$M"
check_out "a missing required option" "nic: missing" $SYNC check
check_eq "and it fails" "1" "$($SYNC check >/dev/null 2>&1; echo $?)"
$TOOL set "$M" nic '"enp9s0"' >/dev/null
$TOOL set "$M" gpu '["nvidia", "intel"]' >/dev/null
check_out "gpu may be a list" "machine.toml is fine" env HS_QUIET_OK= $SYNC check

echo "-- get, set, unset"
check_eq "a string" "mine" "$($TOOL get "$M" hostName)"
check_eq "a bool" "false" "$($TOOL set "$M" metrics false >/dev/null; $TOOL get "$M" metrics)"
check_eq "a list, one per line" "nvidia
intel" "$($TOOL get "$M" gpu)"
check_eq "inside a table" "95" "$($TOOL get "$M" vlans.home.id)"
check_eq "JSON" '["nvidia", "intel"]' "$($TOOL get "$M" gpu --json)"
check_eq "not set: exit 1" "1" "$($TOOL get "$M" timeZone >/dev/null; echo $?)"
$TOOL set "$M" keyMap '"de"' >/dev/null
check_eq "a commented option is revived in its place" 'keyMap = "de"' "$(grep '^keyMap' "$M")"
$TOOL unset "$M" keyMap >/dev/null
check_eq "unset comments it out" '# keyMap = "de"' "$(grep 'keyMap' "$M" | head -n1)"
check_out "a value that is not TOML is refused" "not a TOML value" $TOOL set "$M" keyMap de
check_eq "a string with quotes survives" 'it "works"' "$($TOOL set "$M" hostName '"it \"works\""' >/dev/null; $TOOL get "$M" hostName)"
$TOOL set "$M" hostName '"homeserver"' >/dev/null

echo "-- migrate from machine.nix"
rm -f "$M"; BIN=$WORK/bin; mkdir -p "$BIN"
cat > "$BIN/nix-instantiate" <<'FAKE'
#!/usr/bin/env bash
# stands in for: nix-instantiate --eval --strict --json -E 'import <file>'
echo '{"hostName":"oldname","hostId":"cafe0001","nic":"enp1s0","smbAllow":"10.0.0.0/24","sshKeys":["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIold o@pc"],"vlans":{"a":{"id":1,"default":true}},"metrics":true,"adDomain":{"realm":"AD.X.LAN","workgroup":"X"}}'
FAKE
chmod +x "$BIN/nix-instantiate"
echo '{ hostName = "oldname"; }' > "$WORK/machine.nix"
check_out "migrate" "Converted" env PATH="$BIN:$PATH" $SYNC migrate
check_eq "the values arrived" "oldname AD.X.LAN true" "$($TOOL get "$M" hostName) $($TOOL get "$M" adDomain.realm) $($TOOL get "$M" metrics)"
check_eq "in the layout of the example" "1" "$(grep -c '^# ═══ Storage' "$M")"
check_eq "the old file is kept under another name" "yes" "$(test -f "$WORK/machine.nix.migrated" && test ! -e "$WORK/machine.nix" && echo yes)"
check_out "a second migrate does nothing" "nothing to convert" $SYNC migrate
check_out "the shim does the same for the old command" "has every option|Added|now has" env HS_QUIET_OK= bash "$SCRIPTS/machine-merge.sh"

echo "-- hs update asks before the rebuild"
G="git -c user.name=t -c user.email=t@t -c commit.gpgsign=false"
UP=$WORK/up.git; REPO=$WORK/repo; PUSHER=$WORK/pusher
git init -q --bare "$UP"; git clone -q "$UP" "$PUSHER" 2>/dev/null
mkdir -p "$PUSHER/scripts/lib"
cp "$SCRIPTS"/machine-sync.sh "$SCRIPTS"/machine-toml.py "$PUSHER/scripts/"
cp "$SCRIPTS"/lib/machine.sh "$SCRIPTS"/lib/ui.sh "$SCRIPTS"/lib/i18n.sh "$SCRIPTS"/lib/setting.sh "$PUSHER/scripts/lib/"; cp -r "$SCRIPTS"/lib/i18n "$PUSHER/scripts/lib/"
printf '#!/usr/bin/env bash\necho "REBUILD RAN"\n' > "$PUSHER/scripts/rebuild.sh"
cp "$EX" "$PUSHER/machine.toml.example"
( cd "$PUSHER" && $G add -A && $G commit -q -m first && git push -q origin HEAD 2>/dev/null )
git clone -q "$UP" "$REPO" 2>/dev/null
cp "$EX" "$REPO/machine.toml"; sed -i 's/CHANGEME/deadbeef/' "$REPO/machine.toml"
printf '#!/bin/sh\nshift 3\nexec "$@"\n' > "$BIN/sudo"; chmod +x "$BIN/sudo"
printf '#!/bin/sh\nexit 0\n' > "$BIN/logger"; chmod +x "$BIN/logger"
unset HS_MACHINE_EXAMPLE   # the example of the checkout (scripts/..) is the one that counts here
export HS_REPO=$REPO HS_LOCKED_MARKER=$WORK/nolock
U="bash $SCRIPTS/update.sh"
upstream() {   # upstream <name>: a new option in the example, pushed
  printf '\n# %s does a thing\n# %s = true\n' "$1" "$1" >> "$PUSHER/machine.toml.example"
  ( cd "$PUSHER" && $G add -A && $G commit -q -m "add $1" && git push -q origin HEAD 2>/dev/null )
}
export HS_MACHINE_FILE=$REPO/machine.toml
env PATH="$BIN:$PATH" $U > "$WORK/u.out" 2>&1 < /dev/null
check_out "nothing new: no question, the rebuild runs" "REBUILD RAN" cat "$WORK/u.out"
upstream optionOne
env PATH="$BIN:$PATH" HS_GUIDED_TTY=1 $U > "$WORK/u.out" 2>&1 <<< "2"
check_out "a new option on a terminal: the options are listed" "optionOne" cat "$WORK/u.out"
check_out "and the question is asked" "Rebuild now" cat "$WORK/u.out"
check_eq "stopping: no rebuild" "0" "$(grep -c 'REBUILD RAN' "$WORK/u.out")"
check_out "stopping names the file to edit" "Edit .*machine.toml, then run: hs rebuild" cat "$WORK/u.out"
check_eq "the option is in the file, in place, commented out" "1" "$(grep -c '^# optionOne = true' "$REPO/machine.toml")"
upstream optionTwo
env PATH="$BIN:$PATH" HS_GUIDED_TTY=1 $U > "$WORK/u.out" 2>&1 <<< "1"
check_out "answering rebuild: it rebuilds" "REBUILD RAN" cat "$WORK/u.out"
upstream optionThree
env PATH="$BIN:$PATH" $U > "$WORK/u.out" 2>&1 < /dev/null
check_out "no terminal: no question, rebuilds as before" "REBUILD RAN" cat "$WORK/u.out"
check_eq "and the option is in the file" "1" "$(grep -c '^# optionThree = true' "$REPO/machine.toml")"
upstream optionFour
env PATH="$BIN:$PATH" $U --stop-on-new > "$WORK/u.out" 2>&1 < /dev/null
check_eq "--stop-on-new stops without asking" "0" "$(grep -c 'REBUILD RAN' "$WORK/u.out")"
upstream optionFive
env PATH="$BIN:$PATH" HS_GUIDED_TTY=1 $U --yes > "$WORK/u.out" 2>&1 < /dev/null
check_out "--yes rebuilds without asking" "REBUILD RAN" cat "$WORK/u.out"
check_eq "the question was not asked" "0" "$(grep -c 'Rebuild now' "$WORK/u.out")"


echo "-- hs update skips the rebuild when nothing changed"
. "$SCRIPTS/lib/stamp.sh"
export HS_STATE_DIR=$WORK/stamp-state; mkdir -p "$HS_STATE_DIR"
stamp() {   # stamp <dirty>: what a rebuild of the checkout as it is now would have written
  printf 'rev=%s\ndirty=%s\nmachine=%s\ntime=1\n' "$(git -C "$REPO" rev-parse HEAD)" "$1" "$(config_fingerprint "$REPO")" > "$HS_STATE_DIR/last-rebuild-rev"
}
env PATH="$BIN:$PATH" $U > "$WORK/u.out" 2>&1 < /dev/null   # normalises machine.toml (sync) and rebuilds
stamp 0
env PATH="$BIN:$PATH" $U > "$WORK/u.out" 2>&1 < /dev/null
check_out "same revision, same files: it says so" "Nothing changed since the last rebuild" cat "$WORK/u.out"
check_eq "and the rebuild does not run" "0" "$(grep -c 'REBUILD RAN' "$WORK/u.out")"
check_out "it names the way to build anyway" "hs update --force" cat "$WORK/u.out"
env PATH="$BIN:$PATH" $U --force > "$WORK/u.out" 2>&1 < /dev/null
check_out "--force rebuilds anyway" "REBUILD RAN" cat "$WORK/u.out"
sed -i 's/deadbeef/cafebabe/' "$REPO/machine.toml"   # a real value (a comment would be normalised away by the sync)
env PATH="$BIN:$PATH" $U > "$WORK/u.out" 2>&1 < /dev/null
check_out "machine.toml changed since the last rebuild: it rebuilds" "REBUILD RAN" cat "$WORK/u.out"
stamp 1
env PATH="$BIN:$PATH" $U > "$WORK/u.out" 2>&1 < /dev/null
check_out "the last rebuild was of a dirty checkout: it rebuilds" "REBUILD RAN" cat "$WORK/u.out"
stamp 0
printf '# a change\n' >> "$PUSHER/scripts/rebuild.sh"; ( cd "$PUSHER" && $G add -A && $G commit -q -m "a change" && git push -q origin HEAD 2>/dev/null )
env PATH="$BIN:$PATH" $U > "$WORK/u.out" 2>&1 < /dev/null
check_out "a new commit: it rebuilds" "REBUILD RAN" cat "$WORK/u.out"
rm -f "$HS_STATE_DIR/last-rebuild-rev"
env PATH="$BIN:$PATH" $U > "$WORK/u.out" 2>&1 < /dev/null
check_out "no stamp yet (first update of this kind): it rebuilds" "REBUILD RAN" cat "$WORK/u.out"
check_eq "a skipped update sends no push message" "0" "$(grep -c 'update started' "$WORK/u.out")"

finish
