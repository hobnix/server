#!/usr/bin/env bash
# Web interface, gap-filling round: another disk (disk-change.sh temp-mount|temp-copy|temp-eject), DNS names (dns-change.sh), the router view
# (unifi.sh networks|clients) and the allowlists in scripts/web-serve.py. Stand-ins for temp-disk.sh, dns.sh and curl: no root, no hardware.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en
unset HS_CALLER HS_GUIDED_TTY
T=$'\t'
has() { grep -q -- "$1" <<<"$out"; }

if have python3; then
  echo "-- allowlists"
  if out=$(python3 -I "$ROOT/tests/web-gaps-test.py" 2>&1); then pass "web CHANGES and READS ($(grep -E '^Ran ' <<<"$out"))"; else fail "allowlists: $(tail -n 25 <<<"$out")"; fi
else
  skip "python3 missing"
fi

echo "-- another disk (disk-change.sh)"
export HS_BULK=$WORK/bulk; mkdir -p "$HS_BULK/shares/photos"
cat > "$WORK/tdisk" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/tdisk-calls"
case "$1" in
  raw)
    echo "/dev/sdg1|ntfs|Backup Stick|500107862016|"
    echo "/dev/sdh1|ext4||1000204886016|/mnt/temp/travel"
    echo "/dev/sdi1|exfat|other|64000000000|/media/user/other" ;;
  mount)
    dev=$2
    if [ "${*: -1}" = "--dry-run" ]; then
      [ "$dev" != /dev/sdz1 ] || { echo "Filesystem 'zfs' is not supported here"; exit 1; }
      echo "Disk:   $dev (ntfs)"; echo "Mount:  /mnt/temp/sdg1 (ntfs3, read-only)"; echo 'Share:  \\host\temp-sdg1 (only HOME\Domain Admins)'; echo "(dry run, nothing changed)"; exit 0
    fi
    echo "Mounted and shared as temp-sdg1" ;;
  eject) echo "$2: unmounted, safe to unplug" ;;
  copy)  echo "Copied." ;;
esac
FAKE
chmod +x "$WORK/tdisk"
export HS_TEMP_DISK=$WORK/tdisk
run() { rc=0; out=$(timeout 20 bash "$SCRIPTS/disk-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }

run plan temp-mount sdg1
check_eq "mount plan: exit 0" 0 "$rc"
has "^status${T}ok$" && has "^heading${T}look at /dev/sdg1$" && has "^step${T}mount /dev/sdg1 read-only (ntfs, \"Backup Stick\"" && has "^step${T}Mount /mnt/temp/sdg1" && has "^command${T}bash .*tdisk mount /dev/sdg1$" && has "^long${T}no$" && pass "mount plan: heading, read-only step, mount point, command" || fail "mount plan: $out"
has '^danger' && fail "mounting is not red" || pass "mounting is not red"
run plan temp-mount sdg1 --name stick
has "^command${T}bash .*tdisk mount /dev/sdg1 --name stick$" && pass "a name is passed on" || fail "name: $out"
run plan temp-mount sdh1
check_eq "an already mounted partition is refused" 1 "$rc"
has "mounted at /mnt/temp/travel already" && pass "says where" || fail "mounted: $out"
run plan temp-mount sdb1
check_eq "a partition that is not offered is refused" 1 "$rc"
has "never mounted here" && pass "system and pool disks are never offered" || fail "not offered: $out"
run plan temp-mount sdg1 --rw
check_eq "no read-write" 1 "$rc"
run plan temp-mount sdg1 --name 'Bad Name'
check_eq "a bad name" 1 "$rc"
run plan temp-mount sdg1 --name
check_eq "a name without a value ends (no endless loop)" 1 "$rc"
run plan temp-mount ../sdg1
check_eq "no path tricks" 1 "$rc"
rm -f "$WORK/tdisk-calls"
run start temp-mount sdg1
check_eq "start: exit 0" 0 "$rc"
check_eq "start is done at once" "status${T}done" "$out"
grep -qx "mount /dev/sdg1" "$WORK/tdisk-calls" && pass "temp-disk.sh mount was called, once without --dry-run" || fail "calls: $(cat "$WORK/tdisk-calls")"
rm -f "$WORK/tdisk-calls"
run start temp-mount sdh1
check_eq "start on a mounted partition: refused" 1 "$rc"
grep -qx "mount /dev/sdh1" "$WORK/tdisk-calls" && fail "mounted anyway" || pass "nothing was mounted"

run plan temp-eject travel
check_eq "eject plan: exit 0" 0 "$rc"
has "^heading${T}eject travel$" && has "^step${T}remove the share temp-travel and unmount /mnt/temp/travel$" && has "^warn${T}Open files" && has "^command${T}bash .*tdisk eject travel$" && pass "eject plan names the share and the mount" || fail "eject: $out"
run plan temp-eject nothing
check_eq "eject of something that is not mounted here" 1 "$rc"
run plan temp-eject other
check_eq "a disk mounted elsewhere is not ours to eject" 1 "$rc"
run start temp-eject travel
check_eq "eject start: done" "status${T}done" "$out"

run plan temp-copy travel
check_eq "copy without a share: needs" 2 "$rc"
has "^needs${T}to$" && pass "asks for the share" || fail "needs: $out"
run plan temp-copy travel --to photos
check_eq "copy plan: exit 0" 0 "$rc"
has "^heading${T}copy travel into the share photos$" && has "^command${T}bash .*tdisk copy travel photos$" && has "^long${T}yes$" && pass "copy plan: long, names the command" || fail "copy: $out"
run plan temp-copy travel --to nothere
check_eq "copy into a share that does not exist" 1 "$rc"
run plan temp-copy travel --to '../x'
check_eq "no path as a share" 1 "$rc"
run plan temp-copy travel --delete
check_eq "no other options" 1 "$rc"
run plan temp-format sdg1
check_eq "an unknown action" 1 "$rc"

echo "-- DNS names (dns-change.sh)"
cat > "$WORK/dns" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/dns-calls"
[ "$1" = sync ] || exit 1
case "${FAKE_DNS:-changes}" in
  broken) echo "There is no domain (adDomain) in machine.toml, so there is no DNS to put names into."; exit 1 ;;
  uptodate) exit 0 ;;
esac
if [ "${2:-}" = --plain ]; then
  printf 'add\tdocs.home.ad.home.lan\tA\t10.10.95.22\t\n'
  printf 'change\tdocker.home.ad.home.lan\tA\t10.10.95.20\t10.10.95.99\n'
  printf 'remove\told.home.ad.home.lan\tA\t10.10.95.77\t\n'
fi
FAKE
chmod +x "$WORK/dns"
export HS_DNS=$WORK/dns
runc() { rc=0; out=$(timeout 20 bash "$SCRIPTS/dns-change.sh" "$@" </dev/null 2>/dev/null) || rc=$?; }
runc plan sync
check_eq "dns plan: exit 0" 0 "$rc"
has "^step${T}add docs.home.ad.home.lan (A) = 10.10.95.22$" && has "^step${T}change docker.home.ad.home.lan (A) from 10.10.95.99 to 10.10.95.20$" && has "^step${T}remove old.home.ad.home.lan (A = 10.10.95.77)$" && pass "every record is a step" || fail "dns plan: $out"
has "^warn${T}Names that no running instance" && has "^command${T}bash .*dns sync --yes$" && has "^long${T}yes$" && pass "removal warned about, command named" || fail "dns plan tail: $out"
FAKE_DNS=uptodate runc plan sync
check_eq "nothing to do is a refusal" 1 "$rc"
has "up to date" && pass "says so" || fail "uptodate: $out"
FAKE_DNS=broken runc plan sync
check_eq "no domain: refused" 1 "$rc"
has "^reason${T}There is no domain" && pass "with the reason of dns.sh" || fail "broken: $out"
runc plan nonsense
check_eq "unknown action" 1 "$rc"
runc plan sync --yes
check_eq "no extra word" 1 "$rc"

echo "-- router view (unifi.sh networks|clients)"
if ! have python3; then
  skip "python3 missing for unifi clients"
else
  export HS_STATE_DIR=$WORK/state; mkdir -p "$HS_STATE_DIR"
  printf 'https://router.invalid\nkey\n' > "$HS_STATE_DIR/unifi"
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/curl" <<'FAKE'
#!/usr/bin/env bash
# the last argument is the URL; answer from a file next to this script and add the status line the script strips
url=${*: -1}
case "$url" in
  */rest/networkconf) f=networks.json ;;
  */rest/user)        f=users.json ;;
  */stat/sta)         f=sta.json ;;
  *) echo "unexpected $url" >&2; exit 1 ;;
esac
cat "$(dirname "$0")/$f"; printf '\n200'
FAKE
  chmod +x "$WORK/bin/curl"
  cat > "$WORK/bin/users.json" <<'JSON'
{"data":[{"mac":"aa:aa:aa:aa:aa:01","name":"docker","use_fixedip":true,"fixed_ip":"10.10.95.20"},
         {"mac":"aa:aa:aa:aa:aa:02","hostname":"printer","use_fixedip":true,"fixed_ip":"10.10.95.5"},
         {"mac":"aa:aa:aa:aa:aa:03","name":"phone","use_fixedip":false,"fixed_ip":"10.10.95.77"}]}
JSON
  cat > "$WORK/bin/sta.json" <<'JSON'
{"data":[{"mac":"aa:aa:aa:aa:aa:01","ip":"10.10.95.20","hostname":"docker-x"},{"mac":"aa:aa:aa:aa:aa:09","ip":"10.10.95.101","hostname":"laptop"},{"mac":"aa:aa:aa:aa:aa:0a"}]}
JSON
  cat > "$WORK/bin/networks.json" <<'JSON'
{"data":[{"name":"home","ip_subnet":"10.10.95.1/24","dhcpd_enabled":true,"dhcpd_start":"10.10.95.100","dhcpd_stop":"10.10.95.254","_id":"n1"},
         {"name":"lan","ip_subnet":"10.10.10.1/24","dhcpd_enabled":false,"_id":"n2"}]}
JSON
  export PATH="$WORK/bin:$PATH"
  out=$(timeout 20 bash "$SCRIPTS/unifi.sh" clients 2>&1 | tr -d '\015') || true
  exp=$(printf '10.10.95.5\taa:aa:aa:aa:aa:02\tprinter\treserved\n10.10.95.20\taa:aa:aa:aa:aa:01\tdocker\treserved+online\n10.10.95.101\taa:aa:aa:aa:aa:09\tlaptop\tonline')
  check_eq "clients: ip, mac, name, how, sorted by address, no header; a client that is not reserved is not 'reserved'" "$exp" "$out"
  if have jq; then
    out=$(timeout 20 bash "$SCRIPTS/unifi.sh" networks 2>&1) || true
    check_eq "networks: name, subnet, dhcp, first, last" "$(printf 'home\t10.10.95.1/24\ttrue\t10.10.95.100\t10.10.95.254\nlan\t10.10.10.1/24\tfalse\t-\t-')" "$out"
  else
    skip "jq missing for unifi networks"
  fi
  out=$(timeout 20 bash "$SCRIPTS/unifi.sh" clients extra 2>&1) || true
  has "usage" && pass "no extra argument" || fail "extra: $out"
fi

echo "-- registry"
reg=$SCRIPTS/lib/registry.tsv
for r in "sys unifi networks" "sys unifi clients" "sys ports list" "sys dns list" "sys dns plan <action>" "sys dns start <action>"; do
  check "row: $r" grep -q "^sys${T}$r${T}" "$reg"
done

finish
