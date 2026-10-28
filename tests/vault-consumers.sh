#!/usr/bin/env bash
# The scripts that read a secret while the vault is closed or open: backup.sh, unifi.sh, secrets.sh, motd.sh,
# secret.sh helpers. A closed vault = the link at the old path dangles. No root, no restic: nothing here reaches a disk.
# The "closed" half needs symbolic links (skipped where the file system has none, e.g. Git Bash without developer mode).
# HS_VAULT_OPEN=1 is the test knob of lib/vault.sh for "the mapper is mounted".
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test
unset INVOCATION_ID   # CI runs inside a systemd service: its variable would make every manual call look like a timer
export HS_STATE_DIR=$WORK/state HS_VAULT_DIR=$WORK/vault HS_BULK=$WORK/bulk HS_BACKUP_NO_MOUNT=1 HS_BACKUP_MOUNT=$WORK/mnt
export HS_SSH_DIR=$WORK/ssh HS_SAMBA_PRIVATE=$WORK/samba HS_INITRD_SECRETS=$WORK/initrd HS_SECRETS_ANY_OWNER=1
export HS_LOGIN_MESSAGE=$WORK/login HS_LOCKED_MARKER=$WORK/locked
mkdir -p "$HS_STATE_DIR" "$HS_VAULT_DIR/secrets" "$HS_BULK/shares/docs" "$WORK/ssh" "$WORK/samba" "$WORK/bin"
printf 'curl: stand-in\n' > /dev/null
printf '#!/usr/bin/env bash\nexit 7\n' > "$WORK/bin/curl"; chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"
B="bash $SCRIPTS/backup.sh"
U="bash $SCRIPTS/unifi.sh"
S="bash $SCRIPTS/secrets.sh"
M="bash $SCRIPTS/motd.sh"
rc() { "$@" >/dev/null 2>&1; echo $?; }

# can this file system make a symbolic link that dangles?
ln -s "$WORK/nowhere" "$WORK/probe" 2>/dev/null
if [ -L "$WORK/probe" ]; then links=true; rm -f "$WORK/probe"; else links=false; fi

echo "-- no vault on this server: nothing changes"
check_out "backup --state before init" "configured.no" $B --state
check_out "backup now before init" "Not set up yet" $B now
check_out "motd: no backup yet" "No backup yet" $M
check_out "unifi: not set up, as before" "not set up" $U check
check_eq "the helper notes nothing for a plain file" ok "$(echo x > "$WORK/p"; bash -c ". $SCRIPTS/lib/secret.sh; secret_state $WORK/p")"

echo "-- a secret on the plain disk although there is a vault"
echo uuid > "$HS_STATE_DIR/vault-uuid"
echo pw > "$HS_STATE_DIR/restic-password"; chmod 600 "$HS_STATE_DIR/restic-password"
if [ "$(stat -c %a "$HS_STATE_DIR/restic-password")" = 600 ]; then
  out=$($S 2>&1 || true)
  check_out "flagged: move it" "restic-password.*move it: hs vault move restic-password" echo "$out"
  check_eq "that alone is not an error" 0 "$(rc $S)"
  if grep -q 'pw$' <<<"$out"; then fail "the content is never printed"; else pass "the content is never printed"; fi
else skip "no file modes on this file system (plain secret flagged)"; fi
rm -f "$HS_STATE_DIR/restic-password"

echo "-- open vault: links resolve"
if $links; then
  for n in restic-password unifi; do echo "secret-$n" > "$HS_VAULT_DIR/secrets/$n"; chmod 600 "$HS_VAULT_DIR/secrets/$n"; ln -s "$HS_VAULT_DIR/secrets/$n" "$HS_STATE_DIR/$n"; done
  export HS_VAULT_OPEN=1
  check_out "backup --state: configured" "configured.yes" $B --state
  if $B --state | grep -q '^vault'; then fail "no vault line while open"; else pass "no vault line while open"; fi
  check_out "secrets: in the vault" "restic-password.*in the vault" $S
  if $S | grep -q "in the vault (closed)"; then fail "open is not closed"; else pass "open is not closed"; fi
  check_out "status_line Vault open" "Vault: open" $S
  out=$($U used 10.10.95.5 2>&1 || true)
  if grep -q "vault is closed" <<<"$out"; then fail "unifi does not mention the vault when open"; else pass "unifi does not mention the vault when open"; fi
  unset HS_VAULT_OPEN
else skip "no symbolic links on this file system (open vault)"; fi

echo "-- closed vault: the links dangle"
if $links; then
  for n in restic-password unifi; do rm -f "$HS_VAULT_DIR/secrets/$n"; done
  unset HS_VAULT_OPEN
  # machine-readable modes: exit 0, same shape, nothing the interface cannot parse
  check_eq "--state exits 0" 0 "$(rc $B --state)"
  check_out "--state: still configured" "configured.yes" $B --state
  check_out "--state: says why nothing is known" "vault.closed" $B --state
  if $B --state | awk -F'\t' 'NF != 2 { exit 1 }'; then pass "--state stays key<TAB>value"; else fail "--state stays key<TAB>value"; fi
  check_eq "--shares exits 0" 0 "$(rc $B --shares)"
  check_out "--shares lists the share" "share.docs.(on|off)" $B --shares
  check_eq "status exits 0" 0 "$(rc $B status)"
  check_out "status: the vault, not 'not set up'" "vault closed" $B status
  # commands that need the password
  for c in "now" "drill" "list" "init /dev/null" "verify"; do
    out=$($B $c 2>&1) && r=0 || r=$?
    check_eq "backup $c: exit 1 on a terminal-less manual call" 1 "$r"
    check "backup $c: names hs unlock" grep -q "run hs unlock" <<<"$out"
    if grep -q "Not set up" <<<"$out"; then fail "backup $c: not 'not set up'"; else pass "backup $c: not 'not set up'"; fi
  done
  check_eq "a timer skips: exit 0" 0 "$(HS_CALLER=timer rc $B now)"
  check_out "...and logs why" "vault is closed" env HS_CALLER=timer $B now
  check_eq "now --scheduled skips: exit 0" 0 "$(rc $B now --scheduled)"
  check_eq "a job skips: exit 0" 0 "$(HS_CALLER=job rc $B drill)"
  check_eq "unifi: exit 1" 1 "$(rc $U check)"
  check_out "unifi names hs unlock" "run hs unlock" $U used 10.10.95.5
  if $U used 10.10.95.5 2>&1 | grep -q "not set up"; then fail "unifi: not 'not set up'"; else pass "unifi: not 'not set up'"; fi
  check_eq "unifi in a job: exit 0" 0 "$(HS_CALLER=job rc $U check)"
  out=$($S 2>&1 || true)
  check_out "secrets: in the vault (closed)" "restic-password.*in the vault \(closed\)" echo "$out"
  check_out "secrets: unifi too" "unifi.*in the vault \(closed\)" echo "$out"
  check_out "secrets: the state line" "Vault: closed" echo "$out"
  check_eq "secrets: closed is no error" 0 "$(rc $S)"
  $S fix >/dev/null 2>&1
  check "fix keeps the links" test -L "$HS_STATE_DIR/restic-password"
  check_eq "fix creates nothing in the vault" 0 "$(find "$HS_VAULT_DIR/secrets" -type f | wc -l | tr -d ' ')"
  out=$($M 2>&1)
  check_out "motd: closed, not 'no backup yet'" "vault is closed" echo "$out"
  if grep -q "No backup yet" <<<"$out"; then fail "motd does not claim no backup"; else pass "motd does not claim no backup"; fi
  # a new secret cannot be created while closed
  check_eq "secret_prepare refuses while closed" 1 "$(bash -c ". $SCRIPTS/lib/secret.sh; secret_prepare grafana-admin $HS_STATE_DIR" >/dev/null 2>&1; echo $?)"
  check_eq "...and writes nothing" 0 "$([ -e "$HS_STATE_DIR/grafana-admin" ] || [ -L "$HS_STATE_DIR/grafana-admin" ] && echo 1 || echo 0)"
  # opened: a new secret is created inside the vault and linked
  check_eq "secret_prepare when open" 0 "$(HS_VAULT_OPEN=1 bash -c ". $SCRIPTS/lib/secret.sh; secret_prepare grafana-admin $HS_STATE_DIR" >/dev/null 2>&1; echo $?)"
  check "...links into the vault" test "$(readlink "$HS_STATE_DIR/grafana-admin")" = "$HS_VAULT_DIR/secrets/grafana-admin"
  check_eq "an open vault with a link and no file is 'missing', not 'locked'" missing "$(HS_VAULT_OPEN=1 bash -c ". $SCRIPTS/lib/secret.sh; secret_state $HS_STATE_DIR/grafana-admin")"
else skip "no symbolic links on this file system (closed vault)"; fi

finish
