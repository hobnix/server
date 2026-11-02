#!/usr/bin/env bash
# Locked instances: user.hs.managed_by refuses delete, device changes, docker=no and a smaller disk (scripts/lib/instance.sh).
# Fake incus on PATH. Needs jq, no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1
BIN=$WORK/bin; mkdir -p "$BIN"
export LOG=$WORK/incus.log; : > "$LOG"

if ! command -v jq >/dev/null 2>&1; then skip "jq is not installed: lock tests not run"; finish; exit $?; fi

cat > "$BIN/incus" <<'FAKE'
#!/usr/bin/env bash
echo "incus $*" >> "$LOG"
case "$1" in
  info) case "$2" in web|box) exit 0 ;; *) exit 1 ;; esac ;;
  list) cat <<'JSON'
[{"name":"web","type":"container","status":"Running","state":{"network":null},"expanded_devices":{"eth0":{"hwaddr":"00:16:3e:00:00:01"}}},
 {"name":"box","type":"container","status":"Running","state":{"network":null},"config":{"user.hs.managed_by":"docker"},"expanded_devices":{"eth0":{"hwaddr":"00:16:3e:00:00:02"}}}]
JSON
    ;;
  query) case "$2" in
      /1.0/instances/box) echo '{"type":"container","config":{"user.hs.managed_by":"docker"},"expanded_devices":{"root":{"size":"10GiB"}}}' ;;
      *) echo '{"type":"container","expanded_devices":{}}' ;;
    esac ;;
  config) case "$2" in get) echo "" ;; device) [ "$3" = get ] && exit 1 || true ;; esac ;;
esac
exit 0
FAKE
chmod +x "$BIN/incus"
export PATH="$BIN:$PATH"
C="bash $SCRIPTS/manage-ct.sh"

echo "-- delete"
rc=0; out=$($C box --delete --dry-run 2>&1) || rc=$?
check_eq "locked delete refused" 1 "$rc"
echo "$out" | grep -qF "Docker owns 'box': deleting it is refused. Turn Docker off under Settings, Capabilities, Docker." && pass "with the reason" || fail "reason: $out"
rc=0; out=$(env HS_OWNER=docker $C box --delete --dry-run 2>&1) || rc=$?
check_eq "the owner may delete" 0 "$rc"
echo "$out" | grep -q "incus delete -f box" && pass "plan shows the delete" || fail "plan: $out"
rc=0; env HS_OWNER=other $C box --delete --dry-run >/dev/null 2>&1 || rc=$?
check_eq "another owner is refused" 1 "$rc"

echo "-- refused changes"
: > "$LOG"
for a in "--remove-storage data" "--add-storage fast data /data" "--set docker=no" "--set disk=5"; do
  rc=0; $C box $a --dry-run >/dev/null 2>&1 || rc=$?
  check_eq "box $a" 1 "$rc"
done
! grep -E 'incus (delete|config device (remove|set|override|add)|config set|storage)' "$LOG" >/dev/null && pass "no refused call changed anything" || fail "a changing call was logged"

echo "-- a refused key stops the others"
: > "$LOG"
rc=0; $C box --set ram=2048 docker=no --dry-run >/dev/null 2>&1 || rc=$?
check_eq "ram first, docker=no second: refused" 1 "$rc"
! grep -E 'incus config (set|unset)' "$LOG" >/dev/null && pass "ram was not applied" || fail "ram was applied before the refusal"

echo "-- allowed"
for a in --start --stop --restart "--snapshot x" "--set docker=yes" "--set disk=20" "--set ram=1024"; do
  rc=0; $C box $a --dry-run >/dev/null 2>&1 || rc=$?
  check_eq "box $a" 0 "$rc"
done
rc=0; $C web --delete --dry-run >/dev/null 2>&1 || rc=$?
check_eq "an unlocked instance can be deleted" 0 "$rc"

echo "-- list"
list=$($C --list)
check_eq "17 fields on every line" "17 17" "$(printf '%s\n' "$list" | awk -F'\t' '{print NF}' | tr '\n' ' ' | sed 's/ $//')"
check_eq "box owner" docker "$(printf '%s\n' "$list" | awk -F'\t' '$1=="box"{print $17}')"
check_eq "web owner" "-" "$(printf '%s\n' "$list" | awk -F'\t' '$1=="web"{print $17}')"

echo "-- create-share"
: > "$LOG"; echo zfs > "$WORK/bulk-type"
rc=0; out=$(HS_BULK_TYPE_FILE=$WORK/bulk-type bash "$SCRIPTS/create-share.sh" x --ct box /x 2>&1) || rc=$?
check_eq "refused" 1 "$rc"
echo "$out" | grep -q "Docker owns 'box'" && pass "with the reason" || fail "reason: $out"
! grep -q 'device add' "$LOG" && pass "no device added" || fail "a device was added"

echo "-- every route checks the lock; the web cannot bypass it"
for f in manage-ct create-share manage-shares share-delete remote; do
  grep -q 'lib/instance.sh' "$SCRIPTS/$f.sh" && grep -q refuse_if_locked "$SCRIPTS/$f.sh" && pass "$f" || fail "$f does not check the lock"
done
! grep -q HS_OWNER "$SCRIPTS/web-serve.py" "$SCRIPTS/ct-change.sh" && pass "web cannot set HS_OWNER" || fail "HS_OWNER found in the web path"
finish
