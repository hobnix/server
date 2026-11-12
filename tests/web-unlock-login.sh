#!/usr/bin/env bash
# hs web unlock-login: --dry-run changes nothing; the real run restarts hs-web through HS_SYSTEMCTL.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

echo "-- hs web unlock-login"
export HS_CALLER= HS_WEB_UNLOCK_NOROOT=1
cat > "$WORK/fake-systemctl" <<FAKE
#!/usr/bin/env bash
echo "\$*" >> "$WORK/systemctl.log"
FAKE
chmod +x "$WORK/fake-systemctl"
export HS_SYSTEMCTL="$WORK/fake-systemctl"
out=$(bash "$SCRIPTS/web-unlock-login.sh" --dry-run 2>&1); rc=$?
check "dry-run succeeds" test "$rc" = 0
check "dry-run says what it would run" grep -q 'systemctl restart hs-web' <<<"$out"
check "dry-run calls nothing" test ! -e "$WORK/systemctl.log"
out=$(bash "$SCRIPTS/web-unlock-login.sh" 2>&1); rc=$?
check "the run succeeds" test "$rc" = 0
check "it restarts hs-web" grep -qx 'restart hs-web' "$WORK/systemctl.log"
check "it says the sign-in is open" grep -q 'open again' <<<"$out"
check "a wrong flag is refused" bash -c "! bash '$SCRIPTS/web-unlock-login.sh' --bogus >/dev/null 2>&1"
finish
