#!/usr/bin/env bash
# hs backup config [restore]: list the host snapshots, put machine.toml / machine.nix back (no root, no disk, a fake restic).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
if ! have jq; then skip "jq missing"; finish; exit 0; fi
export HS_PLAIN=1 HS_LANG=en HS_BACKUP_NO_MOUNT=1
unset HS_CALLER HS_BACKUP_YES
ST=$WORK/state NX=$WORK/nixos FIX=$WORK/fixture
export HS_STATE_DIR=$ST HS_NIXOS_DIR=$NX HS_BACKUP_REPO=$WORK/repo FIX
mkdir -p "$ST" "$NX" "$WORK/repo" "$WORK/bin" "$FIX$NX" "$FIX$ST/disks" "$FIX$ST/sub"
: > "$WORK/repo/config"
echo live-pass > "$ST/restic-password"
echo 'old = 1' > "$NX/machine.toml"
echo 'hw-live' > "$NX/hardware-configuration.nix"
echo 'old = 1' > "$NX/machine.nix"
echo 'old = 1' > "$FIX$NX/machine.nix"          # same as live
echo 'new = 2' > "$FIX$NX/machine.toml"         # differs
echo 'hw-snapshot' > "$FIX$NX/hardware-configuration.nix"
echo snap-pass > "$FIX$ST/restic-password"
echo 'disk-a' > "$FIX$ST/disks/a"
echo 'uuid' > "$FIX$ST/vault-uuid"
echo 'luks' > "$FIX$ST/luks-uuids"
echo 'setting' > "$FIX$ST/sub/keep"
cat > "$WORK/bin/restic" <<'FAKE'
#!/usr/bin/env bash
# restore <snap> --tag host --target T --include P ...: copy P from $FIX below T; ls <snap> P: print P if it is in $FIX
cmd="" target="" inc=() ; args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    --password-file) [ -z "${FIXPASS:-}" ] || [ "$(cat "${args[$((i + 1))]}")" = "$FIXPASS" ] || { echo "wrong password" >&2; exit 1; }
                     echo "${args[*]}" >> "$FIX.calls" ;;
    --target) target=${args[$((i + 1))]} ;;
    --include) inc+=("${args[$((i + 1))]}") ;;
    snapshots|restore|ls) cmd=${cmd:-${args[$i]}} ;;
  esac
done
case "$cmd" in
  snapshots) echo '[{"id":"abcdef0123456789","time":"2026-11-05T04:00:01Z"}]' ;;
  ls) p=${args[$((${#args[@]} - 1))]}; [ -e "$FIX$p" ] && echo "$p" ;;
  restore) shopt -s nullglob
    for p in "${inc[@]}"; do for q in $FIX$p; do q=${q#"$FIX"}; mkdir -p "$target$(dirname "$q")"; cp -a "$FIX$q" "$target$q"; done; done ;;
esac
exit 0
FAKE
chmod +x "$WORK/bin/restic"
export PATH="$WORK/bin:$PATH"
b() { bash "$SCRIPTS/backup.sh" "$@" </dev/null 2>&1; }
has() { grep -qF -- "$1" <<<"$out"; }

echo "-- list"
out=$(b config)
has "abcdef01" && has "machine.toml, machine.nix" && pass "the snapshot with the files it holds" || fail "list: $out"

echo "-- dry run"
out=$(b config restore --dry-run)
has "changed" && has "$NX/machine.toml" && has "dry run" && pass "the plan names the changed file" || fail "dry: $out"
case "$out" in *new\ =*) fail "contents printed" ;; *) pass "no contents in the plan" ;; esac
check_eq "dry run changes nothing" "old = 1" "$(cat "$NX/machine.toml")"
check_eq "no safety copy yet" 0 "$(ls "$NX" | grep -c before-restore || true)"

echo "-- refuses without a terminal and without --yes"
if out=$(b config restore); then fail "no refusal: $out"; else has "terminal" && pass "refused" || fail "refusal text: $out"; fi
check_eq "still unchanged" "old = 1" "$(cat "$NX/machine.toml")"

echo "-- restore with --yes"
out=$(b config restore --yes) || fail "restore failed: $out"
check_eq "machine.toml is back" "new = 2" "$(cat "$NX/machine.toml")"
check_eq "one safety copy" 1 "$(ls "$NX" | grep -c '^machine.toml.before-restore-')"
check_eq "the safety copy is the old file" "old = 1" "$(cat "$NX"/machine.toml.before-restore-*)"
check_eq "the identical file got no copy" 0 "$(ls "$NX" | grep -c '^machine.nix.before-restore-' || true)"
check_eq "hardware-configuration.nix untouched" "hw-live" "$(cat "$NX/hardware-configuration.nix")"
has "hs rebuild" && pass "points to hs rebuild" || fail "no rebuild hint: $out"
check_eq "no temp folder left" 0 "$(ls -A "$ST" | grep -c config-restore || true)"

echo "-- second run"
out=$(b config restore --yes)
has "identical" && pass "says identical" || fail "second: $out"
check_eq "still one safety copy" 1 "$(ls "$NX" | grep -c '^machine.toml.before-restore-')"

echo "-- with state"
echo 'new = 3' > "$FIX$NX/machine.toml"
out=$(b config restore --yes --with-state)
check_eq "restic-password not restored" "live-pass" "$(cat "$ST/restic-password")"
[ ! -e "$ST/disks" ] && pass "disks not restored" || fail "disks restored"
[ ! -e "$ST/vault-uuid" ] && [ ! -e "$ST/luks-uuids" ] && pass "vault-uuid and luks-uuids not restored" || fail "uuids restored"
check_eq "other state files are restored" "setting" "$(cat "$ST/sub/keep" 2>/dev/null)"
check_eq "machine.toml updated again" "new = 3" "$(cat "$NX/machine.toml")"
check_eq "hardware-configuration.nix still untouched" "hw-live" "$(cat "$NX/hardware-configuration.nix")"

echo "-- from-disk: a fresh install (no password file, no state)"
export FIXPASS=typed-pass HS_RUN_DIR=$WORK
rm -rf "$ST" "$NX"; mkdir -p "$NX" "$ST"
echo 'old = 1' > "$NX/machine.toml"
echo 'new = 5' > "$FIX$NX/machine.toml"
export HS_SSH_DIR=$WORK/ssh HS_SAMBA_DIR=$WORK/samba
mkdir -p "$HS_SSH_DIR" "$FIX$HS_SSH_DIR" "$FIX$HS_SAMBA_DIR"
echo hostkey > "$FIX$HS_SSH_DIR/ssh_host_ed25519_key"
echo livekey > "$HS_SSH_DIR/ssh_host_ed25519_key"
echo sambasecret > "$FIX$HS_SAMBA_DIR/secrets.tdb"
fd() { bash "$SCRIPTS/backup.sh" config restore --from-disk /dev/fake "$@" 2>&1; }

out=$(printf 'typed-pass\n' | fd --dry-run)
has "ssh_host_ed25519_key" && has "machine.toml" && has "dry run" && pass "the plan names machine.toml and the SSH host key" || fail "from-disk dry: $out"
check_eq "dry run changes nothing" "old = 1" "$(cat "$NX/machine.toml")"
has "--with-samba" && pass "says Samba is left out" || fail "samba note: $out"
case "$out" in *secrets.tdb*) fail "samba listed without the flag" ;; *) pass "Samba not in the plan" ;; esac

if out=$(printf 'wrong\n' | fd --dry-run); then fail "wrong passphrase accepted"; else has "passphrase" && pass "wrong passphrase refused" || fail "wrong pass text: $out"; fi
if out=$(printf '\n' | fd --dry-run); then fail "empty passphrase accepted"; else pass "empty passphrase refused"; fi
if grep -qF typed-pass "$FIX.calls" 2>/dev/null; then fail "passphrase on argv"; else pass "passphrase never on argv"; fi

out=$(printf 'typed-pass\nmachine.toml\nnope\n' | fd)
check_eq "machine.toml restored" "new = 5" "$(cat "$NX/machine.toml")"
check_eq "SSH key kept without the typed line" "livekey" "$(cat "$HS_SSH_DIR/ssh_host_ed25519_key")"
has "SSH host keys not restored" && pass "says the keys were skipped" || fail "skip text: $out"
check_eq "no restic-password written" 0 "$(ls "$ST" | grep -c '^restic-password$' || true)"
check_eq "no passphrase file left" 0 "$(ls "$WORK" | grep -c 'hs-config-restore-pw' || true)"

out=$(printf 'typed-pass\nmachine.toml\nssh host keys\n' | fd)
check_eq "SSH key restored after typing its name" "hostkey" "$(cat "$HS_SSH_DIR/ssh_host_ed25519_key")"
check_eq "SSH key safety copy" "livekey" "$(cat "$HS_SSH_DIR"/ssh_host_ed25519_key.before-restore-*)"
[ ! -e "$HS_SAMBA_DIR/secrets.tdb" ] && pass "Samba secrets not restored by default" || fail "samba restored"

echo 'new = 6' > "$FIX$NX/machine.toml"
out=$(printf 'typed-pass\nmachine.toml\n' | fd --with-samba)
check_eq "Samba secrets restored with the flag" "sambasecret" "$(cat "$HS_SAMBA_DIR/secrets.tdb" 2>/dev/null)"

echo 'new = 7' > "$FIX$NX/machine.toml"
echo livekey2 > "$HS_SSH_DIR/ssh_host_ed25519_key"
out=$(printf 'typed-pass\n' | fd --yes)
check_eq "--yes leaves the SSH key alone" "livekey2" "$(cat "$HS_SSH_DIR/ssh_host_ed25519_key")"
check_eq "--yes restores machine.toml" "new = 7" "$(cat "$NX/machine.toml")"
if out=$(bash "$SCRIPTS/backup.sh" config restore --with-samba </dev/null 2>&1); then fail "--with-samba without --from-disk accepted"; else pass "--with-samba needs --from-disk"; fi

finish
