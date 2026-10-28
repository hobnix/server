#!/usr/bin/env bash
# ct_tailscale (scripts/recipes/_lib.sh): Tailscale inside a container, as used by livekit and stalwart. A stub recipe sources the real
# _lib.sh with a fake incus that logs what it is asked; no root, no server.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test HS_STATE_DIR=$WORK/state
mkdir -p "$WORK/bin" "$HS_STATE_DIR"
cat > "$WORK/bin/incus" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
case "$*" in
  *"test -c /dev/net/tun"*) [ -z "${NO_TUN:-}" ] ;;
  *"command -v tailscale"*) [ -z "${NO_TS:-}" ] ;;
  *"tailscale ip -4"*) [ -z "${SIGNED_OUT:-}" ] && echo 100.64.0.7 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$WORK/bin/incus"
export PATH="$WORK/bin:$PATH" HS_INCUS=$WORK/bin/incus FAKE_LOG=$WORK/log
cat > "$WORK/stub.sh" <<STUB
#!/usr/bin/env bash
# recipe: Demo: a stub for the test
set -euo pipefail
scripts=$SCRIPTS
state=\$HS_STATE_DIR
ct=demo
. "\$scripts/recipes/_lib.sh"
ct_tailscale
echo "ts_ip=[\$ts_ip]"
STUB
: > "$FAKE_LOG"; out=$(bash "$WORK/stub.sh" 2>&1 </dev/null)
check_out "signed in already: says so and sets ts_ip" "ts_ip=\[100.64.0.7\]" echo "$out"
check_out "and does not sign in again" "Signed in to Tailscale already" echo "$out"
check "it neither adds the tun device nor installs anything" bash -c '! grep -qE "device add|install" "$1"' _ "$FAKE_LOG"
: > "$FAKE_LOG"; out=$(SIGNED_OUT=1 bash "$WORK/stub.sh" 2>&1 </dev/null)
check_out "signed out, no terminal: it names the command to sign in" "Sign it in with: incus exec demo -- tailscale up --hostname=demo --accept-dns=false" echo "$out"
check_out "and ts_ip is empty" "ts_ip=\[\]" echo "$out"
: > "$FAKE_LOG"; out=$(NO_TUN=1 bash "$WORK/stub.sh" 2>&1 </dev/null)
check "without /dev/net/tun the device is added" grep -q 'config device add demo tun unix-char' "$FAKE_LOG"
finish
