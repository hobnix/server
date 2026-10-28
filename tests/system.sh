#!/usr/bin/env bash
# hs notify (notify.sh) and hs rebuild / hs system rebuild (rebuild.sh), with fake curl, logger, nixos-rebuild and readlink
# on PATH. No root, nothing is sent, nothing is rebuilt.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_STATE_DIR=$WORK/state
BIN=$WORK/bin; mkdir -p "$BIN" "$HS_STATE_DIR"
export CALLS=$WORK/calls; : > "$CALLS"
REAL_READLINK=$(command -v readlink); export REAL_READLINK

cat > "$BIN/curl" <<'FAKE'
#!/usr/bin/env bash
a="$*"; echo "curl ${a//$'\n'/ }" >> "$CALLS"   # one line per call, the body has several
[ -z "${CURL_FAIL:-}" ]
FAKE
cat > "$BIN/logger" <<'FAKE'
#!/usr/bin/env bash
echo "logger $*" >> "$CALLS"
FAKE
cat > "$BIN/nixos-rebuild" <<'FAKE'
#!/usr/bin/env bash
echo "nixos-rebuild $*" >> "$CALLS"
echo "building the system configuration..."
[ -z "${REBUILD_FAIL:-}" ] || { echo "error: build of /nix/store/x.drv failed"; exit 1; }
[ -z "${REBUILD_SWITCH:-}" ] || echo /nix/store/bbb-system > "$STATE_FILE"
exit 0
FAKE
# the system links: current system in $STATE_FILE, generation 7, same kernel before and after
cat > "$BIN/readlink" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  /nix/var/nix/profiles/system) echo system-7-link ;;
  "-f /run/current-system") cat "$STATE_FILE" ;;
  "-f /run/booted-system/kernel"|"-f /run/current-system/kernel") echo /nix/store/kernel ;;
  *) exec "$REAL_READLINK" "$@" ;;
esac
FAKE
chmod +x "$BIN"/*
export STATE_FILE=$WORK/current; echo /nix/store/aaa-system > "$STATE_FILE"
export PATH=$BIN:$PATH
N="bash $SCRIPTS/notify.sh"

echo "-- hs notify"
check_out "no arguments: usage" "usage: hs notify" $N
check_out "one argument: usage" "usage: hs notify" $N onlytitle
check_out "a bad priority position (four arguments): usage" "usage: hs notify" $N a b c d
check_out "dry run, no address: only the journal" "No notifyUrl set, would only write to the journal" env HS_NOTIFY_URL= $N --dry-run "Backup" "failed"
out=$(HS_NOTIFY_URL=https://ntfy.test/topic $N --dry-run "Backup" $'line one\nline two' high)
check_out "dry run shows the address, title, priority" "Would send to https://ntfy.test/topic" echo "$out"
check_out "and the priority" "priority: high" echo "$out"
check_out "and a multi-line message as indented bullets" "^  - line two" echo "$out"
check_out "and the category with its icon" "category: problem \(warning\)" echo "$out"
check_eq "a dry run sends and logs nothing" "" "$(cat "$CALLS")"
HS_NOTIFY_URL= $N "Disk" "sdb is BAD" urgent
check_eq "without an address the journal gets the message" "logger -t hs-notify -- [urgent] Disk: sdb is BAD" "$(cat "$CALLS")"
: > "$CALLS"
HS_NOTIFY_URL=https://ntfy.test/topic $N "Disk" $'two\nlines'
check_out "with an address: journal first" "logger -t hs-notify -- \[default\] Disk: two; lines" cat "$CALLS"
check_out "then a POST with title, priority, icon and markdown as headers" "curl -fsS -m 10 -H Title: Disk -H Priority: default -H Tags: information_source,[a-z0-9-]+ -H Markdown: yes --data-raw - two - lines" cat "$CALLS"
: > "$CALLS"
check_eq "an undeliverable message never makes the caller fail" "0" "$(HS_NOTIFY_URL=https://ntfy.test/t CURL_FAIL=1 $N T M >/dev/null 2>&1; echo $?)"
check_out "and the failure goes to the journal" "could not send 'T' to https://ntfy.test/t" cat "$CALLS"
echo "https://from-file.test/x" > "$HS_STATE_DIR/notify-url"
: > "$CALLS"
$N T M
check_out "the file in the state directory is the address (hs recipe ntfy writes it)" "https://from-file.test/x" cat "$CALLS"
rm -f "$HS_STATE_DIR/notify-url"

echo "-- hs rebuild with options goes straight to nixos-rebuild"
: > "$CALLS"
bash "$SCRIPTS/rebuild.sh" --verbose >/dev/null
check_eq "--verbose alone" "nixos-rebuild switch" "$(cat "$CALLS")"
: > "$CALLS"
bash "$SCRIPTS/rebuild.sh" --verbose --show-trace >/dev/null
check_eq "other options are passed on" "nixos-rebuild switch --show-trace" "$(cat "$CALLS")"

echo "-- hs rebuild / hs system rebuild"
R="bash $SCRIPTS/rebuild.sh"
: > "$CALLS"
out=$($R 2>&1)
check_eq "it runs nixos-rebuild switch" "nixos-rebuild switch" "$(cat "$CALLS")"
check_out "no change: it says so" "Nothing to change" echo "$out"
out=$(REBUILD_SWITCH=1 $R 2>&1)
check_out "a new system: the generation is named, with the one before" "Now running generation 7 \(before: 7\)" echo "$out"
check_out "and the way back is shown" "nixos-rebuild switch --rollback" echo "$out"
echo /nix/store/aaa-system > "$STATE_FILE"
out=$(REBUILD_FAIL=1 $R 2>&1 || true)
check_out "a failed build shows its last lines" "build of /nix/store/x.drv failed" echo "$out"
check_out "and where the rest is" "hs rebuild --verbose" echo "$out"
check_eq "a failed build exits 1" "1" "$(REBUILD_FAIL=1 $R >/dev/null 2>&1; echo $?)"
fake=$WORK/reg; mkdir -p "$fake/lib"
cp "$SCRIPTS"/lib/hs.sh "$SCRIPTS"/lib/capability.sh "$SCRIPTS"/lib/registry-load.sh "$SCRIPTS"/lib/ui.sh "$SCRIPTS"/lib/i18n.sh "$SCRIPTS"/lib/setting.sh "$SCRIPTS"/lib/job.sh "$SCRIPTS"/lib/locked.sh "$SCRIPTS"/lib/machine.sh "$SCRIPTS/lib/registry.tsv" "$fake/lib/"; cp -r "$SCRIPTS"/lib/i18n "$fake/lib/"
cp "$SCRIPTS/rebuild.sh" "$fake/"
: > "$CALLS"
env HS_CALLER=t HS_COMPLETE_DIR=$WORK/complete bash "$fake/lib/hs.sh" system rebuild >/dev/null 2>&1
check_eq "hs system rebuild is the same script" "nixos-rebuild switch" "$(cat "$CALLS")"
finish
