#!/usr/bin/env bash
# The sunshine recipe (syntax, dry run) and `hs ext games` (pc.sh: list, add, remove, wake with a stand-in for the packet). No root, no incus.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test
export HS_STATE_DIR=$WORK/state
mkdir -p "$HS_STATE_DIR"
P="bash $ROOT/capabilities/games/pc.sh"

echo "-- recipe"
check "sunshine.sh parses" bash -n "$ROOT/packages/sunshine/run.sh"
check "pc.sh parses" bash -n "$ROOT/capabilities/games/pc.sh"
check "recipe has a German one-liner" grep -q '^# recipe.de: ' "$ROOT/packages/sunshine/run.sh"
check_out "dry run names the container" "container 'sunshine'" bash "$ROOT/packages/sunshine/run.sh" --dry-run

echo "-- hs ext games (pc.sh)"
check_out "empty list says how to add" "hs ext games add" $P list
check_out "add" "Saved 'gaming'" $P add gaming AA:BB:CC:DD:EE:FF 10.10.10.50
check_out "list shows MAC lower case and address" "gaming +aa:bb:cc:dd:ee:ff +10.10.10.50" $P list
check "bad MAC refused" bash -c "! $P add x nonsense 2>/dev/null"
check "bad address refused" bash -c "! $P add x aa:bb:cc:dd:ee:ff 300.x 2>/dev/null"
check "unknown PC refused" bash -c "! $P wake nobody 2>/dev/null"

cat > "$WORK/wol" <<'W'
#!/usr/bin/env bash
echo "$1" >> "${WOL_LOG}"
W
chmod +x "$WORK/wol"
export HS_WOL_CMD=$WORK/wol WOL_LOG=$WORK/wol.log
check_out "wake sends the packet" "Wake-up packet sent" $P wake gaming
check_eq "the packet went to the saved MAC" "aa:bb:cc:dd:ee:ff" "$(cat "$WORK/wol.log")"
$P add nomac aa:bb:cc:dd:ee:00 >/dev/null
check "--wait without an address refused" bash -c "! $P wake nomac --wait 2>/dev/null"
$P add dead aa:bb:cc:dd:ee:01 127.0.0.1 >/dev/null
check "--wait gives up when nothing answers" bash -c "! HS_PC_PORT=1 HS_PC_WAIT_SECONDS=2 $P wake dead --wait 2>/dev/null"
$P add gaming aa:bb:cc:dd:ee:02 >/dev/null
check_eq "add again replaces the entry" "1" "$(grep -c '^gaming' "$HS_STATE_DIR/pcs")"
check_out "remove" "Removed 'gaming'" $P remove gaming
finish
