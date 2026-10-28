#!/usr/bin/env bash
# Web interface backend (scripts/web-serve.py): sign-in rules (Domain Admins and the local account only), sessions, CSRF, throttle, static files, theme.
# The helpers (ntlm_auth, wbinfo, unix_chkpwd) are replaced in the test, so no domain and no root are needed.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have python3; then skip "python3 missing"; finish; exit 0; fi

echo "-- web backend"
if out=$(python3 -I "$ROOT/tests/web-login-test.py" 2>&1); then pass "web backend tests ($(grep -E '^Ran ' <<<"$out"))"; else fail "web backend tests: $(tail -n 25 <<<"$out")"; fi

echo "-- helper commands (stand-ins for ntlm_auth, wbinfo, unix_chkpwd)"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/ntlm_auth" <<'X'
#!/bin/sh
read -r u p
[ "$u $p" = 'HOME\anna pw%20with%20space' ] && echo OK || echo ERR
X
cat > "$WORK/bin/wbinfo" <<'X'
#!/bin/sh
case "$1" in
  --group-info) echo 'HOME\domain admins:x:512:' ;;
  -r) if [ "$2" = 'HOME\anna' ]; then printf '513\n512\n'; else printf '513\n'; fi ;;
esac
X
cat > "$WORK/bin/unix_chkpwd" <<'X'
#!/bin/sh
[ "$1 $2" = "adminuser nonull" ] && [ "$(tr -d '\0')" = "secret" ]
X
chmod +x "$WORK/bin/"*
cat > "$WORK/helpers.py" <<'X'
import importlib.util, os
spec = importlib.util.spec_from_file_location("w", os.environ["ROOT"] + "/scripts/web-serve.py")
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)
b = os.environ["B"]
c = w.Config()
c.workgroup, c.ntlm_auth, c.wbinfo, c.chkpwd = "HOME", b + "/ntlm_auth", b + "/wbinfo", b + "/unix_chkpwd"
a = w.Auth(c)
r = {"pw": a.domain_password_ok("anna", "pw with space"), "bad": a.domain_password_ok("anna", "x"),
     "admin": a.domain_is_admin("anna"), "notadmin": a.domain_is_admin("bob"),
     "local": a.local_password_ok("adminuser", "secret"), "localbad": a.local_password_ok("adminuser", "no"),
     "empty": a.local_password_ok("adminuser", "")}
print(" ".join(k for k, v in r.items() if v))
X
check_eq "helpers answer as the real ones do" "pw admin local" "$(ROOT=$ROOT B=$WORK/bin python3 -I "$WORK/helpers.py")"
finish
